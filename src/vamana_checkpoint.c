/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_checkpoint.c
 *
 * Checkpoint subsystem for Vamana indexes.
 *
 * ShouldCheckpoint implements a two-mode debounce policy:
 *   - Debounce mode (default): fires when ops >= min_ops AND the index has
 *     been quiet for >= debounce_window, OR when ops >= min_ops AND the last
 *     checkpoint was more than max_interval seconds ago.
 *   - Simple mode (either checkpoint_operations > 0 or checkpoint_interval > 0):
 *     simple OR-logic, independent of the debounce policy.
 *
 * PerformCheckpoint executes a 5-phase atomic save:
 *   1-4. VamanaSaveIndexToDisk: write to temp files, fsync, atomic rename,
 *        fsync directory (includes the TID map via VamanaSaveTidMapAtomically).
 *   5.   VamanaSlotAdvance: advance confirmed_flush_lsn only after the save
 *        is durable, so replay from the prior LSN covers any gap on crash.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_checkpoint.h"
#include "vamana_replication.h"
#include "vamanaworker.h"

#include "access/xact.h"
#include "access/xlog.h"
#include "miscadmin.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

bool
ShouldCheckpoint(VamanaIndexCache *cache)
{
	TimestampTz now;
	long		elapsed_sec;
	long		quiet_sec;
	bool		enough_ops;

	/* A standby cannot persist (no WAL in recovery); it never checkpoints. */
	if (!VamanaGetReplayRole()->persists_index)
		return false;

	if (!cache->isValid || cache->svsIndex == NULL)
		return false;

	if (cache->checkpointInProgress)
		return false;

	now = GetCurrentTimestamp();

	/* Simple mode: either GUC is active; use OR-logic between the two triggers. */
	if (vamana_checkpoint_operations > 0 || vamana_checkpoint_interval > 0)
	{
		if (vamana_checkpoint_operations > 0 &&
			cache->opsSinceCheckpoint >= vamana_checkpoint_operations)
			return true;

		if (vamana_checkpoint_interval > 0)
		{
			elapsed_sec = (cache->lastCheckpointTime > 0)
				? (long) ((now - cache->lastCheckpointTime) / USECS_PER_SEC)
				: LONG_MAX;
			if (elapsed_sec >= vamana_checkpoint_interval)
				return true;
		}

		return false;
	}

	/* Debounce mode (default). */
	enough_ops = (cache->opsSinceCheckpoint >= vamana_checkpoint_min_ops);

	if (!enough_ops)
		return false;

	if (cache->lastWriteTime > 0 && vamana_checkpoint_debounce_window > 0)
	{
		quiet_sec = (long) ((now - cache->lastWriteTime) / USECS_PER_SEC);
		if (quiet_sec >= vamana_checkpoint_debounce_window)
			return true;
	}

	if (vamana_checkpoint_max_interval > 0)
	{
		elapsed_sec = (cache->lastCheckpointTime > 0)
			? (long) ((now - cache->lastCheckpointTime) / USECS_PER_SEC)
			: LONG_MAX;
		if (elapsed_sec >= vamana_checkpoint_max_interval)
			return true;
	}

	return false;
}

void
PerformCheckpoint(VamanaIndexCache *cache)
{
	Relation	indexRel;
	XLogRecPtr	checkpoint_lsn;

	Assert(!RecoveryInProgress());
	Assert(cache != NULL && cache->isValid);
	Assert(!cache->checkpointInProgress);

	cache->checkpointInProgress = true;

	/*
	 * Snapshot LSN before writing to disk so the slot is not advanced past
	 * WAL that arrived after we began.  Replay from this LSN on crash
	 * recovers any operations that landed after the snapshot.
	 */
	checkpoint_lsn = GetFlushRecPtr(NULL);

	indexRel = index_open(cache->indexRelid, AccessShareLock);

	PG_TRY();
	{
		/*
		 * Phases 1-4: write SVS graph and TID map to temp files, fsync,
		 * atomic rename, fsync directory.
		 * VamanaSaveIndexToDisk calls VamanaSaveTidMapAtomically internally.
		 */
		VamanaSaveIndexToDisk(indexRel, cache->svsIndex, MAIN_FORKNUM, cache);

		index_close(indexRel, AccessShareLock);
		indexRel = NULL;

		/* Phase 5: advance slot only after on-disk state is durable. */
		VamanaSlotAdvance(cache->replicationSlot, checkpoint_lsn);
	}
	PG_CATCH();
	{
		if (indexRel != NULL)
			index_close(indexRel, AccessShareLock);
		cache->checkpointInProgress = false;
		/*
		 * Re-throw so the BGW restarts.  The slot LSN has not advanced, so
		 * replay from the prior confirmed_flush_lsn recovers all changes.
		 */
		PG_RE_THROW();
	}
	PG_END_TRY();

	cache->opsSinceCheckpoint = 0;
	cache->lastCheckpointTime = GetCurrentTimestamp();
	cache->checkpointInProgress = false;

	ereport(DEBUG1,
			(errmsg("vamana index %u: checkpoint complete, slot advanced to %X/%X",
					cache->indexRelid, LSN_FORMAT_ARGS(checkpoint_lsn))));
}

/*
 * Checkpoint one cached index: the transaction/snapshot ritual around
 * PerformCheckpoint.  Suppresses eviction for the duration, because
 * AcceptInvalidationMessages inside StartTransactionCommand/index_open can fire
 * VamanaRelcacheCallback and free the SVSIndexHandle mid-save.  The PG_CATCH
 * only restores the suppression global and re-throws; it never absorbs the
 * error.
 */
void
VamanaCheckpointCachedIndex(VamanaIndexCache *cache)
{
	bool		prevSuppressed = vamana_eviction_suppressed;

	PG_TRY();
	{
		vamana_eviction_suppressed = true;
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		PerformCheckpoint(cache);
		PopActiveSnapshot();
		CommitTransactionCommand();
		vamana_eviction_suppressed = prevSuppressed;
	}
	PG_CATCH();
	{
		vamana_eviction_suppressed = prevSuppressed;
		PG_RE_THROW();
	}
	PG_END_TRY();
}
