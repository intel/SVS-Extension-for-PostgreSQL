/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkerwrite.c
 *
 * Worker-side execution of non-SEARCH slots: INSERT, DELETE, MAINTENANCE,
 * and LOAD.  Write operations (INSERT/DELETE/MAINTENANCE) hold LW_EXCLUSIVE
 * on the per-index lock for their duration to serialize against concurrent
 * shared-mode search batches.  LOAD populates a fresh cache entry from the
 * save directory and does not acquire the lock (nothing else references the
 * entry until the slot is marked DONE).
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_replication.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/table.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "miscadmin.h"
#include "replication/slot.h"
#include "storage/lwlock.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

/* -----------------------------------------------------------------------
 * Write slot execution
 * ----------------------------------------------------------------------- */

/*
 * Persist the cached counters to the index metapage in a short-lived
 * transaction.  Shared by every write path that mutates the cache.
 */
static void
VamanaWorkerPersistMetaCounters(Oid relid, VamanaIndexCache *cache)
{
	Relation	indexRel;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	indexRel = index_open(relid, AccessShareLock);
	VamanaWriteMetaPageDynamic(indexRel,
							   cache->nextExternalId,
							   (uint32) cache->numVectors,
							   (uint32) cache->numDeleted,
							   (uint32) cache->tidMappingCapacity,
							   MAIN_FORKNUM);
	index_close(indexRel, AccessShareLock);
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/*
 * Build the dynamic SVS index using the first INSERT vector as seed data.
 * Called when svsIndex is NULL (empty-table CREATE INDEX case).
 * On success, updates the cache with the new index and tidMapping.
 * Returns the new SVSIndexHandle, or NULL on failure.
 */
static SVSIndexHandle
VamanaWorkerBuildFirstInsert(Oid relid, VamanaIndexCache *cache,
							 float *vec, ItemPointer heapTid)
{
	SVSAlgorithmHandle algorithm;
	SVSStorageHandle storage;
	SVSBuilderHandle builder;
	SVSIndexHandle	svsIndex;
	int				errorCode = 0;
	size_t			externalId = 0;
	int				buildWindow;
	MemoryContext	oldCtx;
	Relation		indexRel;
	VamanaOptions  *opts;
	int				rawAlpha;
	SVSDistanceType distanceType;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	indexRel = index_open(relid, AccessShareLock);

	opts = (VamanaOptions *) indexRel->rd_options;
	rawAlpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildWindow = (opts && opts->build_window_size > 0)
		? opts->build_window_size
		: VAMANA_BUILD_WINDOW_FROM_DEGREE(cache->graph_degree);
	distanceType = VamanaGetDistanceMetric(indexRel);

	index_close(indexRel, AccessShareLock);
	PopActiveSnapshot();
	CommitTransactionCommand();

	algorithm = SVSCreateAlgorithm(cache->graph_degree, buildWindow,
								   vamana_search_window_size,
								   rawAlpha, VAMANA_DEFAULT_USE_SEARCH_HISTORY);
	storage = SVSCreateSimpleStorage(SVS_DTYPE_FLOAT32);
	builder = SVSCreateBuilder(distanceType, cache->dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);

	svsIndex = SVSBuildDynamicIndex(builder, vec, &externalId, 1, &errorCode);

	SVSFreeBuilder(builder);
	SVSFreeStorage(storage);
	SVSFreeAlgorithm(algorithm);

	if (svsIndex == NULL || errorCode != 0)
	{
		ereport(WARNING,
				(errmsg("vamana worker: first-insert build failed for index %u",
						relid)));
		return NULL;
	}

	cache->svsIndex = svsIndex;
	cache->nextExternalId = 1;
	cache->numVectors = 1;

	oldCtx = MemoryContextSwitchTo(TopMemoryContext);
	cache->tidMapping = palloc0((Size) 1024 * sizeof(ItemPointerData));
	MemoryContextSwitchTo(oldCtx);
	cache->tidMappingCapacity = 1024;

	ItemPointerCopy(heapTid, &cache->tidMapping[0]);

	if (cache->tidToExternalId == NULL)
	{
		HASHCTL		hctl;

		memset(&hctl, 0, sizeof(hctl));
		hctl.keysize   = sizeof(ItemPointerData);
		hctl.entrysize = sizeof(ItemPointerData) + sizeof(uint64);
		hctl.hcxt      = TopMemoryContext;

		oldCtx = MemoryContextSwitchTo(TopMemoryContext);
		cache->tidToExternalId = hash_create("vamana tidToExternalId",
											 1024, &hctl,
											 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
		MemoryContextSwitchTo(oldCtx);
	}

	{
		bool	found;
		uint64	eid = 0;
		char   *hentry = (char *) hash_search(cache->tidToExternalId,
											  heapTid, HASH_ENTER, &found);

		if (!found)
			memcpy(hentry + sizeof(ItemPointerData), &eid, sizeof(uint64));
	}

	return svsIndex;
}

/*
 * Empty-table CREATE INDEX leaves a cache entry with svsIndex=NULL because SVS
 * requires at least one vector to build.  The first INSERT builds the dynamic
 * index from the incoming vector as seed and lazily creates the index's
 * replication slot.  Marks the slot DONE on success; throws on failure so the
 * caller's guard converts it into VAMANA_SLOT_ERROR.
 */
static void
VamanaWorkerBuildEmptyTableIndex(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
	Oid			relid = slot->indexRelid;
	VamanaIndexCache *cache = VamanaGetCache(relid);
	SVSIndexHandle index = NULL;

	if (cache != NULL && slot->slotKind == VAMANA_SLOTKIND_INSERT)
		index = VamanaWorkerBuildFirstInsert(relid, cache,
											 VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdx),
											 &slot->writeHeapTid);

	if (index == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("vamana worker: index %u not loaded for write", relid)));

	/* Seed vector is already indexed by the build; no external ID to return. */
	slot->writeExternalId = 0;

	if (cache->replicationSlot == NULL)
	{
		VamanaReplicationCreate(VamanaWorkerShmemPtr->dbOid, relid);
		cache->replicationSlot = VamanaReplicationOpen(
			VamanaWorkerShmemPtr->dbOid, relid);
		cache->lastReplayLsn = GetFlushRecPtr(NULL);
	}

	VamanaWorkerPersistMetaCounters(relid, cache);

	cache->opsSinceCheckpoint++;
	cache->lastWriteTime = GetCurrentTimestamp();
	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
}

/*
 * Resolve the index and run the requested write, holding the per-index
 * LW_EXCLUSIVE lock across the INSERT/DELETE/MAINTENANCE paths.  Every failure
 * throws; the caller's guard releases all locks and converts it to a slot
 * error.
 */
static void
VamanaWorkerExecuteWriteSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
	Oid			relid = slot->indexRelid;
	LWLock	   *rwlock;
	SVSIndexHandle index;
	bool		needsRebuild;

	/* Load and catch up the index if it is not already warm. */
	index = VamanaGetCachedIndex(relid, &needsRebuild);
	if (needsRebuild)
		index = VamanaWorkerEnsureIndexCurrent(relid);

	/*
	 * Retry once: handles the race where CREATE INDEX committed and sent a
	 * LOAD slot, but that slot was processed after this write slot was already
	 * collected as PENDING.  A second attempt will find the fresh entry.
	 */
	if (index == NULL)
		index = VamanaWorkerEnsureIndexCurrent(relid);

	if (index == NULL)
	{
		VamanaWorkerBuildEmptyTableIndex(slotIdx);
		return;
	}

	/* Acquire LW_EXCLUSIVE — blocks until all shared (search) holders exit. */
	rwlock = VamanaGetIndexLock(VamanaWorkerShmemPtr, relid);
	if (rwlock != NULL)
		LWLockAcquire(rwlock, LW_EXCLUSIVE);

	switch (slot->slotKind)
	{
		case VAMANA_SLOTKIND_INSERT:
			{
				/*
				 * The query vector and heap_tid are already in the slot.
				 * Allocate the next external ID from the cached nextExternalId,
				 * then call SVSAddPoints.
				 */
				VamanaIndexCache *cache = VamanaGetCache(relid);
				size_t		externalId;
				int			added;
				float	   *vec = VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdx);

				if (cache == NULL)
					ereport(ERROR,
							(errmsg("vamana worker: no cache entry for insert on index %u",
									relid)));

				externalId = (size_t) cache->nextExternalId;
				added = SVSAddPoints(index, vec, &externalId, 1);

				if (added <= 0)
					ereport(ERROR,
							(errmsg("vamana worker: SVSAddPoints failed for index %u",
									relid)));

				/* Grow tidMapping if needed. */
				if ((int) externalId >= cache->tidMappingCapacity)
				{
					int			newCap = cache->tidMappingCapacity > 0 ?
						cache->tidMappingCapacity * 2 : 1024;
					MemoryContext oldCtx;

					if (newCap <= (int) externalId)
						newCap = (int) externalId + 1;

					oldCtx = MemoryContextSwitchTo(TopMemoryContext);
					cache->tidMapping = repalloc(cache->tidMapping,
												 (Size) newCap * sizeof(ItemPointerData));
					MemSet(cache->tidMapping + cache->tidMappingCapacity, 0,
						   (Size) (newCap - cache->tidMappingCapacity) *
						   sizeof(ItemPointerData));
					MemoryContextSwitchTo(oldCtx);
					cache->tidMappingCapacity = newCap;
				}

				ItemPointerCopy(&slot->writeHeapTid,
								&cache->tidMapping[externalId]);

				/* Keep reverse hash in sync. */
				if (cache->tidToExternalId != NULL)
				{
					bool	found;
					uint64	eid = (uint64) externalId;
					char   *hentry = (char *) hash_search(
						cache->tidToExternalId,
						&slot->writeHeapTid,
						HASH_ENTER,
						&found);

					if (!found)
						memcpy(hentry + sizeof(ItemPointerData),
							   &eid, sizeof(uint64));
				}

				cache->nextExternalId = externalId + 1;
				cache->numVectors++;
				/* Return the allocated external ID to the backend. */
				slot->writeExternalId = (uint64) externalId;

				VamanaWorkerPersistMetaCounters(relid, cache);

				slot->numResults = 1;
				cache->opsSinceCheckpoint++;
				cache->lastWriteTime = GetCurrentTimestamp();
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
				break;
			}

		case VAMANA_SLOTKIND_DELETE:
			{
				/*
				 * The backend wrote the count of IDs into slot->numResults and
				 * packed the size_t IDs into the query-vector buffer (reused for
				 * input; float[] is naturally aligned for size_t).
				 */
				int			nIds = slot->numResults;
				size_t	   *ids = (size_t *) VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdx);
				int			deleted;
				VamanaIndexCache *cache = VamanaGetCache(relid);

				deleted = SVSDeletePoints(index, ids, nIds);

				if (deleted < 0)
					ereport(ERROR,
							(errmsg("vamana worker: SVSDeletePoints failed for index %u",
									relid)));

				if (cache != NULL)
				{
					for (int i = 0; i < nIds; i++)
						VamanaCacheForgetExternalId(cache, ids[i]);

					cache->numDeleted += deleted;
					cache->numVectors = (cache->numVectors > deleted) ?
						cache->numVectors - deleted : 0;

					VamanaWorkerPersistMetaCounters(relid, cache);
				}

				slot->numResults = deleted;
				if (cache != NULL)
				{
					cache->opsSinceCheckpoint++;
					cache->lastWriteTime = GetCurrentTimestamp();
				}
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
				break;
			}

		case VAMANA_SLOTKIND_MAINTENANCE:
			{
				VamanaIndexCache *cache = VamanaGetCache(relid);

				if (slot->maintenanceOp == VAMANA_MAINTENANCE_CONSOLIDATE)
				{
					if (!SVSConsolidate(index))
						ereport(ERROR,
								(errmsg("vamana worker: SVSConsolidate failed for index %u",
										relid)));
				}
				else if (slot->maintenanceOp == VAMANA_MAINTENANCE_COMPACT)
				{
					if (!SVSCompact(index, 0))
						ereport(ERROR,
								(errmsg("vamana worker: SVSCompact failed for index %u",
										relid)));
					if (cache != NULL)
						cache->numDeleted = 0;
				}

				if (cache != NULL)
				{
					cache->opsSinceCheckpoint++;
					cache->lastWriteTime = GetCurrentTimestamp();
				}

				slot->numResults = 0;
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
				break;
			}

		default:
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("vamana worker: unknown slotKind %u",
							slot->slotKind)));
			break;
	}

	if (rwlock != NULL)
		LWLockRelease(rwlock);
}

/*
 * VamanaWorkerProcessWriteSlot
 *
 * Execute a single non-SEARCH slot (INSERT / DELETE / MAINTENANCE), building
 * the dynamic index on the empty-table first-insert path when needed.  Writes
 * DONE or ERROR into the slot status; SetLatch on the waiting backend is the
 * caller's responsibility.
 *
 * Called from VamanaWorkerProcessRequests after the slot has been transitioned
 * to PROCESSING.  Must not throw: this guard is the sole owner of the
 * eviction-suppression flag and the terminal error status, so every failure
 * below becomes VAMANA_SLOT_ERROR uniformly.
 */
void
VamanaWorkerProcessWriteSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];

	/*
	 * Suppress VamanaRelcacheCallback for the entire duration of this write
	 * slot.  The CREATE INDEX that triggered a preceding LOAD slot commits
	 * only after that LOAD slot marks DONE — meaning the relcache invalidation
	 * arrives after the LOAD slot has already cleared the flag.  The very
	 * next write slot then calls StartTransactionCommand(), which calls
	 * AcceptInvalidationMessages() and processes the queued invalidation.
	 * Without the guard, VamanaRelcacheCallback evicts the index mid-write,
	 * freeing the SVSIndexHandle we already retrieved and causing a
	 * use-after-free or stale-index write.
	 */
	vamana_eviction_suppressed = true;

	PG_TRY();
	{
		VamanaWorkerExecuteWriteSlot(slotIdx);
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		/*
		 * Unwind process-level resources the way the top-level backend loop
		 * does.  The empty-table build path throws from outside a transaction
		 * (VamanaReplicationCreate holds ReplicationSlotAllocationLock and can
		 * ereport "all replication slots are in use"), so AbortCurrentTransaction
		 * alone would leak that lock and any per-index lock still held.  Keep
		 * the worker alive rather than letting the error reach proc_exit.
		 */
		HOLD_INTERRUPTS();
		LWLockReleaseAll();
		if (MyReplicationSlot != NULL)
			ReplicationSlotRelease();
		AbortOutOfAnyTransaction();

		edata = CopyErrorData();
		FlushErrorState();
		RESUME_INTERRUPTS();

		snprintf(slot->errorMessage, sizeof(slot->errorMessage),
				 "%s", edata->message ? edata->message : "unknown error");
		slot->errorCategory = VamanaCategorizeSQLState(edata->sqlerrcode);
		FreeErrorData(edata);

		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);

		vamana_eviction_suppressed = false;
		return;
	}
	PG_END_TRY();

	vamana_eviction_suppressed = false;
}

/* -----------------------------------------------------------------------
 * Load slot execution
 * ----------------------------------------------------------------------- */

/*
 * VamanaWorkerProcessLoadSlot
 *
 * Load a newly built index from its on-disk save directory into the BGW
 * cache without opening the index relation (the backend holds AEL on it).
 *
 * The backend packed a VamanaLoadParams into the queryVec buffer before
 * setting the slot PENDING.  On success the cache entry is live and the
 * waiting backend's VamanaWorkerSubmitLoad returns true.
 *
 * Must not throw: all errors are converted to VAMANA_SLOT_ERROR.
 */
void
VamanaWorkerProcessLoadSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
	Oid			relid = slot->indexRelid;
	VamanaLoadParams *params = (VamanaLoadParams *) VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdx);
	SVSBuildConfig	config;
	SVSIndexHandle	svsIndex = NULL;
	ItemPointerData *tidMapping = NULL;
	char		savepath[MAXPGPATH];
	bool		loadSucceeded = false;


	PG_TRY();
	{
		VamanaGetIndexSavePath(VamanaWorkerShmemPtr->dbOid, relid, savepath, sizeof(savepath));

		config.dimensions			= params->dimensions;
		config.graph_degree			= params->graph_degree;
		config.alpha				= params->alpha;
		config.search_window_size	= params->search_window_size;
		config.build_window_size	= params->build_window_size;
		config.compression_type		= params->compression_type;
		config.compression_primary	= params->compression_primary;
		config.compression_secondary = params->compression_secondary;
		config.leanvec_dims			= params->leanvec_dims;
		config.distance_type		= (SVSDistanceType) params->distance_type;
		config.data_type			= SVS_DTYPE_FLOAT32;

		svsIndex = SVSLoadDynamicIndex(savepath, &config);
		if (svsIndex == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("vamana worker: failed to load index %u from \"%s\"",
							relid, savepath)));

		if (params->tidMappingCapacity > 0)
		{
			tidMapping = (ItemPointerData *)
				MemoryContextAlloc(TopMemoryContext,
								   (Size) params->tidMappingCapacity * sizeof(ItemPointerData));
			if (!VamanaLoadTidMap(VamanaWorkerShmemPtr->dbOid, relid, tidMapping, params->tidMappingCapacity))
				ereport(ERROR,
						(errcode(ERRCODE_DATA_EXCEPTION),
						 errmsg("vamana worker: TID map missing or corrupt for index %u",
								relid)));
		}

		/*
		 * Set the reload guard before populating the cache so any relcache
		 * invalidation that fires inside VamanaCacheIndex (e.g. from a
		 * concurrent DROP) does not evict the entry mid-populate.
		 *
		 * The guard is cleared only after DONE is written.  The next write
		 * slot will set its own guard on entry, which covers the window where
		 * the CREATE INDEX commit's relcache invalidation arrives.
		 */
		vamana_eviction_suppressed = true;
		VamanaCacheIndex(relid, svsIndex,
						 params->dimensions,
						 params->graph_degree,
						 VAMANA_ALPHA_TO_FLOAT(params->alpha),
						 tidMapping,
						 params->numVectors,
						 params->tidMappingCapacity,
						 params->nextExternalId,
						 params->numDeleted);

		{
			VamanaIndexCache *cache = VamanaGetCache(relid);

			if (cache != NULL)
			{
				cache->heapRelid    = params->heapRelid;
				cache->vectorAttNum = params->vectorAttNum;

				/*
				 * Slot creation must happen in the BGW: CreateInitDecodingContext
				 * rejects callers inside a write transaction, and vamanabuild
				 * always runs in one.
				 */
				VamanaReplicationCreate(VamanaWorkerShmemPtr->dbOid, relid);
				cache->replicationSlot = VamanaReplicationOpen(
					VamanaWorkerShmemPtr->dbOid, relid);
				cache->lastReplayLsn = GetFlushRecPtr(NULL);
			}
		}

		slot->numResults = params->numVectors;
		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
		vamana_eviction_suppressed = false;
		loadSucceeded = true;
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		vamana_eviction_suppressed = false;

		edata = CopyErrorData();
		FlushErrorState();

		snprintf(slot->errorMessage, sizeof(slot->errorMessage),
				 "%s", edata->message ? edata->message : "unknown error");
		slot->errorCategory = VamanaCategorizeSQLState(edata->sqlerrcode);
		FreeErrorData(edata);

		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
	}
	PG_END_TRY();

	if (!loadSucceeded)
		return;

	/*
	 * SLOT_DONE is now visible to the backend, which is free to commit the
	 * CREATE INDEX transaction.  Build the initial consistent snapshot here —
	 * the only window where DecodingContextFindStartpoint sees no user inserts
	 * yet, so start_decoding_at is anchored before any post-index writes.
	 * A failure is non-fatal: crash recovery falls back to a full WAL rescan.
	 */
	ereport(DEBUG1,
			(errmsg("vamana: entering BuildSnapshot for index %u", relid)));
	PG_TRY();
	{
		VamanaReplicationBuildSnapshot(VamanaWorkerShmemPtr->dbOid, relid);
	}
	PG_CATCH();
	{
		if (ProcDiePending)
			PG_RE_THROW();
		FlushErrorState();
		ereport(LOG,
				(errmsg("vamana: snapshot build failed for index %u; "
						"crash recovery will rescan from restart_lsn", relid)));
	}
	PG_END_TRY();
	ereport(DEBUG1,
			(errmsg("vamana: exited BuildSnapshot for index %u", relid)));
}

/*
 * VamanaWorkerProcessWarmupSlot
 *
 * Force an index resident in the worker cache on demand.  Routes through
 * VamanaWorkerGetOrLoadIndex, so a hot index is a no-op via its fast path.
 *
 * Unlike ProcessLoadSlot, GetOrLoadIndex opens the index relation and reads
 * the catalog, so it must run inside a transaction.  Eviction is suppressed
 * across the load for the same reason the reload path does it: a relcache
 * invalidation fired during StartTransactionCommand must not evict the entry
 * mid-load.  Must not throw: all errors become VAMANA_SLOT_ERROR.
 */
void
VamanaWorkerProcessWarmupSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
	Oid			relid = slot->indexRelid;

	PG_TRY();
	{
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());

		vamana_eviction_suppressed = true;
		(void) VamanaWorkerGetOrLoadIndex(relid, NULL);
		vamana_eviction_suppressed = false;

		PopActiveSnapshot();
		CommitTransactionCommand();

		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		vamana_eviction_suppressed = false;

		if (IsTransactionState())
			AbortCurrentTransaction();

		edata = CopyErrorData();
		FlushErrorState();

		snprintf(slot->errorMessage, sizeof(slot->errorMessage),
				 "%s", edata->message ? edata->message : "unknown error");
		slot->errorCategory = VamanaCategorizeSQLState(edata->sqlerrcode);
		FreeErrorData(edata);

		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
	}
	PG_END_TRY();
}
