/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanabuild.c
 *
 * Index build implementation for Vamana index using SVS library.
 * Uses simplified batch approach where SVS handles parallelism internally.
 */

#include "postgres.h"

#include "vamana.h"
#include "svs_build_thread_grant.h"
#include "svs_wrapper.h"
#include "vamanaworker.h"

#include "access/amapi.h"
#include "access/heapam.h"
#include "access/relscan.h"
#include "access/table.h"
#include "access/tableam.h"
#include "access/xlog.h"
#include "access/xloginsert.h"
#include "catalog/index.h"
#include "commands/progress.h"
#include "miscadmin.h"
#include "pgstat.h"
#include "storage/bufmgr.h"
#include "storage/ipc.h"
#include "storage/lmgr.h"
#include "tcop/tcopprot.h"
#include "utils/injection_point.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

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
	float	   *floats;
	int			dimensions;

	if (isnull[0])
		return;

	floats = VamanaDatumToFloats(buildstate->typeInfo, values[0],
								 &dimensions, "build");

	if (buildstate->numVectors >= buildstate->bufferCapacity)
	{
		buildstate->bufferCapacity *= 2;
		buildstate->vectorBuffer = repalloc(buildstate->vectorBuffer,
											buildstate->bufferCapacity * sizeof(float *));
		buildstate->tidBuffer = repalloc(buildstate->tidBuffer,
										 buildstate->bufferCapacity * sizeof(ItemPointerData));
	}

	buildstate->vectorBuffer[buildstate->numVectors] = floats;

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
 */
static void
SerializeIndexToPages(VamanaBuildState * buildstate, SVSIndexHandle svsIndex)
{
	VamanaIndexCache meta;

	memset(&meta, 0, sizeof(meta));
	meta.indexRelid = RelationGetRelid(buildstate->index);
	meta.svsIndex = svsIndex;
	meta.isValid = true;
	meta.dimensions = buildstate->dimensions;
	meta.graph_degree = buildstate->graph_degree;
	meta.alpha = VAMANA_ALPHA_TO_FLOAT(buildstate->alpha);
	meta.tidMapping = buildstate->tidBuffer;
	meta.numVectors = buildstate->numVectors;
	meta.tidMappingCapacity = buildstate->numVectors;
	meta.nextExternalId = (uint64) buildstate->numVectors;
	meta.numDeleted = 0;
	meta.needsSave = false;

	VamanaSaveIndexToDisk(buildstate->index, svsIndex, buildstate->forkNum, &meta);
}

/* Valid compression values; used only in this file */
static const int VAMANA_VALID_COMPRESSION_VALUES[] = {
	VAMANA_LEANVEC_UINT4,
	VAMANA_LEANVEC_INT4,
	VAMANA_LEANVEC_UINT8,
	VAMANA_LEANVEC_INT8
};
#define VAMANA_NUM_COMPRESSION_VALUES \
	(sizeof(VAMANA_VALID_COMPRESSION_VALUES) / sizeof(VAMANA_VALID_COMPRESSION_VALUES[0]))

/*
 * (primary bits, residual bits) pairs SVS compiles LVQ specializations for.
 * A pair outside this set fails deep inside the library when the loader looks
 * for a matching specialization, so it is rejected here instead.  Widen this
 * table if an SVS build ever adds specializations; the rule itself does not
 * need rewriting.
 */
typedef struct VamanaLVQPair
{
	int			primary_bits;
	int			residual_bits;
}			VamanaLVQPair;

static const VamanaLVQPair VAMANA_VALID_LVQ_PAIRS[] = {
	{4, 0},
	{8, 0},
	{4, 4},
	{4, 8}
};
#define VAMANA_NUM_LVQ_PAIRS \
	(sizeof(VAMANA_VALID_LVQ_PAIRS) / sizeof(VAMANA_VALID_LVQ_PAIRS[0]))

/*
 * Validate compression parameter (must be one of the valid values).  allow_none
 * additionally accepts 0; pass it only for LVQ's residual, the one parameter
 * for which "absent" is a legal value.
 */
static void
ValidateCompressionParam(int value, const char *param_name, bool allow_none)
{
	bool		is_valid = false;

	if (allow_none && value == VAMANA_COMPRESSION_NO_RESIDUAL)
		return;

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
				 errhint("Valid values are: %d (UINT4), %d (INT4), %d (UINT8), %d (INT8)%s",
						 VAMANA_LEANVEC_UINT4, VAMANA_LEANVEC_INT4,
						 VAMANA_LEANVEC_UINT8, VAMANA_LEANVEC_INT8,
						 allow_none ? ", 0 (no residual)" : "")));
	}
}

/*
 * Validate the compression reloptions as a set.  Parameters belonging to a
 * scheme other than the one selected are ignored rather than rejected, which
 * is how the other irrelevant-parameter cases behave (leanvec_dims under LVQ,
 * every compression parameter under compression_type = none).
 */
static void
ValidateCompressionOptions(int compression_type, int compression_primary,
						   int compression_secondary)
{
	int			primary_bits = abs(compression_primary);
	int			secondary_bits = abs(compression_secondary);

	if (compression_type == VAMANA_COMPRESSION_LEANVEC)
	{
		ValidateCompressionParam(compression_primary, "compression_primary", false);
		ValidateCompressionParam(compression_secondary, "compression_secondary", false);

		if (primary_bits > secondary_bits)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("compression_primary (%d-bit) cannot have higher precision than compression_secondary (%d-bit)",
							primary_bits, secondary_bits),
					 errhint("Primary quantization must be <= secondary precision (e.g., 4-bit primary with 8-bit secondary is valid)")));
		}
	}
	else if (compression_type == VAMANA_COMPRESSION_LVQ)
	{
		bool		is_valid = false;

		ValidateCompressionParam(compression_primary, "compression_primary", false);
		ValidateCompressionParam(compression_secondary, "compression_secondary", true);

		for (size_t i = 0; i < VAMANA_NUM_LVQ_PAIRS; i++)
		{
			if (primary_bits == VAMANA_VALID_LVQ_PAIRS[i].primary_bits &&
				secondary_bits == VAMANA_VALID_LVQ_PAIRS[i].residual_bits)
			{
				is_valid = true;
				break;
			}
		}

		if (!is_valid)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("unsupported LVQ configuration: %d-bit primary with %d-bit residual",
							primary_bits, secondary_bits),
					 errhint("Supported LVQ configurations are 4- or 8-bit primary with no residual (compression_secondary = 0), or 4-bit primary with a 4- or 8-bit residual.")));
		}
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
	buildstate->search_window_size = VamanaResolveSearchWindowSize(opts);
	buildstate->use_search_history = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;

	buildstate->compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;

	buildstate->compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_COMPRESSION_PRIMARY;
	buildstate->compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_COMPRESSION_SECONDARY;
	buildstate->leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	ValidateCompressionOptions(buildstate->compression_type,
							   buildstate->compression_primary,
							   buildstate->compression_secondary);

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
 * Closure for SvsRunGovernedBuild: the actual SVS graph build, run once the
 * thread count is known.  ids is generated here, not passed in, since its
 * only use is this call and its size depends on numVectors either way.
 */
typedef struct VamanaSVSBuildContext
{
	SVSBuilderHandle builder;
	const float *flatData;
	int			numVectors;
	int			graph_degree;
	int			dimensions;

	SVSIndexHandle result;
	int			errorCode;
} VamanaSVSBuildContext;

static void
VamanaRunSVSBuild(int grantedThreads, void *context)
{
	VamanaSVSBuildContext *ctx = (VamanaSVSBuildContext *) context;
	size_t	   *ids = palloc((size_t) ctx->numVectors * sizeof(size_t));

	for (int i = 0; i < ctx->numVectors; i++)
		ids[i] = (size_t) i;

	SVSBuilderSetThreadpool(ctx->builder, grantedThreads);
	ctx->result = SVSBuildDynamicIndex(ctx->builder, ctx->flatData, ids,
										ctx->numVectors, ctx->graph_degree,
										ctx->dimensions, &ctx->errorCode);
	pfree(ids);
}

/*
 * Index-shape parameters needed to construct an SVS algorithm/storage/
 * builder triple.  Deliberately narrower than VamanaBuildState: the only
 * callers building fresh (vamanabuild, VamanaRebuildFromTable) source these
 * from different places (reloptions vs. a live scan), and this keeps the
 * builder lifecycle below decoupled from either caller's own state.  relid
 * is identity rather than shape, but both callers have it on hand and an
 * admission check needs it to size an estimate against the right index.
 */
typedef struct VamanaSVSIndexParams
{
	Oid				relid;
	int				dimensions;
	int				graph_degree;
	int				alpha;
	int				build_window_size;
	int				search_window_size;
	bool			use_search_history;
	int				compression_type;
	int				compression_primary;
	int				compression_secondary;
	int				leanvec_dims;
	SVSDistanceType	distance_type;
	SVSDType		data_type;
} VamanaSVSIndexParams;

/*
 * Builds an SVS index under a launcher-granted thread count.  Takes the
 * caller's raw per-vector buffer and flattens it internally rather than
 * requiring an already-flattened one, so that an admission check needing a
 * live builder handle can sit between builder creation and the flatten,
 * ahead of the large allocation it would exist to refuse.  Owns the
 * builder/storage/algorithm handles it creates and the flattened buffer it
 * allocates, and frees all of them on every exit path, including an ERROR
 * raised while waiting for or running under the grant -- the SVS handles
 * are native objects that PostgreSQL's own memory-context cleanup does not
 * know how to reclaim.  The caller retains ownership of vectorBuffer.
 */
static SVSIndexHandle
VamanaBuildSVSIndexGoverned(const VamanaSVSIndexParams *params,
							 float **vectorBuffer, int numVectors,
							 int *errorCodeOut)
{
	SVSAlgorithmHandle algorithm;
	SVSStorageHandle storage;
	SVSBuilderHandle builder;
	VamanaSVSBuildContext buildCtx;
	float	   *volatile flatData = NULL;
	Size		dataSize;
	int			buildWindow = params->build_window_size > 0 ?
		params->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(params->graph_degree);

	algorithm = SVSCreateAlgorithm(params->graph_degree, buildWindow,
									params->search_window_size, params->alpha,
									params->use_search_history);

	storage = SVSCreateStorageForCompression(params->compression_type,
											 params->data_type,
											 params->dimensions,
											 params->leanvec_dims,
											 params->compression_primary,
											 params->compression_secondary);

	builder = SVSCreateBuilder(params->distance_type, params->dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);

	PG_TRY();
	{
		/*
		 * The admission gate belongs here: the builder above exists for it
		 * to estimate against, and nothing below it has allocated yet.
		 */
		INJECTION_POINT("vamana-build-governed-pre-allocation", NULL);

		/*
		 * Unreachable in practice: dimensions is capped at VAMANA_MAX_DIM
		 * (2000) by both callers, so firing needs more than ~2.3e15 vectors
		 * on a 64-bit system.  Guards the multiplication as belt-and-braces.
		 */
		if ((size_t) numVectors > 0 &&
			(size_t) params->dimensions > SIZE_MAX / sizeof(float) / (size_t) numVectors)
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("vector dataset too large to index "
							"(%d vectors x %d dimensions exceeds memory limit)",
							numVectors, params->dimensions)));

		dataSize = (Size) numVectors * params->dimensions * sizeof(float);
		flatData = MemoryContextAllocHuge(CurrentMemoryContext, dataSize);
		for (int i = 0; i < numVectors; i++)
		{
			memcpy(flatData + (Size) i * params->dimensions,
				   vectorBuffer[i],
				   params->dimensions * sizeof(float));
		}

		buildCtx = (VamanaSVSBuildContext) {
			.builder = builder,
			.flatData = flatData,
			.numVectors = numVectors,
			.graph_degree = params->graph_degree,
			.dimensions = params->dimensions,
		};

		SvsRunGovernedBuild(VamanaRunSVSBuild, &buildCtx);
	}
	PG_FINALLY();
	{
		if (flatData)
			pfree(flatData);
		SVSFreeBuilder(builder);
		SVSFreeStorage(storage);
		SVSFreeAlgorithm(algorithm);
	}
	PG_END_TRY();

	*errorCodeOut = buildCtx.errorCode;
	return buildCtx.result;
}

/*
 * Abort-cleanup callback for PG_ENSURE_ERROR_CLEANUP below.  Its purpose is
 * to release whatever memory reservation the caller of
 * VamanaBuildSVSIndexGoverned holds, on every error unwind.
 * VamanaBuildSVSIndexGoverned reserves nothing, so this callback has
 * nothing to release and does nothing; that emptiness is what makes it
 * safe to wrap the wider span in each caller below, past the build call
 * itself and through the worker hand-off.
 */
static void
SvsBuildAbortCleanup(int code, Datum arg)
{
}

/*
 * Build the index
 */
IndexBuildResult *
vamanabuild(Relation heap, Relation index, IndexInfo *indexInfo)
{
	IndexBuildResult *result;
	VamanaBuildState buildstate;
	SVSIndexHandle svsIndex = NULL;
	int			error_code;

	/*
	 * Reject the build up front if this database is not enabled for vamana: the
	 * index could never be served here, and the check is a property of the
	 * database, not of the heap's contents.  Doing it before the scan also
	 * avoids wasting a full table scan on a permanent misconfiguration.
	 */
	VamanaWorkerAssertDatabase();

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

		/*
		 * Flush before invalidating: VamanaInvalidateCache signals the BGW,
		 * which may immediately open the new relfilenode.  RBM_NORMAL
		 * requires the page to already be on disk.
		 */
		FlushRelationBuffers(index);
		VamanaInvalidateCache(RelationGetRelid(index));

		goto cleanup;
	}

	ereport(NOTICE,
			(errmsg("building SVS index with %d vectors of dimension %d",
					buildstate.numVectors, buildstate.dimensions)));

	/*
	 * SvsBuildAbortCleanup releases whatever memory reservation this build
	 * holds, on an error unwind; it must span through the warm-up hand-off
	 * below because PG_TRY alone does not run on a FATAL exit, and the
	 * worker never independently learns of a caller-owned reservation.
	 * VamanaBuildSVSIndexGoverned reserves nothing, so the callback has
	 * nothing to release and does nothing.
	 */
	PG_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, (Datum) 0);
	{
		VamanaSVSIndexParams params = {
			.relid = RelationGetRelid(index),
			.dimensions = buildstate.dimensions,
			.graph_degree = buildstate.graph_degree,
			.alpha = buildstate.alpha,
			.build_window_size = buildstate.build_window_size,
			.search_window_size = buildstate.search_window_size,
			.use_search_history = buildstate.use_search_history,
			.compression_type = buildstate.compression_type,
			.compression_primary = buildstate.compression_primary,
			.compression_secondary = buildstate.compression_secondary,
			.leanvec_dims = buildstate.leanvec_dims,
			.distance_type = buildstate.distance_type,
			.data_type = buildstate.typeInfo->dataType,
		};

		svsIndex = VamanaBuildSVSIndexGoverned(&params, buildstate.vectorBuffer,
											   buildstate.numVectors, &error_code);

		if (svsIndex == NULL)
		{
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to build SVS index"),
					 errdetail_log("SVS error code: %d.", error_code),
					 errhint("Try increasing maintenance_work_mem or reducing vector dimensions.")));
		}

		ereport(NOTICE,
				(errmsg("SVS index built successfully")));

		/* Serialize index to disk so the BGW can adopt it. */
		SerializeIndexToPages(&buildstate, svsIndex);

		/*
		 * Synchronous warm-up: send a LOAD slot to the BGW so the index is in
		 * the worker cache before this transaction commits.  We read the
		 * authoritative values back from the metapage rather than using
		 * buildstate fields directly, because
		 * SerializeIndexToPages may have adjusted counters.
		 *
		 * leanvec_dims and distance_type are not stored on the metapage; read
		 * them from storage options / the AM support function.
		 */
		{
			Oid				relid = RelationGetRelid(index);
			VamanaMetaPageData meta;
			VamanaOptions  *opts = (VamanaOptions *) index->rd_options;

			VamanaReadMetaPage(index, &meta);

			if (VamanaWorkerIsAvailable())
			{
				INJECTION_POINT("vamana-build-governed-pre-handoff", NULL);
				if (!VamanaWorkerSubmitLoad(
						relid,
						(int) meta.dimensions,
						(int) meta.graph_degree,
						(int) meta.alpha,
						VamanaResolveSearchWindowSize(opts),
						(opts && opts->build_window_size > 0) ? opts->build_window_size : 0,
						(int) meta.compression_type,
						(int) meta.compression_primary,
						(int) meta.compression_secondary,
						opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS,
						(int) VamanaGetDistanceMetric(index),
						(int) buildstate.typeInfo->dataType,
						(int) meta.numVectors,
						(int) meta.tidMappingCapacity,
						meta.nextExternalId,
						(int) meta.numDeleted,
						RelationGetRelid(heap),
						index->rd_index->indkey.values[0] - 1))
				{
					ereport(WARNING,
							(errmsg("vamana index \"%s\": background worker load failed; "
									"index will be adopted by the worker on startup",
									RelationGetRelationName(index))));
				}
			}
			else
			{
				ereport(WARNING,
						(errmsg("vamana index \"%s\": background worker not yet available; "
								"index will be adopted by the worker on startup",
								RelationGetRelationName(index))));
			}
		}
	}
	PG_END_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, (Datum) 0);

cleanup:
	if (svsIndex)
		SVSFreeIndex(svsIndex);

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

	/*
	 * Flush before invalidating: VamanaInvalidateCache signals the BGW,
	 * which may immediately open the new relfilenode.  RBM_NORMAL requires
	 * the page to already be on disk.
	 */
	FlushRelationBuffers(index);
	VamanaInvalidateCache(RelationGetRelid(index));

	MemoryContextDelete(buildstate.buildCtx);
	MemoryContextDelete(buildstate.tmpCtx);
}

/*
 * Rebuild SVS index from table data
 * This is called when the index is not cached (e.g., after server restart)
 */
SVSIndexHandle
VamanaRebuildFromTable(Relation index)
{
	Relation	heap;
	TableScanDesc heapScan;
	HeapTuple	tuple;
	TupleDesc	tupdesc;
	SVSIndexHandle svsIndex;
	VamanaOptions *opts;
	const		VamanaTypeInfo *typeInfo;
	int			dimensions;
	int			graph_degree;
	int			alpha;
	int			buildWindow;
	int			searchWindow;
	bool		useSearchHistory;
	SVSDistanceType distanceType;
	int			compression_type;
	int			compression_primary;
	int			compression_secondary;
	int			leanvec_dims;
	Snapshot	snapshot;
	float	  **vectorBuffer = NULL;
	ItemPointerData *tidMapping = NULL;
	int			numVectors = 0;
	int			bufferCapacity = VAMANA_INITIAL_BUFFER_CAPACITY;
	int			errorCode = 0;

	ereport(LOG,
			(errmsg("rebuilding vamana index from table data")));

	opts = (VamanaOptions *) index->rd_options;
	typeInfo = VamanaGetTypeInfo(index);
	dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;
	graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildWindow = (opts && opts->build_window_size > 0) ?
		opts->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(graph_degree);
	searchWindow = VamanaResolveSearchWindowSize(opts);
	useSearchHistory = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;
	compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;
	compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_COMPRESSION_PRIMARY;
	compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_COMPRESSION_SECONDARY;
	leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	distanceType = VamanaGetDistanceMetric(index);

	vectorBuffer = palloc(bufferCapacity * sizeof(float *));
	tidMapping = palloc(bufferCapacity * sizeof(ItemPointerData));

	/*
	 * Acquire AccessShareLock on the heap non-blocking.  The BGW must never
	 * block on a relation-level lock: holding ASL on the index (acquired by
	 * VamanaWorkerGetOrLoadIndex) while blocking on the heap creates a
	 * lock-ordering cycle with DROP TABLE, which takes AEL on the heap then
	 * AEL on the index.  This mirrors the autovacuum pattern.
	 */
	if (!ConditionalLockRelationOid(index->rd_index->indrelid, AccessShareLock))
	{
		pfree(vectorBuffer);
		pfree(tidMapping);
		ereport(LOG,
				(errmsg("vamana index %u: heap locked by DDL, skipping rebuild",
						RelationGetRelid(index))));
		return NULL;
	}

	heap = table_open(index->rd_index->indrelid, NoLock);
	tupdesc = RelationGetDescr(heap);

	/*
	 * Scan table to collect vectors - use an MVCC snapshot to exclude dead
	 * tuples
	 */
	snapshot = RegisterSnapshot(GetTransactionSnapshot());
	heapScan = table_beginscan(heap, snapshot, 0, NULL);

	while ((tuple = heap_getnext(heapScan, ForwardScanDirection)) != NULL)
	{
		Datum	   *values;
		bool	   *isnull;
		float	   *floats;
		int			datumDim;
		int			natts = tupdesc->natts;
		int			vectorAttNum;

		values = (Datum *) palloc(natts * sizeof(Datum));
		isnull = (bool *) palloc(natts * sizeof(bool));

		heap_deform_tuple(tuple, tupdesc, values, isnull);

		/* Find which attribute is the indexed vector column */
		vectorAttNum = index->rd_index->indkey.values[0] - 1;	/* Attribute numbers are
																 * 1-based */

		if (!isnull[vectorAttNum])
		{
			if (numVectors >= bufferCapacity)
			{
				bufferCapacity *= 2;
				vectorBuffer = repalloc(vectorBuffer,
										bufferCapacity * sizeof(float *));
				tidMapping = repalloc(tidMapping,
									  bufferCapacity * sizeof(ItemPointerData));
			}

			/* Store heap TID for mapping */
			ItemPointerCopy(&tuple->t_self, &tidMapping[numVectors]);

			floats = VamanaDatumToFloats(typeInfo, values[vectorAttNum],
										 &datumDim, "rebuild");
			if (datumDim != dimensions)
			{
				pfree(floats);
				pfree(values);
				pfree(isnull);
				ereport(ERROR,
						(errcode(ERRCODE_DATA_EXCEPTION),
						 errmsg("vector dimension mismatch: expected %d, got %d", dimensions, datumDim)));
			}
			vectorBuffer[numVectors] = floats;
			numVectors++;

			/*
			 * Emit progress LOG at regular intervals to surface progress during
			 * long-running rebuilds.
			 */
			if (numVectors % VAMANA_PROGRESS_INTERVAL == 0)
				ereport(LOG,
						(errmsg("vamana index %u: scanning table, %d vectors collected",
								RelationGetRelid(index), numVectors)));
		}

		pfree(values);
		pfree(isnull);

		CHECK_FOR_INTERRUPTS();
	}

	table_endscan(heapScan);
	UnregisterSnapshot(snapshot);
	table_close(heap, NoLock);
	UnlockRelationOid(index->rd_index->indrelid, AccessShareLock);

	if (numVectors == 0)
	{
		ereport(WARNING,
				(errmsg("no vectors found in table for index rebuild")));
		pfree(tidMapping);
		pfree(vectorBuffer);
		return NULL;
	}

	ereport(NOTICE,
			(errmsg("collected %d vectors, building SVS index...", numVectors)));

	if (compression_type == VAMANA_COMPRESSION_LEANVEC &&
		numVectors < 100000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LeanVec index with only %d vectors; "
						"recall may be poor (recommend >= 100000, minimum 10000)",
						numVectors)));
	}
	else if (compression_type == VAMANA_COMPRESSION_LVQ &&
			 numVectors < 10000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LVQ index with only %d vectors; "
						"recall may be poor (recommend >= 10000)",
						numVectors)));
	}

	/*
	 * SvsBuildAbortCleanup releases whatever memory reservation this build
	 * holds, on an error unwind; it must span through VamanaCacheIndex
	 * below, the point at which the index is durably tracked and hand-off
	 * to the worker is complete, mirroring vamanabuild()'s own span.  The
	 * release happens here, in the caller, rather than inside
	 * VamanaBuildSVSIndexGoverned, because only the caller knows when
	 * hand-off has completed.  VamanaBuildSVSIndexGoverned reserves
	 * nothing, so the callback has nothing to release and does nothing.
	 */
	PG_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, (Datum) 0);
	{
		VamanaSVSIndexParams params = {
			.relid = RelationGetRelid(index),
			.dimensions = dimensions,
			.graph_degree = graph_degree,
			.alpha = alpha,
			.build_window_size = buildWindow,
			.search_window_size = searchWindow,
			.use_search_history = useSearchHistory,
			.compression_type = compression_type,
			.compression_primary = compression_primary,
			.compression_secondary = compression_secondary,
			.leanvec_dims = leanvec_dims,
			.distance_type = distanceType,
			.data_type = typeInfo->dataType,
		};

		svsIndex = VamanaBuildSVSIndexGoverned(&params, vectorBuffer, numVectors, &errorCode);

		if (svsIndex == NULL || errorCode != 0)
		{
			for (int i = 0; i < numVectors; i++)
				pfree(vectorBuffer[i]);
			pfree(vectorBuffer);

			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("failed to rebuild vamana index from table"),
					 errdetail("SVS build failed with error code %d.", errorCode)));
		}

		SVSSetIndexSearchThreads(svsIndex, SvsCurrentSearchGrant());

		/* tidMapping is still needed below, by VamanaCacheIndex. */
		for (int i = 0; i < numVectors; i++)
			pfree(vectorBuffer[i]);
		pfree(vectorBuffer);

		ereport(NOTICE,
				(errmsg("successfully rebuilt vamana index with %d vectors", numVectors)));

		/* Cache the rebuilt index with TID mapping and dynamic fields */
		INJECTION_POINT("vamana-build-governed-pre-handoff", NULL);
		VamanaCacheIndex(RelationGetRelid(index), svsIndex, dimensions,
						 graph_degree, VAMANA_ALPHA_TO_FLOAT(alpha), tidMapping, numVectors,
						 numVectors,	/* tidMappingCapacity (fresh rebuild, no
										 * holes) */
						 (uint64) numVectors,	/* nextExternalId */
						 0);		/* numDeleted */
	}
	PG_END_ENSURE_ERROR_CLEANUP(SvsBuildAbortCleanup, (Datum) 0);

	return svsIndex;
}
