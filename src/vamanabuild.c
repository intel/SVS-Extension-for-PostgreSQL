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
#include "storage/lmgr.h"
#include "tcop/tcopprot.h"
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
		int			primary_bits = abs(buildstate->compression_primary);
		int			secondary_bits = abs(buildstate->compression_secondary);

		ValidateCompressionParam(buildstate->compression_primary, "compression_primary");
		ValidateCompressionParam(buildstate->compression_secondary, "compression_secondary");

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

		/*
		 * Flush before invalidating: VamanaInvalidateCache signals the BGW,
		 * which may immediately open the new relfilenode.  RBM_NORMAL
		 * requires the page to already be on disk.
		 */
		FlushRelationBuffers(index);
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
				 errmsg("failed to build SVS index"),
				 errdetail_log("SVS error code: %d.", error_code),
				 errhint("Try increasing maintenance_work_mem or reducing vector dimensions.")));
	}

	ereport(NOTICE,
			(errmsg("SVS index built successfully")));

	/* Serialize index to disk so the BGW can adopt it. */
	SerializeIndexToPages(&buildstate, svsIndex);

	/*
	 * Fail immediately if the worker is running for a different database —
	 * this is a permanent misconfiguration and the index will never be
	 * usable here.
	 */
	VamanaWorkerAssertDatabase();

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
			if (!VamanaWorkerSubmitLoad(
					relid,
					(int) meta.dimensions,
					(int) meta.graph_degree,
					(int) meta.alpha,
					opts ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW,
					(opts && opts->build_window_size > 0) ? opts->build_window_size : 0,
					(int) meta.compression_type,
					(int) meta.compression_primary,
					(int) meta.compression_secondary,
					opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS,
					(int) VamanaGetDistanceMetric(index),
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
	SVSAlgorithmHandle algorithm;
	SVSBuilderHandle builder;
	SVSStorageHandle storage;
	VamanaOptions *opts;
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
	Size		dataSize;
	float	   *flatData;

	ereport(LOG,
			(errmsg("rebuilding vamana index from table data")));

	opts = (VamanaOptions *) index->rd_options;
	dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;
	graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildWindow = (opts && opts->build_window_size > 0) ?
		opts->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(graph_degree);
	searchWindow = opts ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW;
	useSearchHistory = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;
	compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;
	compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_LEANVEC_PRIMARY;
	compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_LEANVEC_SECONDARY;
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
		Vector	   *vec;
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

			/*
			 * Extract vector using _COPY to avoid reading past page-buffer
			 * boundary.  PG_DETOAST_DATUM for untoasted vectors returns a
			 * pointer directly into the 8192-byte heap page; memcpy's
			 * internal 8-byte reads can overshoot the palloc block end.
			 */
			vec = (Vector *) PG_DETOAST_DATUM_COPY(values[vectorAttNum]);
			if (vec->dim != dimensions)
			{
				pfree(vec);
				pfree(values);
				pfree(isnull);
				ereport(ERROR,
						(errcode(ERRCODE_DATA_EXCEPTION),
						 errmsg("vector dimension mismatch: expected %d, got %d", dimensions, vec->dim)));
			}
			vectorBuffer[numVectors] = palloc(dimensions * sizeof(float));
			memcpy(vectorBuffer[numVectors], vec->x, dimensions * sizeof(float));
			pfree(vec);			/* free the _COPY allocation */
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

	/* Flatten vector data for SVS */
	dataSize = (Size) numVectors * dimensions * sizeof(float);
	flatData = MemoryContextAllocHuge(CurrentMemoryContext, dataSize);

	for (int i = 0; i < numVectors; i++)
	{
		memcpy(flatData + (i * dimensions),
			   vectorBuffer[i],
			   dimensions * sizeof(float));
	}

	algorithm = SVSCreateAlgorithm(graph_degree, buildWindow, searchWindow, alpha, useSearchHistory);

	if (compression_type == VAMANA_COMPRESSION_LEANVEC)
		storage = SVSCreateLeanVecStorage(dimensions, leanvec_dims,
										  compression_primary, compression_secondary);
	else
		storage = SVSCreateSimpleStorage(SVS_DTYPE_FLOAT32);

	builder = SVSCreateBuilder(distanceType, dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);
	SVSBuilderSetThreadpool(builder, SVSDefaultBuildThreads());

	/* Generate sequential external IDs: ids[i] = i */
	{
		size_t	   *ids = palloc((size_t) numVectors * sizeof(size_t));

		for (int i = 0; i < numVectors; i++)
			ids[i] = (size_t) i;

		svsIndex = SVSBuildDynamicIndex(builder, flatData, ids, numVectors, &errorCode);
		pfree(ids);
	}

	if (svsIndex == NULL || errorCode != 0)
	{
		SVSFreeBuilder(builder);
		SVSFreeStorage(storage);
		SVSFreeAlgorithm(algorithm);

		for (int i = 0; i < numVectors; i++)
			pfree(vectorBuffer[i]);
		pfree(vectorBuffer);
		pfree(flatData);

		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to rebuild vamana index from table"),
				 errdetail("SVS build failed with error code %d.", errorCode)));
	}

	SVSSetIndexSearchThreads(svsIndex, SVSDefaultSearchThreads());

	/* Cleanup vector buffers and flatData (but keep tidMapping for cache) */
	SVSFreeBuilder(builder);
	SVSFreeStorage(storage);
	SVSFreeAlgorithm(algorithm);

	for (int i = 0; i < numVectors; i++)
		pfree(vectorBuffer[i]);
	pfree(vectorBuffer);
	pfree(flatData);

	ereport(NOTICE,
			(errmsg("successfully rebuilt vamana index with %d vectors", numVectors)));

	/* Cache the rebuilt index with TID mapping and dynamic fields */
	VamanaCacheIndex(RelationGetRelid(index), svsIndex, dimensions,
					 graph_degree, VAMANA_ALPHA_TO_FLOAT(alpha), tidMapping, numVectors,
					 numVectors,	/* tidMappingCapacity (fresh rebuild, no
									 * holes) */
					 (uint64) numVectors,	/* nextExternalId */
					 0);		/* numDeleted */

	return svsIndex;
}
