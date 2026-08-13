/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworker.c
 *
 * Background worker for Vamana index.  A single dedicated process holds the
 * SVS index permanently and serves search requests from client backends via
 * shared memory.  Backends write query vectors into a per-backend slot and
 * wait on a shared latch; the worker drains all pending slots as one batch,
 * runs SVSSearch for each, and wakes the originating backends.
 *
 * This file contains: signal handlers, the main event loop and its helpers
 * (ProcessRequests, ProcessReloads), and the backend-side IPC API used by
 * client backends to submit operations and wait for results.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_checkpoint.h"
#include "vamana_replication.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/xact.h"
#include "access/xlog.h"
#include "commands/dbcommands.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "replication/slot.h"
#include "replication/walreceiver.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "tcop/tcopprot.h"
#include "utils/injection_point.h"
#include "utils/inval.h"
#include "utils/timestamp.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

/*
 * PG 17 renamed BackendId/MyBackendId → ProcNumber/MyProcNumber.
 * PG_WAIT_EXTENSION moved from pgstat.h to utils/wait_classes.h in PG 17.
 */
#if PG_VERSION_NUM >= 170000
#include "storage/procnumber.h"
#include "utils/wait_classes.h"
#define VAMANA_MY_SLOT_IDX		((int) MyProcNumber)
#else
#include "pgstat.h"
#define VAMANA_MY_SLOT_IDX		(MyBackendId - 1)
#endif

/* -----------------------------------------------------------------------
 * Signal flags (worker process only)
 * ----------------------------------------------------------------------- */

volatile sig_atomic_t worker_got_sigterm = false;
volatile sig_atomic_t worker_got_sighup = false;

/*
 * Set while an index load or slot drain is in progress.  VamanaRelcacheCallback
 * checks this flag to avoid evicting entries the load path is populating.
 */
bool		vamana_eviction_suppressed = false;

/*
 * Set by VamanaRelcacheCallback when a relid outside the cache is invalidated;
 * cleared by the main loop after it reconciles.  A standby has no other signal
 * that a vamana index was created or dropped on the primary.
 */
bool		standbyRediscoverPending = false;

/* -----------------------------------------------------------------------
 * Signal handlers (worker process only)
 * ----------------------------------------------------------------------- */

static void
VamanaWorkerSigterm(SIGNAL_ARGS)
{
	int			save_errno = errno;

	/*
	 * Record durable shutdown intent and raise a catchable cancel so any core
	 * primitive blocked in a CHECK_FOR_INTERRUPTS wait (e.g. the decoding
	 * startpoint scan during slot creation) unwinds via ERROR back to the main
	 * loop, which then drains and exits.  A catchable cancel, not ProcDiePending:
	 * FATAL here would abandon the drain.  Guarded like core's
	 * StatementCancelHandler so we do not joggle proc_exit.
	 */
	if (!proc_exit_inprogress)
	{
		worker_got_sigterm = true;
		InterruptPending = true;
		QueryCancelPending = true;
	}
	SetLatch(MyLatch);
	errno = save_errno;
}

static void
VamanaWorkerSighup(SIGNAL_ARGS)
{
	int			save_errno = errno;

	worker_got_sighup = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

bool
VamanaShutdownCancelPending(void)
{
	return worker_got_sigterm && geterrcode() == ERRCODE_QUERY_CANCELED;
}

/* -----------------------------------------------------------------------
 * Worker main loop helpers
 * ----------------------------------------------------------------------- */

/*
 * VamanaWorkerDispatchWriteSlot
 *
 * Route one non-SEARCH slot to its kind-specific processor.  Parallels
 * VamanaWorkerDispatchBatch on the search side.
 */
static void
VamanaWorkerDispatchWriteSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];

	if (slot->slotKind == VAMANA_SLOTKIND_LOAD)
		VamanaWorkerProcessLoadSlot(slotIdx);
	else if (slot->slotKind == VAMANA_SLOTKIND_WARMUP)
		VamanaWorkerProcessWarmupSlot(slotIdx);
	else
		VamanaWorkerProcessWriteSlot(slotIdx);
}

/*
 * VamanaWorkerProcessRequests
 *
 * Collect all PENDING slots, transition them to PROCESSING.
 * SEARCH slots are batched and dispatched together via VamanaWorkerDispatchBatch.
 * Write slots (INSERT/DELETE/MAINTENANCE) are processed individually via
 * VamanaWorkerDispatchWriteSlot, which holds LW_EXCLUSIVE for the duration.
 * After all processing, wake every waiting backend.
 */
static void
VamanaWorkerProcessRequests(void)
{
	int		   *searchPending;
	int		   *writePending;
	int			numSearch = 0;
	int			numWrite = 0;
	int			maxBatch;
	int			numTotal = 0;
	int		   *allPending;

	maxBatch = (vamana_max_batch_size > 0) ? vamana_max_batch_size : MaxBackends;

	searchPending = palloc(MaxBackends * sizeof(int));
	writePending = palloc(MaxBackends * sizeof(int));
	allPending = palloc(MaxBackends * sizeof(int));

	/* Collect all PENDING slots (single worker, no contention here) */
	for (int i = 0;
		 i < VamanaWorkerShmemPtr->maxSlots && numTotal < maxBatch;
		 i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];

		if (pg_atomic_read_u32(&slot->status) == VAMANA_SLOT_PENDING)
		{
			pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PROCESSING);
			allPending[numTotal++] = i;

			if (slot->slotKind == VAMANA_SLOTKIND_SEARCH)
				searchPending[numSearch++] = i;
			else
				writePending[numWrite++] = i;
		}
	}

	if (numTotal == 0)
	{
		pfree(searchPending);
		pfree(writePending);
		pfree(allPending);
		return;
	}

	ereport(DEBUG1,
			(errmsg("vamana worker: dispatching %d search + %d write request(s)",
					numSearch, numWrite)));

	/* Process searches as a batch (LW_SHARED). Searches run in either role. */
	if (numSearch > 0)
		VamanaWorkerDispatchBatch(searchPending, numSearch);

	/*
	 * Write/load slots mutate the index and open write transactions, which is
	 * illegal in recovery.  A read-only standby never enqueues them; the role
	 * gate makes that a hard guarantee rather than an assumption.
	 */
	if (VamanaGetReplayRole()->processes_write_ipc)
	{
		for (int i = 0; i < numWrite; i++)
			VamanaWorkerDispatchWriteSlot(writePending[i]);
	}

	/* Wake all waiting backends */
	for (int i = 0; i < numTotal; i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[allPending[i]];

		SetLatch(&slot->latch);
	}

	pfree(searchPending);
	pfree(writePending);
	pfree(allPending);
}

/*
 * VamanaWorkerProcessReloads
 *
 * Check the reload queue for OIDs that backends have signaled need
 * reloading (after INSERT/UPDATE/DELETE/REINDEX).  For each pending OID,
 * reload the index from disk (or rebuild) and clear the queue entry.
 *
 * Must NOT use SIGUSR1: that signal is owned by PostgreSQL's ProcSignal
 * infrastructure.  This polling approach is the correct alternative.
 */
static void
VamanaWorkerProcessReloads(void)
{
	bool		anyReload = false;

	/*
	 * A backend sets evict_all when the per-OID queue overflows and the dropped
	 * OIDs are unknown.  Evict every cached entry so the next request for each
	 * reloads a fresh copy on demand.
	 */
	if (pg_atomic_exchange_u32(&VamanaWorkerShmemPtr->evict_all, 0) != 0)
	{
		ereport(LOG,
				(errmsg("vamana worker: evict_all set, evicting all cached indexes")));
		VamanaEvictAllCacheEntries();
		return;
	}

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
	{
		uint32		relid_u32;
		Oid			relid;

		relid_u32 = pg_atomic_read_u32(
									   &VamanaWorkerShmemPtr->reloadRequests[i].relid);
		if (relid_u32 == 0)
			continue;

		relid = (Oid) relid_u32;

		/*
		 * Clear the slot first (before loading) so that a new invalidation
		 * that arrives during the load is not silently lost.
		 */
		pg_atomic_write_u32(
							&VamanaWorkerShmemPtr->reloadRequests[i].relid, 0);

		ereport(LOG,
				(errmsg("vamana worker: reloading index %u", relid)));

		/*
		 * Evict only the in-process cache entry so VamanaWorkerGetOrLoadIndex
		 * picks up the fresh on-disk copy.  Do NOT use
		 * VamanaInvalidateCache() here: that would delete the on-disk saved
		 * copy (preventing reload from disk) and re-signal the worker
		 * (causing a reload loop).
		 */
		VamanaEvictCacheEntry(relid);
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());

		vamana_eviction_suppressed = true;
		(void) VamanaWorkerGetOrLoadIndex(relid, NULL);
		vamana_eviction_suppressed = false;

		PopActiveSnapshot();
		CommitTransactionCommand();

		anyReload = true;
	}

	(void) anyReload;
}

/* -----------------------------------------------------------------------
 * Worker main entry point
 * ----------------------------------------------------------------------- */

/*
 * VACUUM FULL / CLUSTER replace the relfilenode without triggering any
 * extension AM callback.  This relcache callback catches those cases so
 * the BGW doesn't serve stale TIDs from the old heap.
 */
static void
VamanaRelcacheCallback(Datum arg, Oid relid)
{
	if (relid == InvalidOid || VamanaGetCache(relid) == NULL)
		standbyRediscoverPending = true;

	if (vamana_eviction_suppressed)
		return;

	if (relid == InvalidOid)
		VamanaEvictAllCacheEntries();
	else
		VamanaEvictCacheEntry(relid);
}

/*
 * Drain each cached index's replication slot into its in-memory graph.  A slot
 * that has fallen past max_slot_wal_size is cheaper to drop and rebuild from the
 * heap than to drain, and doing so bounds the WAL it pins on the primary.
 */
static void
VamanaWorkerDrainAllSlots(void)
{
	Oid			relids[VAMANA_MAX_CACHED_INDEXES];
	int			n = VamanaGetAllCachedRelids(relids, VAMANA_MAX_CACHED_INDEXES);

	for (int i = 0; i < n; i++)
	{
		Oid			relid = relids[i];

		if (VamanaReplicationSlotWalLagExceeds(relid, vamana_max_slot_wal_size_mb))
		{
			ereport(LOG,
					(errmsg("vamana replay: slot for index %u exceeds "
							"max_slot_wal_size (%d MB); rebuilding from heap",
							relid, vamana_max_slot_wal_size_mb)));
			VamanaForceHeapRebuild(relid);
		}
		else
			VamanaReplicationDrainSlot(relid);
	}
}

/*
 * Counter-maintenance policy.  indexCount tracks live vamana indexes via
 * CREATE/DROP commit-deltas plus a startup seed — a write path that exists only
 * on the primary.  A standby has no delta path and cannot run the seed, so its
 * counter is not maintained and readers must treat it as absent, not stale.
 */
bool
VamanaIndexCountIsMaintained(void)
{
	return VamanaNodeIsPrimary();
}

/*
 * Worker-lifetime state for the zero-index log-once.  A worker serves one
 * database, so "have I already warned?" is process-local and needs no lock.
 * dbname is captured once in the startup transaction (a catalog lookup in the
 * txn-less heartbeat loop would segfault).
 */
typedef struct VamanaZeroIndexState
{
	char	   *dbname;			/* TopMemoryContext-owned; worker lifetime */
	bool		warned;			/* true once warned; re-armed on return to nonzero */
} VamanaZeroIndexState;

/*
 * Capture this database's name into TopMemoryContext for the worker's lifetime.
 * Must run inside a transaction: get_database_name reads a catalog.
 */
static char *
VamanaWorkerCaptureDatabaseName(void)
{
	char	   *name = get_database_name(MyDatabaseId);

	return name != NULL ? MemoryContextStrdup(TopMemoryContext, name) : NULL;
}

/*
 * Emit one LOG when this worker's index count reaches zero, once per transition
 * into that state, re-arming when the count returns to nonzero.  Primary-only:
 * indexCount is meaningless where it is not maintained.  Runs in the txn-less
 * heartbeat loop, so it reads only the atomic and the pre-captured name.
 */
static void
VamanaWorkerMaybeWarnZeroIndex(VamanaZeroIndexState *state)
{
	if (!VamanaIndexCountIsMaintained())
		return;

	if (pg_atomic_read_u32(&VamanaWorkerShmemPtr->indexCount) == 0)
	{
		if (!state->warned)
		{
			ereport(LOG,
					(errmsg("vamana worker for database \"%s\" has no Vamana indexes",
							state->dbname),
					 errhint("consider removing its row from vamana_databases")));
			state->warned = true;
		}
	}
	else
		state->warned = false;
}

/*
 * Seed indexCount to the live count of vamana indexes in this database.
 *
 * indexCount otherwise only moves on CREATE/DROP commit-deltas, so after a
 * postmaster restart a fully-populated database would read zero until the next
 * DDL — misinforming the zero-index log-once, the SRF, and the BEFORE DELETE gate.
 *
 * This is the single absolute write to the counter; CREATE/DROP are relative
 * deltas.  The ordering holds because the worker performs this in its own
 * startup transaction, before the heartbeat loop, and a backend's CREATE/DROP
 * cannot commit a delta until the database is already being served.
 *
 * Primary-only and caller-gated on VamanaIndexCountIsMaintained().  Must run
 * inside the worker's startup transaction (VamanaWorkerEnumerateIndexes needs
 * a live transaction and snapshot).
 */
void
VamanaWorkerSeedIndexCount(void)
{
	List	   *relids = VamanaWorkerEnumerateIndexes();

	pg_atomic_write_u32(&VamanaWorkerShmemPtr->indexCount,
						(uint32) list_length(relids));
	list_free(relids);
}

/*
 * VamanaWorkerStopAccepting: close the request intake with a full barrier so
 * the drain's final sweep is ordered after every enqueue that observed the
 * worker as accepting.  The full barrier is required: the enqueue side pairs
 * its accepting load with a write barrier over the slot metadata, and a plain
 * store would not establish the store/load ordering.
 */
static void
VamanaWorkerStopAccepting(void)
{
	pg_atomic_write_membarrier_u32(&VamanaWorkerShmemPtr->accepting, 0);
}

/*
 * VamanaWorkerDrainFinalCheckpoint: flush every cached index to disk one last
 * time before exit.  Unlike the steady-state sweep this ignores ShouldCheckpoint
 * debounce.  Best-effort: one index's failure must not abandon the rest, so each
 * checkpoint runs under its own PG_TRY and a failure is logged and skipped.
 *
 * Bounded by svs.shutdown_drain_budget_ms, tested before each index so a slow
 * SVS-library checkpoint cannot hold the postmaster past its shutdown escalation
 * window.  The bound is granular, not hard: a single in-progress checkpoint is
 * not preemptible, so the real limit is the budget plus one checkpoint's worst
 * case.  Indexes not reached are left at their last debounced LSN and logged.
 *
 * Primary only.  A standby never persists (PerformCheckpoint asserts
 * !RecoveryInProgress), so the caller must not reach here in recovery.
 */
static void
VamanaWorkerDrainFinalCheckpoint(void)
{
	Oid			cached_relids[VAMANA_MAX_CACHED_INDEXES];
	int			ncached;
	TimestampTz	drainStart = GetCurrentTimestamp();

	ncached = VamanaGetAllCachedRelids(cached_relids, VAMANA_MAX_CACHED_INDEXES);
	for (int ci = 0; ci < ncached; ci++)
	{
		VamanaIndexCache *cache = VamanaGetCache(cached_relids[ci]);

		if (cache == NULL || !cache->isValid || cache->svsIndex == NULL)
			continue;

		if (TimestampDifferenceExceeds(drainStart, GetCurrentTimestamp(),
									   vamana_shutdown_drain_budget_ms))
		{
			ereport(LOG,
					(errmsg("vamana shutdown: drain budget of %d ms exhausted; "
							"%d of %d indexes not checkpointed",
							vamana_shutdown_drain_budget_ms, ncached - ci, ncached)));
			return;
		}

		PG_TRY();
		{
			VamanaCheckpointCachedIndex(cache);
		}
		PG_CATCH();
		{
			EmitErrorReport();
			FlushErrorState();
			AbortCurrentTransaction();
			ereport(LOG,
					(errmsg("vamana shutdown: index %u not checkpointed",
							cached_relids[ci])));
		}
		PG_END_TRY();

		INJECTION_POINT("vamana-drain-checkpoint-slow", NULL);

		pg_atomic_write_u64(&VamanaWorkerShmemPtr->heartbeat_ts,
							(uint64) GetCurrentTimestamp());
	}
}

/*
 * VamanaWorkerDrainAndStop: shutdown sequence run after the main loop breaks on
 * SIGTERM.  Owns the clean exit.  Defuses the cancel the handler raised so it
 * cannot re-fire inside shutdown's own transactions, drains, then exits.
 *
 * A standby feeds its index by decoding WAL and never persists, so it takes a
 * final slot drain instead of a checkpoint; a primary flushes every cached
 * index to disk.
 */
static pg_noreturn void
VamanaWorkerDrainAndStop(void)
{
	QueryCancelPending = false;

	ereport(LOG, (errmsg("vamana background worker shutting down")));

	/*
	 * Close intake, then clear workerPid, then sweep once.  Backends re-check
	 * accepting after publishing their metadata, so anything published before
	 * the barrier is serviced by this final sweep; a late publisher sees intake
	 * closed and falls back to its own bounded wait.
	 */
	VamanaWorkerStopAccepting();
	VamanaWorkerShmemPtr->workerPid = 0;
	VamanaWorkerProcessRequests();

	if (VamanaGetReplayRole()->persists_index)
		VamanaWorkerDrainFinalCheckpoint();
	else
		VamanaWorkerDrainAllSlots();

	DisownLatch(&VamanaWorkerShmemPtr->workerLatch);
	proc_exit(0);
}

/*
 * Blocking slot-activation policy for VamanaReconcileStandbyCache: waits for
 * the primary's next xl_running_xacts if needed.  Only safe before workerPid
 * is published, since it can block the caller for as long as that record
 * takes to arrive.
 */
static void
VamanaStandbyActivateSlotBlocking(Oid relid)
{
	VamanaReplicationEnsureSlot(VamanaWorkerShmemPtr->dbOid, relid);
}

/*
 * Bounded slot-activation policy for VamanaReconcileStandbyCache: creates the
 * slot if missing (pins restart_lsn, does not block), then scans WAL only up
 * to the locally-replayed end.  Safe to call every main-loop pass; a pass
 * that does not reach consistency leaves the slot for the next pass to retry.
 */
static void
VamanaStandbyActivateSlotBounded(Oid relid)
{
	Oid					dbOid = VamanaWorkerShmemPtr->dbOid;
	VamanaIndexCache   *cache = VamanaGetCache(relid);

	if (cache == NULL)
		return;

	if (cache->replicationSlot == NULL)
	{
		VamanaReplicationCreate(dbOid, relid);
		cache->replicationSlot = VamanaReplicationOpen(dbOid, relid);
	}

	VamanaReplicationActivateSlotBounded(dbOid, relid);
}

/*
 * VamanaWorkerRunStartupTransaction: capture the database name for the
 * txn-less heartbeat loop, log readiness, and seed indexCount from the live
 * catalog (primary-only — a standby neither maintains the counter nor can
 * run the enumerating SPI).  Catalog access and SPI both require a live
 * transaction and snapshot, which only this call provides.
 */
static void
VamanaWorkerRunStartupTransaction(VamanaZeroIndexState *zeroIndexState)
{
	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());
	zeroIndexState->dbname = VamanaWorkerCaptureDatabaseName();
	ereport(LOG, (errmsg("vamana background worker started for database \"%s\"",
						 zeroIndexState->dbname)));
	if (VamanaIndexCountIsMaintained())
		VamanaWorkerSeedIndexCount();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/*
 * VamanaWorkerHandlePromotion: detect a standby -> primary flip since the
 * last call and, if one occurred, drain once more to absorb WAL that
 * streamed in before the flip.  PG hands the promoted primary the
 * standby-era logical slot intact, positioned at the last replay LSN, so
 * there is nothing to drop or recreate — only this one final drain before
 * steady-state writes take over via IPC.  Owns *wasReplayingWal end to end:
 * the caller neither reads it beforehand nor updates it after.
 */
static void
VamanaWorkerHandlePromotion(bool *wasReplayingWal, const VamanaReplayRole *role)
{
	if (*wasReplayingWal && !role->creates_slot_on_load)
	{
		ereport(LOG,
				(errmsg("vamana replay: standby promoted to primary; "
						"continuing replay on inherited slots")));
		VamanaWorkerDrainAllSlots();
	}
	*wasReplayingWal = role->creates_slot_on_load;
}

/*
 * VamanaWorkerCheckpointDueIndexes: flush each cached index whose debounce
 * policy says it is time.  The snapshot of OIDs is taken before the loop so
 * a mid-loop eviction does not invalidate the iterator; VamanaGetCache
 * returns NULL for any OID that was evicted by then.
 */
static void
VamanaWorkerCheckpointDueIndexes(void)
{
	Oid		cached_relids[VAMANA_MAX_CACHED_INDEXES];
	int		ncached;

	ncached = VamanaGetAllCachedRelids(cached_relids, VAMANA_MAX_CACHED_INDEXES);
	for (int ci = 0; ci < ncached; ci++)
	{
		VamanaIndexCache *cache = VamanaGetCache(cached_relids[ci]);

		if (cache == NULL || !ShouldCheckpoint(cache))
			continue;

		VamanaCheckpointCachedIndex(cache);
	}
}

/*
 * Bootstrap the standby cache, announce readiness, then service requests until
 * a shutdown is requested.  A shutdown cancel raised anywhere in this span —
 * including the blocking slot activation that waits on the primary's WAL —
 * propagates out to the drain owner in VamanaWorkerMain rather than being
 * handled here.
 */
static void
VamanaWorkerServe(VamanaZeroIndexState *zeroIndexState)
{
	/* Tracks the role era so VamanaWorkerHandlePromotion can detect a flip. */
	bool		wasReplayingWal;

	/*
	 * A standby has no demand path to populate its cache.  Do it up front, and
	 * before workerPid is set: blocking slot activation waits on the primary's
	 * WAL, which would starve the heartbeat if it ran inside the main loop.
	 */
	if (VamanaGetReplayRole()->creates_slot_on_load)
	{
		List *relids = VamanaWorkerEnumerateAllIndexes();

		(void) VamanaReconcileStandbyCache(relids, VamanaStandbyActivateSlotBlocking);
	}

	/* Non-zero pid marks the worker available to backends. */
	pg_atomic_write_membarrier_u32(&VamanaWorkerShmemPtr->accepting, 1);
	VamanaWorkerShmemPtr->workerPid = MyProcPid;

	VamanaWorkerRunStartupTransaction(zeroIndexState);

	wasReplayingWal = VamanaGetReplayRole()->creates_slot_on_load;

	while (!worker_got_sigterm)
	{
		int			rc;
		const VamanaReplayRole *role = VamanaGetReplayRole();

		rc = WaitLatch(&VamanaWorkerShmemPtr->workerLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   1000L,	/* 1-second heartbeat */
					   PG_WAIT_EXTENSION);

		ResetLatch(&VamanaWorkerShmemPtr->workerLatch);

		pg_atomic_write_u64(&VamanaWorkerShmemPtr->heartbeat_ts,
							(uint64) GetCurrentTimestamp());

		if (rc & WL_POSTMASTER_DEATH)
		{
			DisownLatch(&VamanaWorkerShmemPtr->workerLatch);
			proc_exit(1);
		}

		if (worker_got_sigterm)
			break;

		CHECK_FOR_INTERRUPTS();

		if (worker_got_sighup)
		{
			ProcessConfigFile(PGC_SIGHUP);
			worker_got_sighup = false;
		}

		VamanaWorkerProcessReloads();

		/*
		 * Process pending search requests on every iteration, not only when
		 * the latch was set.  A latch set can race WL_TIMEOUT attribution,
		 * leaving a PENDING slot unprocessed for up to 1 s otherwise.
		 */
		VamanaWorkerProcessRequests();

		VamanaWorkerMaybeWarnZeroIndex(zeroIndexState);

		if (!role->processes_write_ipc && standbyRediscoverPending)
		{
			List *relids;

			standbyRediscoverPending = false;
			relids = VamanaWorkerEnumerateAllIndexes();
			if (!VamanaReconcileStandbyCache(relids, VamanaStandbyActivateSlotBounded))
				standbyRediscoverPending = true;
			list_free(relids);
		}

		/*
		 * A standby feeds its index by decoding streamed WAL; a primary feeds
		 * it from write IPC.  These are the two ways index changes arrive, so
		 * the drain is exactly the branch the write dispatch is not.
		 */
		if (!role->processes_write_ipc)
			VamanaWorkerDrainAllSlots();

		VamanaWorkerHandlePromotion(&wasReplayingWal, role);

		VamanaWorkerCheckpointDueIndexes();
	}
}

/*
 * Reset to a clean state after absorbing a shutdown cancel: release any slot
 * the interrupted replay held, abort its open transaction, and clear the error
 * so the drain runs on a well-defined footing.
 */
static void
VamanaWorkerResetAfterShutdownCancel(void)
{
	HOLD_INTERRUPTS();
	if (MyReplicationSlot != NULL)
		ReplicationSlotRelease();
	AbortOutOfAnyTransaction();
	FlushErrorState();
	RESUME_INTERRUPTS();
}

PGDLLEXPORT void
VamanaWorkerMain(Datum main_arg)
{
	/* Zero-index log-once state; dbname captured in the startup transaction. */
	VamanaZeroIndexState zeroIndexState = {0};

	/*
	 * Set up signal handlers.  Do NOT override SIGUSR1: it is owned by
	 * PostgreSQL's ProcSignal infrastructure.
	 */
	pqsignal(SIGTERM, VamanaWorkerSigterm);
	pqsignal(SIGHUP, VamanaWorkerSighup);
	BackgroundWorkerUnblockSignals();

	if (wal_level < WAL_LEVEL_LOGICAL)
		ereport(FATAL,
				(errmsg("vamana background worker requires wal_level = logical"),
				 errhint("Set wal_level = logical in postgresql.conf and restart.")));

	BackgroundWorkerInitializeConnectionByOid(DatumGetObjectId(main_arg), InvalidOid, 0);

	INJECTION_POINT("vamana-worker-startup-crash", NULL);

	CacheRegisterRelcacheCallback(VamanaRelcacheCallback, (Datum) 0);

	/*
	 * Claim this database's control block and cache the pointer for the
	 * worker's lifetime.  Backends resolve the same block on demand via
	 * VamanaWorkerLookupSlot(MyDatabaseId).
	 */
	VamanaWorkerShmemPtr = VamanaWorkerReserveSlot(MyDatabaseId);
	if (VamanaWorkerShmemPtr == NULL)
		ereport(FATAL,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("cannot start vamana worker: svs.max_databases (%d) already reached",
						max_vamana_databases)));

	/*
	 * A reused block may carry a previous instance's liveness state: a crash
	 * exits without releasing the slot, so its pid and heartbeat survive.  The
	 * worker owns these fields; reset them before announcing readiness.
	 */
	VamanaWorkerShmemPtr->workerPid = 0;
	pg_atomic_write_u64(&VamanaWorkerShmemPtr->heartbeat_ts, 0);
	InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);
	OwnLatch(&VamanaWorkerShmemPtr->workerLatch);

	/*
	 * A standby's logical slot reads catalog rows the primary must not VACUUM
	 * away.  That protection depends on hot_standby_feedback pinning the
	 * primary's catalog_xmin; without it the slot is silently invalidated and
	 * replay stops.  Warn loudly rather than fail: the node still serves reads
	 * from the base-backup index, just without live replay.
	 */
	if (VamanaGetReplayRole()->creates_slot_on_load && !hot_standby_feedback)
		ereport(WARNING,
				(errmsg("vamana replay on standby requires hot_standby_feedback = on"),
				 errhint("Set hot_standby_feedback = on and connect via primary_slot_name, "
						 "or the replication slot will be invalidated and replay will stop.")));

	VamanaWorkerResetStaleSlots();

	/*
	 * Own the drain: a SIGTERM raises a catchable cancel so a blocked primitive
	 * (e.g. the standby slot bootstrap's startpoint scan) unwinds here rather
	 * than at proc_exit.  Absorb only that cancel and fall through to the single
	 * drain; any other error re-throws and restarts the worker.
	 */
	PG_TRY();
	{
		VamanaWorkerServe(&zeroIndexState);
	}
	PG_CATCH();
	{
		if (!VamanaShutdownCancelPending())
			PG_RE_THROW();
		VamanaWorkerResetAfterShutdownCancel();
	}
	PG_END_TRY();

	VamanaWorkerDrainAndStop();
}

/* -----------------------------------------------------------------------
 * Backend-side API
 * ----------------------------------------------------------------------- */

/*
 * VamanaHeartbeatIsStale: pure staleness test over a raw heartbeat value and a
 * reference clock.  A worker that has never beaten (rawHb == 0) is not stale;
 * otherwise it is stale once the most recent beat is older than
 * VAMANA_HEARTBEAT_STALE_MS, meaning the main loop has stopped — hung inside a
 * library call, unable to drain slots or update its timestamp.
 *
 * One definition of "stale", shared by the live entry-path wrapper below and
 * the snapshot-path worker-state classifier.
 */
bool
VamanaHeartbeatIsStale(uint64 rawHb, TimestampTz now)
{
	long		age_ms;

	if (rawHb == 0)
		return false;

	age_ms = (long) ((now - (TimestampTz) rawHb) / 1000);
	return age_ms > VAMANA_HEARTBEAT_STALE_MS;
}

/*
 * VamanaWorkerHeartbeatStale: entry-path wrapper reading the live atomic and
 * the current clock, then delegating to the pure kernel.
 */
static bool
VamanaWorkerHeartbeatStale(VamanaWorkerShmem *entry)
{
	return VamanaHeartbeatIsStale(pg_atomic_read_u64(&entry->heartbeat_ts),
								  GetCurrentTimestamp());
}

/*
 * VamanaWorkerFindActiveSlot: the control block iff a live worker is currently
 * serving this backend's database, else NULL.  NULL distinguishes only
 * "no ready worker" from "ready"; callers that must tell "database not enabled"
 * apart from "worker still starting" use VamanaWorkerLookupSlot directly.
 */
VamanaWorkerShmem *
VamanaWorkerFindActiveSlot(void)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(MyDatabaseId);

	if (entry == NULL || entry->workerPid == 0)
		return NULL;
	if (VamanaWorkerHeartbeatStale(entry))
		return NULL;

	return entry;
}

/*
 * VamanaWorkerIsAvailable: true if the worker is running and serving the
 * current backend's database.
 */
bool
VamanaWorkerIsAvailable(void)
{
	return VamanaWorkerFindActiveSlot() != NULL;
}

/*
 * VamanaWorkerAssertDatabase
 *
 * Answer only the config question: is this database enabled for vamana?  A
 * permanent misconfiguration must fail fast (no amount of waiting fixes it);
 * everything else returns silently and lets the liveness loop in
 * VamanaWorkerWaitUntilAvailable bound any transient.
 *
 * "No slot" is authoritative for "not configured" only after the launcher has
 * materialized the config table into shmem (initialScanDone).  Before that, an
 * enabled database is indistinguishable from an unconfigured one, so the guard
 * must not commit to an error.  A configured database whose slot could not be
 * reserved because the array is full is a distinct, separately-diagnosed error.
 */
void
VamanaWorkerAssertDatabase(void)
{
	if (VamanaWorkerLookupSlot(MyDatabaseId) != NULL)
		return;

	if (!VamanaWorkerInitialScanDone())
		return;

	/*
	 * An enabled database reaches this point only if its slot could not be
	 * reserved.  Reservation happens at PRE_COMMIT when enabled = true commits,
	 * and a full array fails that commit, so an enabled row is never visible
	 * without a slot.  This branch is therefore a defensive guard, unreachable
	 * through the catalog path; it diagnoses exhaustion distinctly from the
	 * not-enabled case below should the invariant ever be violated.
	 */
	if (VamanaWorkerSlotsExhausted())
		ereport(ERROR,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("vamana worker slots exhausted"),
				 errhint("Increase svs.max_databases and restart the server.")));

	ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("vamana index is not enabled for this database"),
			 errhint("Enable it by inserting a row into vamana_databases for this database.")));
}

/*
 * VamanaWorkerWaitUntilAvailable
 *
 * Spin-wait for the background worker to finish startup.  Once the BGW sets
 * workerPid in shared memory this returns immediately.  If the worker does not
 * become available within vamana_worker_startup_timeout_ms milliseconds, an
 * ERROR is thrown so the caller gets an actionable message rather than silent
 * data loss or stale results.
 *
 * This uses a different timeout than vamana_worker_timeout_ms (IPC response
 * time) because startup can take well over 5 s when there are many large
 * indexes to deserialize from disk.
 */
void
VamanaWorkerWaitUntilAvailable(Oid indexRelid, const char *operation)
{
	VamanaWorkerShmem *entry;
	int			total_waited_ms = 0;

	/*
	 * An unconfigured database is a permanent error; no worker will ever serve
	 * it.  A configured-but-not-yet-reserved database is the normal startup
	 * window and must be waited out, so re-resolve the live slot each iteration
	 * rather than caching a pointer that does not exist yet.  AssertDatabase is
	 * re-called each iteration too: the instant initialScanDone flips true with
	 * still no slot, the next call throws the crisp config error instead of
	 * spinning to startup_timeout_ms.
	 */
	VamanaWorkerAssertDatabase();

	if (VamanaWorkerFindActiveSlot() != NULL)
		return;

	/*
	 * A non-zero heartbeat with no live pid means the worker ran, then hung or
	 * died — fail immediately rather than spinning for startup_timeout_ms.
	 */
	entry = VamanaWorkerLookupSlot(MyDatabaseId);
	if (entry != NULL && pg_atomic_read_u64(&entry->heartbeat_ts) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("vamana background worker unavailable after waiting up to %d ms; cannot %s index %u",
						VAMANA_HEARTBEAT_STALE_MS, operation, indexRelid),
				 errhint("Ensure vamana is in shared_preload_libraries and the server was restarted.")));

	while (total_waited_ms < vamana_worker_startup_timeout_ms)
	{
		long		wait_ms = Min(200, vamana_worker_startup_timeout_ms - total_waited_ms);

		(void) WaitLatch(MyLatch,
						 WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						 wait_ms,
						 PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();

		VamanaWorkerAssertDatabase();

		if (VamanaWorkerFindActiveSlot() != NULL)
			return;

		total_waited_ms += (int) wait_ms;
	}

	ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("vamana background worker unavailable after %d ms; cannot %s index %u",
					total_waited_ms, operation, indexRelid),
			 errhint("Ensure vamana is in shared_preload_libraries and the server was restarted.")));
}

/*
 * VamanaWorkerPublishPending
 *
 * Publish a fully-populated slot as PENDING and wake the worker, unless the
 * worker has stopped accepting.  The write barrier orders the slot metadata
 * before the accepting load; paired with the full-barrier clear in
 * VamanaWorkerStopAccepting, an enqueue that observes accepting still set is
 * ordered ahead of the drain's final sweep.  Returns false without publishing
 * if intake has closed, leaving the slot EMPTY for the caller to release.
 */
static bool
VamanaWorkerPublishPending(VamanaWorkerShmem *entry, VamanaWorkerSlot *slot)
{
	pg_write_barrier();

	if (pg_atomic_read_u32(&entry->accepting) == 0)
		return false;

	/*
	 * Between observing accepting set and storing PENDING, a concurrent drain
	 * can clear accepting, run its final sweep, and exit — leaving this store to
	 * a departed worker.  The backend's own bounded wait self-cancels the
	 * orphaned slot, so no request is lost.
	 */
	INJECTION_POINT("vamana-enqueue-before-publish", NULL);

	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PENDING);
	SetLatch(&entry->workerLatch);
	return true;
}

/*
 * VamanaWorkerSignalReload
 *
 * Ask the worker to reload the given index (e.g., after an INSERT/REINDEX).
 * Writes the OID into the reload queue and kicks the worker latch.
 * Must NOT use SIGUSR1: that is owned by PostgreSQL's ProcSignal layer.
 */
void
VamanaWorkerSignalReload(Oid indexRelid)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(MyDatabaseId);

	Assert(OidIsValid(indexRelid));

	if (entry == NULL)
		return;

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
	{
		uint32		expected = 0;

		if (pg_atomic_compare_exchange_u32(
										   &entry->reloadRequests[i].relid,
										   &expected, (uint32) indexRelid))
		{
			SetLatch(&entry->workerLatch);
			return;
		}
	}

	/*
	 * Queue full: the dropped OID is unknown, so tell the worker to evict its
	 * whole cache.  Each index then reloads on its next request.
	 */
	pg_atomic_write_u32(&entry->evict_all, 1);
	ereport(WARNING,
			(errmsg("vamana worker reload queue full for index %u; "
					"worker will evict all cached indexes on next cycle",
					indexRelid)));
	SetLatch(&entry->workerLatch);
}

/*
 * Outcome of VamanaWorkerWaitForSlot.  Search needs to tell ERROR apart from
 * TIMEOUT (it reports each differently); the other submit helpers collapse
 * both into "failed" via VamanaWorkerFinishSubmit.
 */
typedef enum VamanaSlotWaitOutcome
{
	VAMANA_WAIT_DONE,
	VAMANA_WAIT_ERROR,
	VAMANA_WAIT_TIMEOUT,
} VamanaSlotWaitOutcome;

/*
 * VamanaWorkerWaitForSlot
 *
 * Shared wait-loop used by all backend-side submit helpers.  Owns the
 * backend's slot latch, waits for the worker to write DONE or ERROR, then
 * releases the latch.  The slot is reset to EMPTY before returning; on
 * ERROR or TIMEOUT slot->errorMessage and slot->errorCategory describe the
 * failure.
 */
static VamanaSlotWaitOutcome
VamanaWorkerWaitForSlot(VamanaWorkerSlot *slot, int timeout_ms)
{
	uint32		status;
	int			total_waited_ms = 0;

	PG_TRY();
	{
		while (true)
		{
			int			rc;
			long		wait_ms;

			wait_ms = Min(1000, timeout_ms - total_waited_ms);
			if (wait_ms <= 0)
				break;

			rc = WaitLatch(&slot->latch,
						   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						   wait_ms,
						   PG_WAIT_EXTENSION);
			ResetLatch(&slot->latch);

			if (rc & WL_POSTMASTER_DEATH)
				ereport(ERROR, (errmsg("postmaster died")));

			CHECK_FOR_INTERRUPTS();

			status = pg_atomic_read_u32(&slot->status);
			if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
				break;

			if (rc & WL_TIMEOUT)
			{
				total_waited_ms += (int) wait_ms;
				if (total_waited_ms >= timeout_ms)
					break;
			}
		}
	}
	PG_CATCH();
	{
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
		DisownLatch(&slot->latch);
		PG_RE_THROW();
	}
	PG_END_TRY();

	DisownLatch(&slot->latch);

	status = pg_atomic_read_u32(&slot->status);

	if (status == VAMANA_SLOT_DONE)
	{
		pg_read_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return VAMANA_WAIT_DONE;
	}

	if (status == VAMANA_SLOT_ERROR)
	{
		pg_read_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return VAMANA_WAIT_ERROR;
	}

	/* Timeout: try to cancel the pending request. */
	{
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
	}
	snprintf(slot->errorMessage, sizeof(slot->errorMessage),
			 "vamana worker timed out after %d ms", total_waited_ms);
	return VAMANA_WAIT_TIMEOUT;
}

/*
 * elevel diverges by path: insert passes ERROR so a failure aborts the
 * statement and never returns; delete/maintenance/load pass WARNING and
 * degrade on the returned false.
 */
static bool
VamanaWorkerFinishSubmit(VamanaWorkerSlot *slot, int timeout_ms,
						 int elevel, const char *verb)
{
	if (VamanaWorkerWaitForSlot(slot, timeout_ms) == VAMANA_WAIT_DONE)
		return true;

	ereport(elevel,
			(errcode(VamanaSlotErrcode(slot->errorCategory)),
			 errmsg("vamana worker %s failed: %s", verb, slot->errorMessage)));
	return false;
}

/*
 * VamanaWorkerClaimSlot
 *
 * Validate that the worker is available, claim this backend's slot, and
 * initialise the latch.  Returns the slot pointer on success, NULL on
 * failure (not available, slot busy).  On success *entry_out receives the
 * serving database's control block, which the caller threads into the slot
 * data accessors and the worker-latch wakeup.
 */
static VamanaWorkerSlot *
VamanaWorkerClaimSlot(Oid indexRelid, VamanaWorkerShmem **entry_out)
{
	VamanaWorkerShmem *entry;
	int			slotIdx;
	VamanaWorkerSlot *slot;
	uint32		status;

	entry = VamanaWorkerFindActiveSlot();
	if (entry == NULL)
		return NULL;

	slotIdx = VAMANA_MY_SLOT_IDX;
	Assert(slotIdx >= 0 && slotIdx < entry->maxSlots);
	slot = &entry->slots[slotIdx];

	status = pg_atomic_read_u32(&slot->status);

	/* Clean up any leftover DONE/ERROR from a previous timed-out request. */
	if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
	{
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		status = VAMANA_SLOT_EMPTY;
	}

	if (status != VAMANA_SLOT_EMPTY)
	{
		ereport(WARNING,
				(errmsg("vamana worker slot %d not empty (status=%u), cannot submit",
						slotIdx, status)));
		return NULL;
	}

	slot->indexRelid = indexRelid;
	OwnLatch(&slot->latch);
	ResetLatch(&slot->latch);

	*entry_out = entry;
	return slot;
}

/*
 * VamanaWorkerSubmitSearch
 *
 * Backend-side: write the query into this backend's shared-memory slot,
 * wake the worker, and wait for results.  Returns the number of results
 * written to the results/distances arrays, or -1 on failure/timeout (the
 * caller renders its own "worker unavailable" message for either case).
 */
int
VamanaWorkerSubmitSearch(Oid indexRelid,
						 const float *queryVector,
						 int dimensions, int k, int searchWindowSize,
						 ItemPointer results, float *distances)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;
	VamanaSlotWaitOutcome outcome;
	int			nr;

	/*
	 * The result buffer per slot is sized at VAMANA_MAX_SEARCH_WINDOW
	 * entries (see VamanaWorkerShmemSize), so k is capped to that limit to
	 * avoid overrun.
	 */
	if (dimensions <= 0 || dimensions > VAMANA_MAX_DIM || k > VAMANA_MAX_SEARCH_WINDOW)
	{
		ereport(WARNING,
				(errmsg("vamana worker: query dimensions %d or k %d exceed max (%d/%d)",
						dimensions, k, VAMANA_MAX_DIM, VAMANA_MAX_SEARCH_WINDOW)));
		return -1;
	}

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
		return -1;

	memcpy(VamanaWorkerSlotQueryVec(entry, slotIdx), queryVector,
		   dimensions * sizeof(float));
	slot->slotKind = VAMANA_SLOTKIND_SEARCH;
	slot->dimensions = dimensions;
	slot->k = k;
	slot->searchWindowSize = searchWindowSize;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		return -1;
	}

	outcome = VamanaWorkerWaitForSlot(slot, vamana_worker_timeout_ms);

	switch (outcome)
	{
		case VAMANA_WAIT_DONE:
			/*
			 * Load-acquire barrier before reading numResults and result
			 * data: ensures we observe all worker writes that happened
			 * before the DONE status store.
			 */
			pg_read_barrier();
			nr = slot->numResults;
			if (nr > 0)
			{
				memcpy(results, VamanaWorkerSlotResults(entry, slotIdx),
					   nr * sizeof(ItemPointerData));
				memcpy(distances, VamanaWorkerSlotDistances(entry, slotIdx),
					   nr * sizeof(float));
			}
			return nr;

		case VAMANA_WAIT_ERROR:
			ereport(ERROR,
					(errcode(VamanaSlotErrcode(slot->errorCategory)),
					 errmsg("vamana worker error: %s", slot->errorMessage)));
			pg_unreachable();

		case VAMANA_WAIT_TIMEOUT:
			ereport(DEBUG1, (errmsg("%s", slot->errorMessage)));
			return -1;
	}

	pg_unreachable();
}

/*
 * VamanaWorkerSubmitInsert
 *
 * Backend-side: ask the worker to call SVSAddPoints for one vector.
 * On success, *externalId_out receives the allocated external ID.
 * Returns true on success, false on error (ereport(ERROR) in the latter case).
 */
bool
VamanaWorkerSubmitInsert(Oid indexRelid, const float *vector,
						 int dimensions, ItemPointer heap_tid,
						 uint64 *externalId_out)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("vamana index operations require the vamana background worker"),
				 errhint("Ensure the svs extension is listed in shared_preload_libraries and restart PostgreSQL.")));
	}

	if (dimensions <= 0 || dimensions > VAMANA_MAX_DIM)
	{
		DisownLatch(&slot->latch);
		ereport(ERROR,
				(errmsg("vamana worker: insert vector has %d dimensions, max is %d",
						dimensions, VAMANA_MAX_DIM)));
	}

	memcpy(VamanaWorkerSlotQueryVec(entry, slotIdx), vector,
		   dimensions * sizeof(float));
	slot->dimensions = dimensions;
	ItemPointerCopy(heap_tid, &slot->writeHeapTid);
	slot->slotKind = VAMANA_SLOTKIND_INSERT;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("vamana background worker is shutting down; cannot insert into index %u",
						indexRelid)));
	}

	VamanaWorkerFinishSubmit(slot, vamana_worker_timeout_ms, ERROR, "insert");

	pg_read_barrier();
	*externalId_out = slot->writeExternalId;
	return true;
}

/*
 * VamanaWorkerSubmitDelete
 *
 * Backend-side: ask the worker to call SVSDeletePoints for a list of IDs.
 * Returns true on success, false on error (logs a WARNING — vacuum must not
 * throw from the delete path because it is already iterating over a relation).
 */
bool
VamanaWorkerSubmitDelete(Oid indexRelid, const size_t *externalIds, int nIds)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;

	if (nIds <= 0)
		return true;

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
		return false;

	/*
	 * Pack external IDs into the query-vector buffer (reused as input for
	 * DELETE).  float[VAMANA_MAX_DIM] = 4*2000 = 8000 bytes; size_t is 8
	 * bytes, so we can hold up to 1000 IDs with natural alignment.
	 *
	 * Callers (vamanabulkdelete, undo_flush_batch) pre-split into batches of
	 * VAMANA_MAX_DELETE_IDS before calling.
	 */
	Assert(nIds <= (int) VAMANA_MAX_DELETE_IDS);

	memcpy(VamanaWorkerSlotQueryVec(entry, slotIdx), externalIds, nIds * sizeof(size_t));

	slot->numResults = nIds;
	slot->slotKind = VAMANA_SLOTKIND_DELETE;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		return false;
	}

	return VamanaWorkerFinishSubmit(slot, vamana_worker_timeout_ms, WARNING,
									"delete");
}

/*
 * VamanaWorkerSubmitMaintenance
 *
 * Backend-side: ask the worker to run CONSOLIDATE or COMPACT.
 * Returns true on success, false on error.
 */
bool
VamanaWorkerSubmitMaintenance(Oid indexRelid, uint8 op)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
		return false;

	slot->slotKind = VAMANA_SLOTKIND_MAINTENANCE;
	slot->maintenanceOp = op;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		return false;
	}

	return VamanaWorkerFinishSubmit(slot, vamana_worker_timeout_ms, WARNING,
									"maintenance");
}

/*
 * VamanaWorkerSubmitLoad
 *
 * Backend-side: ask the BGW to load a freshly-serialized index from its save
 * directory into the BGW cache.  Called from vamanabuild after the index has
 * been written to disk and the backend still holds AccessExclusiveLock.
 *
 * All parameters needed to reconstruct the SVSBuildConfig and populate the
 * cache entry are passed through the VamanaLoadParams struct packed into the
 * queryVec buffer, so the BGW never needs to open the index relation.
 *
 * Uses vamana_worker_startup_timeout_ms (not the regular IPC timeout) because
 * loading a large graph from disk can take 30–60 seconds.
 *
 * Returns true on success.  Returns false on failure — the caller logs a
 * WARNING; the index loads on demand on its next request.
 */
bool
VamanaWorkerSubmitLoad(Oid indexRelid,
					   int dimensions, int graph_degree, int alpha,
					   int search_window_size, int build_window_size,
					   int compression_type, int compression_primary,
					   int compression_secondary, int leanvec_dims,
					   int distance_type,
					   int numVectors, int tidMappingCapacity,
					   uint64 nextExternalId, int numDeleted,
					   Oid heapRelid, int vectorAttNum)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;
	VamanaLoadParams *params;

	StaticAssertStmt(sizeof(VamanaLoadParams) <= VAMANA_MAX_DIM * sizeof(float),
					 "VamanaLoadParams too large for queryVec buffer");

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
		return false;

	params = (VamanaLoadParams *) VamanaWorkerSlotQueryVec(entry, slotIdx);
	params->dimensions			= dimensions;
	params->graph_degree		= graph_degree;
	params->alpha				= alpha;
	params->search_window_size	= search_window_size;
	params->build_window_size	= build_window_size;
	params->compression_type	= compression_type;
	params->compression_primary	= compression_primary;
	params->compression_secondary = compression_secondary;
	params->leanvec_dims		= leanvec_dims;
	params->distance_type		= distance_type;
	params->numVectors			= numVectors;
	params->tidMappingCapacity	= tidMappingCapacity;
	params->nextExternalId		= nextExternalId;
	params->numDeleted			= numDeleted;
	params->heapRelid			= heapRelid;
	params->vectorAttNum		= vectorAttNum;

	slot->slotKind = VAMANA_SLOTKIND_LOAD;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		return false;
	}

	return VamanaWorkerFinishSubmit(slot, vamana_worker_startup_timeout_ms,
									WARNING, "load");
}

/*
 * VamanaWorkerSubmitWarmup
 *
 * Ask the worker to make one index resident in its cache.  Carries only the
 * relid: the worker reconstructs everything else through GetOrLoadIndex, whose
 * fast path makes an already-hot index a no-op.  Uses the startup timeout
 * because a cold load off disk can take tens of seconds.
 */
bool
VamanaWorkerSubmitWarmup(Oid indexRelid)
{
	VamanaWorkerShmem *entry;
	VamanaWorkerSlot *slot;

	slot = VamanaWorkerClaimSlot(indexRelid, &entry);
	if (slot == NULL)
		return false;

	slot->slotKind = VAMANA_SLOTKIND_WARMUP;

	if (!VamanaWorkerPublishPending(entry, slot))
	{
		DisownLatch(&slot->latch);
		return false;
	}

	return VamanaWorkerFinishSubmit(slot, vamana_worker_startup_timeout_ms,
									WARNING, "warmup");
}
