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

#include "svs_memory.h"
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

/*
 * Returns true once the on-disk save and the slot advance both complete.
 * A busy slot leaves the on-disk save durable but the debounce counters
 * untouched, so ShouldCheckpoint retries the whole checkpoint -- including
 * the slot advance -- on a later cycle instead of this call being mistaken
 * for done.
 */
bool
PerformCheckpoint(VamanaIndexCache *cache)
{
	Relation volatile indexRel;
	bool volatile compactedOnDisk;
	XLogRecPtr	checkpoint_lsn;
	bool		slotAdvanced;

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

	indexRel = NULL;
	compactedOnDisk = false;

	{
		int			priorNumDeleted = cache->numDeleted;

		/*
		 * SVS's own save path consolidates and compacts the live graph
		 * before writing it out (MutableVamanaIndex::save), so the index
		 * this worker holds in memory has no soft-deleted rows left once
		 * VamanaSaveIndexToDisk's call to SVSSaveIndex succeeds -- even if
		 * a later step (the TID-map write, VamanaMarkIndexSaved, or
		 * anything below in this block) then fails. Zero this up front so
		 * a clean save persists a metapage that agrees with what was
		 * actually saved. The PG_CATCH below only restores it if
		 * compactedOnDisk never got set, i.e. the compaction itself never
		 * happened; otherwise it re-measures and reconciles instead of
		 * leaving accounting to drift until an unrelated later write
		 * happens to self-correct it.
		 */
		cache->numDeleted = 0;

		PG_TRY();
		{
			uint64		headroomVectors;

			/*
			 * Phases 1-4: write SVS graph and TID map to temp files, fsync,
			 * atomic rename, fsync directory.
			 * VamanaSaveIndexToDisk calls VamanaSaveTidMapAtomically internally.
			 */
			indexRel = index_open(cache->indexRelid, AccessShareLock);
			VamanaSaveIndexToDisk(indexRel, cache->svsIndex, MAIN_FORKNUM, cache,
								  &compactedOnDisk);

			/*
			 * The save just compacted the live graph in place, so this is
			 * the only reliable moment to re-measure it: without an insert
			 * or another write landing on this same index afterward,
			 * nothing else ever takes a fresh measurement, and both the
			 * residency counter and the reclaimable debt it is tracking
			 * would otherwise stay stale indefinitely.
			 */
			cache->residentBytes = SVSGetIndexMemoryUsage(cache->svsIndex);
			headroomVectors = VamanaRefreshIndexCapacityHeadroom(indexRel, cache->numVectors);

			index_close(indexRel, AccessShareLock);
			indexRel = NULL;

			SvsMemoryReconcileResident(MyDatabaseId, cache->indexRelid,
										cache->residentBytes, &headroomVectors);

			/* Advance slot only after on-disk state is durable. */
			slotAdvanced = VamanaSlotAdvance(cache->replicationSlot, checkpoint_lsn);
		}
		PG_CATCH();
		{
			if (!compactedOnDisk)
			{
				/* The save never got as far as compacting; nothing changed. */
				cache->numDeleted = priorNumDeleted;
			}
			else
			{
				/*
				 * The live graph was already compacted before this failed.
				 * The pre-attempt numDeleted and residency figures are both
				 * stale now, not merely unconfirmed, so commit the zeroed
				 * numDeleted and reconcile committed/reclaimable with a
				 * fresh measurement instead of reverting to a baseline that
				 * no longer matches reality.
				 *
				 * Capacity headroom is deliberately left untouched (NULL):
				 * recomputing it needs VamanaReadMetaPage, which would try
				 * to lock the index's metapage buffer, and a failure here
				 * (e.g. inside VamanaMarkIndexSaved) can leave that same
				 * buffer's content lock held by this backend until the
				 * transaction aborts, well after this catch block runs --
				 * reading it now would self-deadlock. Compaction never
				 * changes vector count, so the reservation's existing
				 * headroom figure is still correct.
				 */
				cache->numDeleted = 0;
				cache->residentBytes = SVSGetIndexMemoryUsage(cache->svsIndex);

				SvsMemoryReconcileResident(MyDatabaseId, cache->indexRelid,
											cache->residentBytes, NULL);
			}

			if (indexRel != NULL)
				index_close(indexRel, AccessShareLock);
			/*
			 * The slot LSN has not advanced, so replay from the prior
			 * confirmed_flush_lsn recovers all changes regardless of how the
			 * caller handles this error.
			 */
			cache->checkpointInProgress = false;
			PG_RE_THROW();
		}
		PG_END_TRY();
	}

	cache->checkpointInProgress = false;

	if (!slotAdvanced)
		return false;

	cache->opsSinceCheckpoint = 0;
	cache->lastCheckpointTime = GetCurrentTimestamp();

	ereport(DEBUG1,
			(errmsg("vamana index %u: checkpoint complete, slot advanced to %X/%X",
					cache->indexRelid, LSN_FORMAT_ARGS(checkpoint_lsn))));

	return true;
}

/*
 * Checkpoint one cached index: the transaction/snapshot ritual around
 * PerformCheckpoint.  Suppresses eviction for the duration, because
 * AcceptInvalidationMessages inside StartTransactionCommand/index_open can fire
 * VamanaRelcacheCallback and free the SVSIndexHandle mid-save.  The PG_CATCH
 * only restores the suppression global and re-throws; it never absorbs the
 * error.
 */
bool
VamanaCheckpointCachedIndex(VamanaIndexCache *cache)
{
	bool		prevSuppressed = vamana_eviction_suppressed;
	bool		completed;

	PG_TRY();
	{
		vamana_eviction_suppressed = true;
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		completed = PerformCheckpoint(cache);
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

	return completed;
}
