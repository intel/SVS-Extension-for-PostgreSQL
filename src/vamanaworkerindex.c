/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkerindex.c
 *
 * Worker-side index lifecycle: load from disk, rebuild from table,
 * cache management, and stale-slot cleanup at startup.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_replication.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/table.h"
#include "access/xact.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "storage/lmgr.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

/* -----------------------------------------------------------------------
 * Worker-internal helpers
 * ----------------------------------------------------------------------- */

/* Swallow save failures — the waiting backend's query must not fail due to a BGW-side I/O problem. */
static void
TrySaveAfterRebuild(Relation indexRel, SVSIndexHandle index, Oid relid)
{
	VamanaIndexCache *cache = VamanaGetCache(relid);

	Assert(cache != NULL);

	/*
	 * A standby cannot persist: the save writes WAL (GenericXLogFinish), which
	 * is illegal in recovery.  The in-memory graph is enough; on restart it is
	 * reloaded from the base backup and brought current by the slot drain.
	 */
	if (!VamanaGetReplayRole()->persists_index)
		return;

	PG_TRY();
	{
		VamanaSaveIndexToDisk(indexRel, index, MAIN_FORKNUM, cache);
	}
	PG_CATCH();
	{
		VamanaCacheSetNeedsSave(relid, true);
		FlushErrorState();
		ereport(LOG,
				(errmsg("vamana index %u: save after rebuild failed, "
						"will retry; index durability degraded", relid)));
	}
	PG_END_TRY();
}

void
VamanaWorkerResetStaleSlots(void)
{
	for (int i = 0; i < VamanaWorkerShmemPtr->maxSlots; i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];
		uint32		s = pg_atomic_read_u32(&slot->status);

		if (s != VAMANA_SLOT_EMPTY)
		{
			ereport(DEBUG1,
					(errmsg("vamana worker: resetting stale slot %d (status=%u) at startup",
							i, s)));
			pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		}
	}
}

/*
 * VamanaWorkerGetOrLoadIndex
 *
 * Return the cached SVSIndexHandle for the given index OID.  If the index is
 * not yet in the worker's in-process cache, open the relation, try to load
 * from disk, and fall back to a full rebuild.  Returns NULL on failure.
 *
 * When loadedFromDisk is non-NULL it is set true only if the handle came from
 * the on-disk checkpoint (not a heap rebuild): such a handle predates any
 * post-checkpoint commit still pending in the replication slot.
 *
 * Must be called from within an active transaction (or the caller must open
 * one).
 */
SVSIndexHandle
VamanaWorkerGetOrLoadIndex(Oid relid, bool *loadedFromDisk)
{
	bool		needsRebuild;
	SVSIndexHandle index;
	Relation	indexRel;

	if (loadedFromDisk != NULL)
		*loadedFromDisk = false;

	/* Fast path: already loaded */
	index = VamanaGetCachedIndex(relid, &needsRebuild);
	if (!needsRebuild)
		return index;

	/*
	 * Acquire AccessShareLock non-blocking before opening the relation.
	 * A background worker must never block on a relation-level lock: if DDL
	 * (DROP TABLE, TRUNCATE) holds AccessExclusiveLock on a related relation,
	 * blocking here creates a lock-ordering cycle and deadlock.  This mirrors
	 * the autovacuum pattern of using ConditionalLockRelationOid.
	 */
	if (!ConditionalLockRelationOid(relid, AccessShareLock))
	{
		ereport(LOG,
				(errmsg("vamana worker: index %u locked by DDL, skipping reload", relid)));
		return NULL;
	}

	/* Open the index relation inside the caller's transaction */
	PG_TRY();
	{
		indexRel = index_open(relid, NoLock);
		index = LoadIndexFromPages(indexRel);
		CHECK_FOR_INTERRUPTS();
		if (index != NULL)
		{
			if (loadedFromDisk != NULL)
				*loadedFromDisk = true;
		}
		else
		{
			ereport(LOG,
					(errmsg("vamana worker: no saved copy for index %u, rebuilding", relid)));
			index = VamanaRebuildFromTable(indexRel);
			CHECK_FOR_INTERRUPTS();
			if (index != NULL)
				TrySaveAfterRebuild(indexRel, index, relid);
			else
			{
				/*
				 * Table has 0 vectors.  Cache an entry with svsIndex=NULL.
				 * The dynamic index will be built lazily on first INSERT
				 * (SVS requires at least 1 vector for build).
				 */
				VamanaOptions *opts = (VamanaOptions *) indexRel->rd_options;
				int		dims = TupleDescAttr(indexRel->rd_att, 0)->atttypmod;

				VamanaCacheIndex(relid, NULL, dims,
								opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE,
								opts ? opts->alpha : VAMANA_DEFAULT_ALPHA,
								NULL, 0, 0, 0, 0);
			}
		}

		{
			VamanaIndexCache *cache = VamanaGetCache(relid);

			if (cache != NULL)
			{
				cache->heapRelid    = indexRel->rd_index->indrelid;
				cache->vectorAttNum = indexRel->rd_index->indkey.values[0] - 1;

				if (cache->replicationSlot == NULL)
					cache->replicationSlot = VamanaReplicationOpen(
						VamanaWorkerShmemPtr->dbOid, relid);
			}
		}

		index_close(indexRel, AccessShareLock);
	}
	PG_CATCH();
	{
		UnlockRelationOid(relid, AccessShareLock);
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana worker: failed to load index %u", relid)));
		index = NULL;
	}
	PG_END_TRY();

	return index;
}

/*
 * Return the cached handle for relid, loaded and caught up to current WAL.
 *
 * A primary persists the graph only at checkpoint and applies later commits
 * from its replication slot.  After a crash the reloaded on-disk copy predates
 * those commits, so a fresh disk load is drained once to replay them.  A heap
 * rebuild already reflects every committed row, so it is not drained: doing so
 * would re-apply post-checkpoint commits the rebuild already contains.
 *
 * Owns its transaction; the caller must not open one.  Returns NULL on failure.
 */
SVSIndexHandle
VamanaWorkerEnsureIndexCurrent(Oid relid)
{
	bool		loadedFromDisk;
	bool		needsRebuild;
	SVSIndexHandle index;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	index = VamanaWorkerGetOrLoadIndex(relid, &loadedFromDisk);
	PopActiveSnapshot();
	CommitTransactionCommand();

	if (index == NULL || !loadedFromDisk)
		return index;

	VamanaReplicationDrainSlot(relid);

	/* A replay error may have rebuilt the index under a new handle. */
	return VamanaGetCachedIndex(relid, &needsRebuild);
}

/*
 * Enumerate every vamana index in the current database, returning a palloc'd
 * List of index relid Oids (NIL if none).  Owns only the SPI session:
 * connect, execute VAMANA_ENUM_INDEXES_IN_DB_SQL, collect, finish.
 *
 * Precondition: the caller holds an open transaction with a pushed snapshot.
 * The two callers reach this from incompatible transaction contexts — the
 * standby loader opens and commits its own txn; the startup seed runs inside
 * the worker's already-open startup txn — so the transaction lifecycle stays
 * the caller's concern, not this wrapper's.
 */
List *
VamanaWorkerEnumerateIndexes(void)
{
	List	   *relids = NIL;
	MemoryContext callerctx = CurrentMemoryContext;
	uint64		nindexes;

	Assert(IsTransactionState());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		ereport(WARNING, (errmsg("vamana worker: SPI_connect failed")));
		return NIL;
	}

	if (SPI_execute(VAMANA_ENUM_INDEXES_IN_DB_SQL, true, 0) != SPI_OK_SELECT)
	{
		SPI_finish();
		ereport(WARNING, (errmsg("vamana worker: failed to enumerate indexes")));
		return NIL;
	}

	nindexes = SPI_processed;
	for (uint64 i = 0; i < nindexes; i++)
	{
		bool		isnull;
		Oid			relid = DatumGetObjectId(
											 SPI_getbinval(SPI_tuptable->vals[i],
														   SPI_tuptable->tupdesc,
														   1, &isnull));
		MemoryContext oldctx;

		if (isnull)
			continue;

		/* Build the result in the caller's context, not SPI's short-lived one. */
		oldctx = MemoryContextSwitchTo(callerctx);
		relids = lappend_oid(relids, relid);
		MemoryContextSwitchTo(oldctx);
	}

	SPI_finish();
	return relids;
}

/*
 * VamanaWorkerEnumerateIndexes in a self-contained transaction, returning the
 * relids in TopMemoryContext.
 */
List *
VamanaWorkerEnumerateAllIndexes(void)
{
	List	   *relids;
	MemoryContext oldctx;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	oldctx = MemoryContextSwitchTo(TopMemoryContext);
	relids = VamanaWorkerEnumerateIndexes();
	MemoryContextSwitchTo(oldctx);

	PopActiveSnapshot();
	CommitTransactionCommand();

	return relids;
}

/*
 * Load a not-yet-cached standby index, suppressing eviction for the load so a
 * relcache invalidation fired while opening the relation does not evict the
 * entry being populated.  Owns its own transaction.
 */
static void
VamanaStandbyLoadIndex(Oid relid)
{
	bool		prevSuppressed = vamana_eviction_suppressed;

	vamana_eviction_suppressed = true;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	(void) VamanaWorkerGetOrLoadIndex(relid, NULL);

	PopActiveSnapshot();
	CommitTransactionCommand();

	vamana_eviction_suppressed = prevSuppressed;
}

/*
 * Release everything a standby holds for an index no longer in the live
 * enumeration: the persistent slot (the orphaned-slot leak DROP INDEX redo
 * would otherwise leave behind, since OAT_DROP never fires on standby redo),
 * the index-lock reservation, and the in-memory cache entry.
 */
static void
VamanaStandbyReleaseIndex(Oid relid)
{
	VamanaWorkerShmem *entry = VamanaWorkerShmemPtr;

	VamanaReplicationDropIfExists(entry->dbOid, relid);
	VamanaReleaseIndexLock(entry, relid);
	VamanaEvictCacheEntry(relid);
}

/*
 * Slot activation reaches CONSISTENT asynchronously: a freshly created handle
 * is not proof of it, so this checks the underlying slot rather than
 * cache->replicationSlot != NULL.
 */
static bool
VamanaStandbySlotIsLive(Oid relid)
{
	return VamanaReplicationSlotIsConsistent(VamanaWorkerShmemPtr->dbOid, relid);
}

/*
 * Bring a standby's cache to match targetRelids: load what is missing,
 * activate the slot (via the caller's activateSlot policy: blocking at
 * startup, bounded from the main loop) for anything not yet live, and release
 * anything cached that is no longer targeted.  Diffs against the live cache
 * each call rather than tracking prior state, so a call left with an
 * unconverged slot is safe to repeat.
 */
bool
VamanaReconcileStandbyCache(List *targetRelids,
							 void (*activateSlot) (Oid relid))
{
	Oid			cachedRelids[VAMANA_MAX_CACHED_INDEXES];
	int			nCached = VamanaGetAllCachedRelids(cachedRelids,
													VAMANA_MAX_CACHED_INDEXES);
	bool		allConverged = true;

	for (int i = 0; i < nCached; i++)
	{
		if (!list_member_oid(targetRelids, cachedRelids[i]))
			VamanaStandbyReleaseIndex(cachedRelids[i]);
	}

	foreach_oid(relid, targetRelids)
	{
		if (VamanaGetCache(relid) == NULL)
			VamanaStandbyLoadIndex(relid);

		if (!VamanaStandbySlotIsLive(relid))
			activateSlot(relid);

		if (!VamanaStandbySlotIsLive(relid))
			allConverged = false;
	}

	return allConverged;
}

