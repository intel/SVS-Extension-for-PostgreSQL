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
 * Must be called from within an active transaction (or the caller must open
 * one).
 */
SVSIndexHandle
VamanaWorkerGetOrLoadIndex(Oid relid)
{
	bool		needsRebuild;
	SVSIndexHandle index;
	Relation	indexRel;

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
		if (index == NULL)
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
 * VamanaWorkerLoadAllIndexes
 *
 * At worker startup, enumerate all Vamana indexes in the connected database
 * via SPI and pre-load each one.  Called inside a transaction.
 */
void
VamanaWorkerLoadAllIndexes(void)
{
	int			ret;
	uint64		nindexes;
	MemoryContext oldctx;

	vamana_eviction_suppressed = true;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		PopActiveSnapshot();
		AbortCurrentTransaction();
		vamana_eviction_suppressed = false;
		ereport(WARNING, (errmsg("vamana worker: SPI_connect failed")));
		return;
	}

	/*
	 * Find all Vamana index OIDs in this database.  We join through pg_class
	 * and pg_am so we don't hardcode an OID.
	 */
	ret = SPI_execute(
					  "SELECT c.oid "
					  "FROM pg_catalog.pg_class c "
					  "JOIN pg_catalog.pg_am a ON a.oid = c.relam "
					  "WHERE a.amname = 'vamana' AND c.relkind = 'i'",
					  true, 0);

	if (ret != SPI_OK_SELECT)
	{
		SPI_finish();
		PopActiveSnapshot();
		AbortCurrentTransaction();
		vamana_eviction_suppressed = false;
		ereport(WARNING, (errmsg("vamana worker: failed to enumerate indexes")));
		return;
	}

	nindexes = SPI_processed;
	oldctx = MemoryContextSwitchTo(TopMemoryContext);

	for (uint64 i = 0; i < nindexes; i++)
	{
		bool		isnull;
		Oid			relid = DatumGetObjectId(
											 SPI_getbinval(SPI_tuptable->vals[i],
														   SPI_tuptable->tupdesc,
														   1, &isnull));

		if (isnull)
			continue;

		MemoryContextSwitchTo(oldctx);

		(void) VamanaWorkerGetOrLoadIndex(relid);

		oldctx = MemoryContextSwitchTo(TopMemoryContext);
	}

	MemoryContextSwitchTo(oldctx);
	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

	/*
	 * A standby starts with no slots: base backup excludes pg_replslot, and the
	 * primary write path that creates them never runs here.  Bootstrap one per
	 * cached index now, outside any transaction as CreateOnStandby requires.
	 * Replay any committed changes that arrived after the last checkpoint.
	 *
	 * Keep eviction suppressed so that relcache invalidations fired during
	 * StartTransactionCommand do not evict entries between the OID snapshot
	 * and the VamanaGetCache lookup.
	 */
	{
		const VamanaReplayRole *role = VamanaGetReplayRole();
		Oid		relids[VAMANA_MAX_CACHED_INDEXES];
		int		n = VamanaGetAllCachedRelids(relids, VAMANA_MAX_CACHED_INDEXES);

		for (int i = 0; i < n; i++)
		{
			VamanaIndexCache *cache = VamanaGetCache(relids[i]);

			if (role->creates_slot_on_load &&
				cache != NULL && cache->replicationSlot == NULL)
			{
				VamanaReplicationCreateOnStandby(VamanaWorkerShmemPtr->dbOid,
												 relids[i]);
				cache->replicationSlot =
					VamanaReplicationOpen(VamanaWorkerShmemPtr->dbOid, relids[i]);
			}

			VamanaReplicationDrainSlot(relids[i]);
		}
	}

	vamana_eviction_suppressed = false;
}
