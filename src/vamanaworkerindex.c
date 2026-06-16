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
				 * Table has 0 vectors.  Cache an empty entry so subsequent
				 * lookups return quickly with 0 results instead of retrying
				 * the rebuild each time.
				 */
				VamanaOptions *opts = (VamanaOptions *) indexRel->rd_options;
				int		dims = TupleDescAttr(indexRel->rd_att, 0)->atttypmod;

				VamanaCacheIndex(relid, NULL, dims,
								opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE,
								opts ? opts->alpha : VAMANA_DEFAULT_ALPHA,
								NULL, 0, 0, 0, 0);
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

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		PopActiveSnapshot();
		AbortCurrentTransaction();
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
}
