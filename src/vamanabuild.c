/*
 * vamanabuild.c
 *
 * Index build implementation for Vamana index using SVS library.
 * Uses simplified batch approach where SVS handles parallelism internally.
 */

#include "postgres.h"

#include "vamana.h"
#include "svs_wrapper.h"
#include "vamanaworker.h"

#include "access/amapi.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xlog.h"
#include "access/xloginsert.h"
#include "catalog/index.h"
#include "commands/progress.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"
#include "utils/rel.h"

#if PG_VERSION_NUM >= 140000
#include "utils/backend_progress.h"
#else
#include "pgstat.h"
#endif

/*
 * Callback for table_index_build_scan - accumulates vectors in buffer
 */
static void
BuildCallback(Relation index, ItemPointer tid, Datum *values,
			  bool *isnull, bool tupleIsAlive, void *state)
{
	VamanaBuildState *buildstate = (VamanaBuildState *) state;
	Vector	   *vec;
	int			dimensions;

	if (isnull[0])
		return;

	/*
	 * Use PG_DETOAST_DATUM_COPY so vec->x sits in its own palloc block.
	 * Without _COPY, SVS aligned reads can overshoot the heap-page buffer.
	 * See also vamanascan.c (query vector detoast).
	 */
	vec = (Vector *) PG_DETOAST_DATUM_COPY(values[0]);
	dimensions = vec->dim;

	if (buildstate->numVectors >= buildstate->bufferCapacity)
	{
		buildstate->bufferCapacity *= 2;
		buildstate->vectorBuffer = repalloc(buildstate->vectorBuffer,
											buildstate->bufferCapacity * sizeof(float *));
		buildstate->tidBuffer = repalloc(buildstate->tidBuffer,
										 buildstate->bufferCapacity * sizeof(ItemPointerData));
	}

	buildstate->vectorBuffer[buildstate->numVectors] =
		palloc(dimensions * sizeof(float));
	memcpy(buildstate->vectorBuffer[buildstate->numVectors],
		   vec->x,
		   dimensions * sizeof(float));
	pfree(vec);					/* free the _COPY allocation; floats are now
								 * in vectorBuffer */

	/* Store heap TID for mapping: must be after repalloc above */
	ItemPointerCopy(tid, &buildstate->tidBuffer[buildstate->numVectors]);

	buildstate->numVectors++;
}

/*
 * Create the metapage
 */
static void
CreateMetaPage(VamanaBuildState * buildstate)
{
	Relation	index = buildstate->index;
	ForkNumber	forkNum = buildstate->forkNum;
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = VamanaNewBuffer(index, forkNum);
	page = BufferGetPage(buf);
	VamanaInitPage(buf, page);

	metap = VamanaPageGetMeta(page);
	metap->magicNumber = VAMANA_MAGIC_NUMBER;
	metap->dimensions = buildstate->dimensions;
	metap->graph_degree = buildstate->graph_degree;
	metap->alpha = buildstate->alpha;
	metap->compression_type = buildstate->compression_type;
	metap->compression_primary = buildstate->compression_primary;
	metap->compression_secondary = buildstate->compression_secondary;
	metap->indexDataBlkno = InvalidBlockNumber;
	metap->indexDataSize = 0;
	metap->numVectors = 0;
	metap->hasSavedIndex = false;
	metap->nextExternalId = 0;
	metap->numDeleted = 0;
	metap->tidMappingCapacity = 0;

	((PageHeader) page)->pd_lower =
		((char *) metap + sizeof(VamanaMetaPageData)) - (char *) page;

	MarkBufferDirty(buf);
	UnlockReleaseBuffer(buf);
}

/*
 * Serialize the SVS index to disk and update the metapage.
 * Delegates to VamanaSaveIndexToDisk() in vamanautils.c.
 */
static void
SerializeIndexToPages(VamanaBuildState * buildstate, SVSIndexHandle svsIndex)
{
	VamanaSaveIndexToDisk(buildstate->index, svsIndex, buildstate->forkNum);
}

/* Valid compression values (moved from vamana.h: only used here) */
static const int VAMANA_VALID_COMPRESSION_VALUES[] = {
	VAMANA_LEANVEC_UINT4,
	VAMANA_LEANVEC_INT4,
	VAMANA_LEANVEC_UINT8,
	VAMANA_LEANVEC_INT8
};
#define VAMANA_NUM_COMPRESSION_VALUES \
	(sizeof(VAMANA_VALID_COMPRESSION_VALUES) / sizeof(VAMANA_VALID_COMPRESSION_VALUES[0]))

/*
 * Validate compression parameter (must be one of the valid values)
 */
static void
ValidateCompressionParam(int value, const char *param_name)
{
	bool		is_valid = false;

	for (size_t i = 0; i < VAMANA_NUM_COMPRESSION_VALUES; i++)
	{
		if (value == VAMANA_VALID_COMPRESSION_VALUES[i])
		{
			is_valid = true;
			break;
		}
	}

	if (!is_valid)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("invalid %s value: %d", param_name, value),
				 errhint("Valid values are: %d (UINT4), %d (INT4), %d (UINT8), %d (INT8)",
						 VAMANA_LEANVEC_UINT4, VAMANA_LEANVEC_INT4,
						 VAMANA_LEANVEC_UINT8, VAMANA_LEANVEC_INT8)));
	}
}

/*
 * Initialize build state
 */
static void
InitBuildState(VamanaBuildState * buildstate, Relation heap, Relation index,
			   IndexInfo *indexInfo, ForkNumber forkNum)
{
	VamanaOptions *opts = (VamanaOptions *) index->rd_options;

	buildstate->heap = heap;
	buildstate->index = index;
	buildstate->indexInfo = indexInfo;
	buildstate->forkNum = forkNum;
	buildstate->typeInfo = VamanaGetTypeInfo(index);

	buildstate->graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	/* If alpha = -1, SVS uses its internal default (1.2 for L2) */
	buildstate->alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildstate->build_window_size = opts ? opts->build_window_size : VAMANA_DEFAULT_BUILD_WINDOW;
	buildstate->search_window_size = opts ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW;
	buildstate->use_search_history = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;

	buildstate->compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;

	buildstate->compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_LEANVEC_PRIMARY;
	buildstate->compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_LEANVEC_SECONDARY;
	buildstate->leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	if (buildstate->compression_type == VAMANA_COMPRESSION_LEANVEC)
	{
		ValidateCompressionParam(buildstate->compression_primary, "compression_primary");
		ValidateCompressionParam(buildstate->compression_secondary, "compression_secondary");

		int			primary_bits = abs(buildstate->compression_primary);
		int			secondary_bits = abs(buildstate->compression_secondary);

		if (primary_bits > secondary_bits)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("compression_primary (%d-bit) cannot have higher precision than compression_secondary (%d-bit)",
							primary_bits, secondary_bits),
					 errhint("Primary quantization must be <= secondary precision (e.g., 4-bit primary with 8-bit secondary is valid)")));
		}
	}

	buildstate->dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;

	/* Validate dimensions */
	if (buildstate->dimensions < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("column does not have dimensions")));

	if (buildstate->dimensions > VAMANA_MAX_DIM)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("column cannot have more than %d dimensions for vamana index", VAMANA_MAX_DIM)));

	buildstate->reltuples = 0;
	buildstate->indtuples = 0;

	VamanaInitSupport(&buildstate->support, index);

	buildstate->distance_type = VamanaGetDistanceMetric(index);

	buildstate->bufferCapacity = VAMANA_INITIAL_BUFFER_CAPACITY;
	buildstate->vectorBuffer = palloc(buildstate->bufferCapacity * sizeof(float *));
	buildstate->tidBuffer = palloc(buildstate->bufferCapacity * sizeof(ItemPointerData));
	buildstate->numVectors = 0;

	buildstate->buildCtx = AllocSetContextCreate(CurrentMemoryContext,
												 "Vamana build context",
												 ALLOCSET_DEFAULT_SIZES);
	buildstate->tmpCtx = AllocSetContextCreate(CurrentMemoryContext,
											   "Vamana build temporary context",
											   ALLOCSET_DEFAULT_SIZES);
}

/*
 * Free build state resources
 */
static void
FreeBuildState(VamanaBuildState * buildstate)
{
	for (int i = 0; i < buildstate->numVectors; i++)
		pfree(buildstate->vectorBuffer[i]);
	pfree(buildstate->vectorBuffer);
	pfree(buildstate->tidBuffer);

	MemoryContextDelete(buildstate->buildCtx);
	MemoryContextDelete(buildstate->tmpCtx);
}

/*
 * Build the index
 */
IndexBuildResult *
vamanabuild(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	VamanaBuildState buildstate;
	SVSAlgorithmHandle algorithm = NULL;
	SVSStorageHandle storage = NULL;
	SVSBuilderHandle builder = NULL;
	SVSIndexHandle svsIndex = NULL;
	float	   *flatData = NULL;
	Size		dataSize;
	int			error_code;

	InitBuildState(&buildstate, heap, index, indexInfo, MAIN_FORKNUM);

	CreateMetaPage(&buildstate);

	pgstat_progress_update_param(PROGRESS_CREATEIDX_SUBPHASE, PROGRESS_VAMANA_PHASE_LOAD);
	buildstate.reltuples = table_index_build_scan(heap, index, indexInfo,
												  true, true, BuildCallback,
												  (void *) &buildstate, NULL);

	ereport(NOTICE,
			(errmsg("buffered %d vectors for SVS index build", buildstate.numVectors)));

	if (buildstate.compression_type == VAMANA_COMPRESSION_LEANVEC &&
		buildstate.numVectors > 0 && buildstate.numVectors < 100000)
	{
		ereport(WARNING,
				(errmsg("building LeanVec index with only %d vectors; "
						"recall may be poor (recommend >= 100000, minimum 10000)",
						buildstate.numVectors)));
	}
	else if (buildstate.compression_type == VAMANA_COMPRESSION_LVQ &&
			 buildstate.numVectors > 0 && buildstate.numVectors < 10000)
	{
		ereport(WARNING,
				(errmsg("building LVQ index with only %d vectors; "
						"recall may be poor (recommend >= 10000)",
						buildstate.numVectors)));
	}

	if (buildstate.numVectors == 0)
	{
		ereport(NOTICE,
				(errmsg("no vectors to index, skipping SVS build")));

		/* Invalidate any cached index to ensure stale data isn't used */
		VamanaInvalidateCache(RelationGetRelid(index));

		goto cleanup;
	}

	dataSize = (Size) buildstate.numVectors * buildstate.dimensions * sizeof(float);
	flatData = MemoryContextAllocHuge(CurrentMemoryContext, dataSize);
	for (int i = 0; i < buildstate.numVectors; i++)
	{
		memcpy(flatData + (i * buildstate.dimensions),
			   buildstate.vectorBuffer[i],
			   buildstate.dimensions * sizeof(float));
	}

	{
		int			build_window = buildstate.build_window_size > 0 ?
			buildstate.build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(buildstate.graph_degree);
		int			search_window = buildstate.search_window_size;

		algorithm = SVSCreateAlgorithm(
									   buildstate.graph_degree,
									   build_window,
									   search_window,
									   buildstate.alpha,
									   buildstate.use_search_history);
	}

	if (buildstate.compression_type == VAMANA_COMPRESSION_LEANVEC)
	{
		storage = SVSCreateLeanVecStorage(buildstate.dimensions,
										  buildstate.leanvec_dims,
										  buildstate.compression_primary,
										  buildstate.compression_secondary);
	}
	else
	{
		storage = SVSCreateSimpleStorage(SVS_DTYPE_FLOAT32);
	}

	builder = SVSCreateBuilder(buildstate.distance_type, buildstate.dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);
	SVSBuilderSetThreadpool(builder, SVSDefaultBuildThreads());

	ereport(NOTICE,
			(errmsg("building SVS index with %d vectors of dimension %d",
					buildstate.numVectors, buildstate.dimensions)));

	{
		size_t	   *ids = palloc((size_t) buildstate.numVectors * sizeof(size_t));

		for (int i = 0; i < buildstate.numVectors; i++)
			ids[i] = (size_t) i;

		svsIndex = SVSBuildDynamicIndex(builder, flatData, ids, buildstate.numVectors, &error_code);
		pfree(ids);
	}

	if (svsIndex == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to build SVS index: error code %d", error_code),
				 errhint("Try increasing maintenance_work_mem or reducing vector dimensions.")));
	}

	ereport(NOTICE,
			(errmsg("SVS index built successfully")));

	VamanaCacheIndex(RelationGetRelid(index), svsIndex,
					 buildstate.dimensions, buildstate.graph_degree,
					 VAMANA_ALPHA_TO_FLOAT(buildstate.alpha),
					 buildstate.tidBuffer, buildstate.numVectors,
					 buildstate.numVectors, /* tidMappingCapacity */
					 (uint64) buildstate.numVectors,	/* nextExternalId */
					 0);		/* numDeleted */

	/* Mark that we should NOT free the svsIndex since it's cached */
	{
		SVSIndexHandle cachedIndex = svsIndex;
		Oid			relid = RelationGetRelid(index);

		svsIndex = NULL;		/* Don't free in cleanup */

		/* Serialize index to disk so the BGW can adopt it. */
		SerializeIndexToPages(&buildstate, cachedIndex);

		if (VamanaWorkerIsAvailable())
		{
			/*
			 * Ask the BGW to load the saved index as the canonical handle.
			 * The backend's local copy is evicted after the ADOPT succeeds so
			 * only one owner of the SVSIndexHandle exists.
			 */
			if (VamanaWorkerSubmitAdopt(relid))
				VamanaEvictCacheEntry(relid);
			else
				ereport(WARNING,
						(errmsg("vamana index %u: BGW adopt failed; "
								"index will be reloaded on next query", relid)));
		}
		else
		{
			/*
			 * Worker not available: keep the local cache warm and signal a
			 * reload when the worker comes up.
			 */
			if (!AmBackgroundWorkerProcess() && vamana_worker_enabled)
				VamanaWorkerSignalReload(relid);
		}
	}

cleanup:
	if (svsIndex)
		SVSFreeIndex(svsIndex);
	if (builder)
		SVSFreeBuilder(builder);
	if (storage)
		SVSFreeStorage(storage);
	if (algorithm)
		SVSFreeAlgorithm(algorithm);
	if (flatData)
		pfree(flatData);

	FreeBuildState(&buildstate);

	/* WAL logging - must be done even for empty indexes */
	if (RelationNeedsWAL(index))
	{
		log_newpage_range(index, MAIN_FORKNUM, 0,
						  RelationGetNumberOfBlocks(index), true);
	}

	result = (IndexBuildResult *) palloc(sizeof(IndexBuildResult));
	result->heap_tuples = buildstate.reltuples;
	result->index_tuples = buildstate.numVectors;

	return result;
}

/*
 * Build empty index (for unlogged tables)
 */
void
vamanabuildempty(Relation index)
{
	VamanaBuildState buildstate;
	IndexInfo  *indexInfo = BuildIndexInfo(index);

	InitBuildState(&buildstate, NULL, index, indexInfo, INIT_FORKNUM);
	CreateMetaPage(&buildstate);

	MemoryContextDelete(buildstate.buildCtx);
	MemoryContextDelete(buildstate.tmpCtx);
}
