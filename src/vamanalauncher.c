/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanalauncher.c
 *
 * The vamana launcher: the one statically-registered background worker.  It
 * connects to svs.launcher_database, reads the enabled databases from the
 * vamana_databases catalog table, and spawns one dynamic per-database worker
 * (VamanaWorkerMain) for each.  Per-database workers are owned by the launcher,
 * not the postmaster: they register with BGW_NEVER_RESTART and notify the
 * launcher on death, so the launcher alone decides when to respawn them.
 *
 * The design mirrors PostgreSQL's logical-replication launcher
 * (src/backend/replication/logical/launcher.c): a reconcile loop woken by its
 * latch (worker death via bgw_notify_pid, NOTIFY, or a fallback timeout) that
 * diffs the live worker set against the table on every wake, rather than
 * reacting to any individual signal.
 */

#include "postgres.h"

#include "svs_build_request_protocol.h"
#include "svs_cpu_budget.h"
#include "svs_index_residency.h"
#include "svs_memory.h"
#include "svs_slot_naming.h"
#include "vamana.h"
#include "vamana_databases.h"
#include "vamana_replication.h"
#include "vamanalauncher.h"
#include "vamanaworker.h"

#include "access/xact.h"
#include "access/xlog.h"
#include "commands/async.h"
#include "commands/dbcommands.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lmgr.h"
#include "storage/procarray.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/injection_point.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/wait_classes.h"

/* Fallback wake interval when nothing else wakes the loop; matches core. */
#define VAMANA_LAUNCHER_NAPTIME_MS		180000L

/* NOTIFY channel published by the vamana_databases_changed trigger. */
#define VAMANA_DATABASES_CHANNEL		"vamana_databases_changed"

/* Upper bound on the exponential respawn backoff. */
#define VAMANA_RESTART_BACKOFF_CEILING_MS	60000

/*
 * Uptime after which a worker's death counts as a recovery (resetting the
 * failure count) rather than another crash-loop iteration.
 */
#define VAMANA_BACKOFF_DWELL_RESET_MS		10000

/* Failure-count clamp for the backoff shift, to avoid overflow. */
#define VAMANA_BACKOFF_MAX_SHIFT			20

/* Naptime floor: a near-zero backoff remainder must not wake a busy re-scan. */
#define VAMANA_LAUNCHER_MIN_NAPTIME_MS		1000L

/*
 * How long a reserved control block must be seen with no matching
 * vamana_databases row, across successive reconcile cycles, before it is
 * treated as orphaned rather than an enrollment whose reserving transaction
 * has not yet become visible.  Reservation happens at that transaction's
 * PRE_COMMIT, a moment before its row is visible to this launcher's own
 * snapshot; this margin is comfortably above that gap and far below
 * VAMANA_BACKOFF_DWELL_RESET_MS.
 */
#define VAMANA_ORPHAN_SLOT_GRACE_MS			5000L

/*
 * One tracked per-database worker: the handle returned by
 * RegisterDynamicBackgroundWorker is the authoritative liveness signal (via
 * GetBackgroundWorkerPid), never the slot's workerPid, which is set only once
 * the worker reaches readiness.  The ledger is launcher-local and correctly
 * rebuilt from a fresh scan after a launcher restart.
 */
typedef enum VamanaRestartAction
{
	RESTART_NOOP,				/* no restart needed */
	RESTART_TERMINATE,			/* mismatch: terminate and wait */
	RESTART_WAIT,				/* waiting for handle to stop */
	RESTART_WAIT_TIMEOUT,		/* wait timeout exceeded */
	RESTART_RESPAWN				/* handle stopped: caller respawns */
} VamanaRestartAction;

/*
 * Why a stopped handle stopped.  A stopped handle has exactly one owner keyed
 * on this reason: a restart drain is completed by the restart machinery
 * (respawn in place, preserving backoff), while a crash, disable, or removal is
 * settled by the liveness pass (accrue or clear backoff, drop the entry).
 * Conflating the two owners is what let a restart delete the entry it needed
 * to respawn.
 */
typedef enum VamanaStopReason
{
	STOP_CRASH,					/* unexpected exit: accrue backoff, clear liveness, drop, keep slot */
	STOP_DISABLED,				/* row still present, enabled = false: drop, keep slot */
	STOP_REMOVED,				/* row no longer in the table: drop, release slot */
	STOP_RESTART_DRAIN			/* deliberate restart in flight: respawn */
} VamanaStopReason;

typedef struct VamanaRestartState
{
	bool		restarting;			/* is a restart in flight? */
	int64		serviced_generation;	/* generation the running worker serves */
	int64		target_generation;	/* generation we're converging to */
	TimestampTz	wait_started;		/* when did we start waiting for stop? */
} VamanaRestartState;

typedef struct VamanaLauncherWorker
{
	Oid			dbOid;
	BackgroundWorkerHandle *handle;

	/*
	 * When the handle was first observed running (BGWH_STARTED), or 0 if it has
	 * not started yet.  Its death is a recovery only if it stayed up past the
	 * dwell threshold; a worker that FATALs before ever starting keeps this 0
	 * and can only escalate the backoff, never reset it.
	 */
	TimestampTz	started_time;

	VamanaRestartState restart_state;
} VamanaLauncherWorker;

/*
 * One database's CPU-governance catalog columns, projected out of the same
 * scan that reads the lifecycle columns below.  Kept as its own struct, not
 * flattened into VamanaDatabaseRow, so the CPU domain's consumer (the
 * upcoming launcher publish path) reads only this and never the lifecycle
 * fields, and a future domain (memory) gets an equally narrow sibling
 * instead of widening this one.
 *
 * NULL search_num_threads/maintenance_num_threads become -1 ("follow the
 * GUC default"); NULL search_threads_reserved becomes 0, which already
 * means "no floor" whether configured explicitly or left NULL.
 */
typedef struct SvsDbCpuColumns
{
	int32		searchNumThreads;
	int32		searchThreadsReserved;
	int32		maintenanceNumThreads;
} SvsDbCpuColumns;

/*
 * One database's memory-governance catalog columns, the equally narrow
 * sibling SvsDbCpuColumns's own comment calls for: the memory domain's
 * consumer (PublishMemoryOverrides) reads only this, never the CPU fields.
 *
 * NULL residency_memory/search_work_mem become 0, matching the shmem
 * override fields' own "0 means unset, resolve to the default GUC" idiom;
 * unlike CPU's threads, 0 is never a valid override value here, so it
 * doubles cleanly as the NULL sentinel with no separate -1 encoding needed.
 */
typedef struct SvsDbMemoryColumns
{
	int32		residencyMemoryMbOverride;
	int32		searchWorkMemMbOverride;
} SvsDbMemoryColumns;

/*
 * One row of the config table, as read from the catalog.  The name is captured
 * during the SPI scan and carried alongside the OID so the spawn and
 * initial-scan paths never re-enter the catalogs: those paths run outside the
 * scan's transaction, where a syscache lookup would have no snapshot.
 *
 * Every row is represented, not just enabled ones: "disabled" (row present,
 * enabled = false) and "removed" (no row at all) are different worker-stop
 * outcomes, and a row is the only place that distinction can be read from.
 */
typedef struct VamanaDatabaseRow
{
	Oid			dbOid;
	char	   *datname;
	int64		restart_generation;
	bool		enabled;
	SvsDbCpuColumns cpu;
	SvsDbMemoryColumns memory;
} VamanaDatabaseRow;

/*
 * The launcher's handle ledger, in TopMemoryContext for the process lifetime.
 * Distinct from the per-cycle context used for the row list.
 */
static List *WorkerLedger = NIL;

/*
 * One reserved control block seen with no matching row, and when that was
 * first observed.  Launcher-local and independent of WorkerLedger: a slot can
 * be orphaned with no ledger entry at all, which is exactly the case a paused
 * (STOP_DISABLED) database's slot is in once its row is later deleted -- the
 * ledger entry is already gone by then, dropped the cycle the worker stopped.
 */
typedef struct VamanaOrphanCandidate
{
	Oid			dbOid;
	TimestampTz firstSeenOrphaned;
} VamanaOrphanCandidate;

/* In TopMemoryContext, same lifetime rationale as WorkerLedger. */
static List *OrphanCandidates = NIL;

static void ClearLauncherPidOnExit(int code, Datum arg);
static void PublishCpuGrants(List *rows);
static void PublishMemoryOverrides(List *rows);
static long VamanaLauncherReconcileWorkers(void);
static List *ReadDatabaseRows(bool *ok);
static List *EnabledRowsOf(List *rows);
static void MaterializeInitialConfig(void);
static bool VamanaWorkerReserveSlotOrLog(Oid dbOid, const char *datname);
static VamanaLauncherWorker *FindLedgerEntry(Oid dbOid);
static VamanaDatabaseRow *FindDatabaseRow(List *rows, Oid dbOid);
static VamanaDatabaseRow *FindEnabledDatabase(List *rows, Oid dbOid);
static bool IsDatabaseEnabled(List *rows, Oid dbOid);
static VamanaStopReason ClassifyWorkerStop(List *rows,
										   const VamanaLauncherWorker *w);
static VamanaRestartAction VamanaRestartStateAdvance(VamanaRestartState *state,
													 int64 current_generation,
													 BgwHandleStatus handle_status,
													 TimestampTz now);
static BackgroundWorkerHandle *RegisterDatabaseWorker(const VamanaDatabaseRow *db,
													  TimestampTz now);
static void SpawnWorker(const VamanaDatabaseRow *db, TimestampTz now);
static bool RespawnWorker(VamanaLauncherWorker *w, const VamanaDatabaseRow *db,
						  TimestampTz now);
static void ReconcileLedgerLiveness(List *rows, TimestampTz now);
static void TerminateDisabledWorkers(List *rows);
static void ReconcileRestartConvergence(List *rows, TimestampTz now);
static void PublishEnabledState(List *rows);

/*
 * Accumulator for CollectReservedDbOids, sized to capacity up front so the
 * callback never allocates under VamanaWorkerForEachReserved's header lock --
 * the same discipline VamanaWorkerHydrateCb (vamanaworkerstats.c) follows for
 * the same lock.
 */
typedef struct VamanaReservedOidCollector
{
	Oid		   *oids;
	int			count;
	int			capacity;
} VamanaReservedOidCollector;

static void CollectReservedDbOids(VamanaWorkerShmem *entry, void *ctx);
static bool ReservedOidsContains(const Oid *oids, int count, Oid dbOid);
static long ReleaseOrphanedReservedSlots(List *rows, TimestampTz now,
										  const Oid *reservedOids, int reservedCount);
static long ReconcileUnledgeredWorkers(List *rows, const Oid *reservedOids, int reservedCount);
static long BackoffThresholdMs(uint32 consecutiveFailures);
static long BackoffRemainingMs(const VamanaLauncherBackoff *backoff, TimestampTz now);

/* -----------------------------------------------------------------------
 * Static registration
 * ----------------------------------------------------------------------- */

void
VamanaLauncherRegister(void)
{
	BackgroundWorker bgw;

	memset(&bgw, 0, sizeof(bgw));
	snprintf(bgw.bgw_name, BGW_MAXLEN, "vamana launcher");
	snprintf(bgw.bgw_type, BGW_MAXLEN, "vamana launcher");
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "svs");
	snprintf(bgw.bgw_function_name, BGW_MAXLEN, "VamanaLauncherMain");
	bgw.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;

	/*
	 * ConsistentState, not RecoveryFinished: the launcher must run on a hot
	 * standby to spawn the standby's per-database workers, which drain
	 * replication slots during recovery.  RecoveryFinished never fires on a
	 * node that stays in recovery.
	 */
	bgw.bgw_start_time = BgWorkerStart_ConsistentState;
	bgw.bgw_restart_time = vamana_worker_restart_time;
	bgw.bgw_main_arg = (Datum) 0;
	bgw.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&bgw);
}

/* -----------------------------------------------------------------------
 * Main loop
 * ----------------------------------------------------------------------- */

static void
ClearLauncherPidOnExit(int code, Datum arg)
{
	SvsSetLauncherPid(0);
}

void
VamanaLauncherMain(Datum main_arg)
{
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

	BackgroundWorkerInitializeConnection(vamana_launcher_database, NULL, 0);

	/*
	 * before_shmem_exit, not inline cleanup before each return: the launcher's
	 * own exits are signal-driven (SIGTERM -> die() -> proc_exit at the next
	 * CHECK_FOR_INTERRUPTS), so there is no controlled point to clear this
	 * inline the way a worker clears its own workerPid before its own
	 * proc_exit call.
	 */
	before_shmem_exit(ClearLauncherPidOnExit, 0);
	SvsSetLauncherPid(MyProcPid);

	/*
	 * Listen before the initial scan so an enable committed between the scan
	 * and the first WaitLatch still wakes us.  A latch set alone carries no
	 * payload; the reconcile pass re-reads the table regardless of cause, so
	 * we never depend on payload contents.
	 */
	StartTransactionCommand();
	Async_Listen(VAMANA_DATABASES_CHANNEL);
	CommitTransactionCommand();

	MaterializeInitialConfig();

	/* Reap anything left dead while no launcher was running to reap it. */
	SvsMemoryReapDeadReservations();

	ereport(LOG, (errmsg("vamana launcher started")));

	for (;;)
	{
		int			rc;
		long		naptime;

		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();

		if (ConfigReloadPending)
		{
			ConfigReloadPending = false;
			ProcessConfigFile(PGC_SIGHUP);
		}

		/*
		 * Drain the async queue outside any transaction.  A latch set leaves
		 * the queue un-consumed (notifyInterruptPending stays set, the SLRU
		 * tail never advances for this backend); consuming it both avoids that
		 * leak.  ProcessNotifyInterrupt refuses to run inside a
		 * transaction, so it precedes the SPI read in the reconcile pass.
		 *
		 * flush=false: the launcher has no client connection, so pq_flush()
		 * would ERROR with "there is no client connection".  There is no
		 * frontend to forward notifications to; draining the queue is all we
		 * need.
		 */
		ProcessNotifyInterrupt(false);

		SvsMemoryReapDeadReservations();

		naptime = VamanaLauncherReconcileWorkers();

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
					   naptime,
					   PG_WAIT_EXTENSION);
		(void) rc;
	}
}

/*
 * Reconcile the live worker set against the table on every wake, and return the
 * naptime for the following WaitLatch.  The full row set is read first so the
 * liveness pass can tell a crash (accrue backoff) from a legitimate disable or
 * removal (drop with no accrual); the spawn diff then respawns any enabled
 * database whose worker is gone, subject to its backoff, folding the naptime
 * down to the soonest eligible retry so a backing-off database is not made to
 * oversleep.
 */
static long
VamanaLauncherReconcileWorkers(void)
{
	MemoryContext cycleCtx;
	MemoryContext oldCtx;
	List	   *rows;
	ListCell   *lc;
	TimestampTz now = GetCurrentTimestamp();
	long		naptime = VAMANA_LAUNCHER_NAPTIME_MS;
	bool		ok;

	cycleCtx = AllocSetContextCreate(TopMemoryContext,
									 "vamana launcher reconcile",
									 ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(cycleCtx);

	rows = ReadDatabaseRows(&ok);

	if (!ok)
	{
		/*
		 * A failed read is not ground truth: every currently-tracked worker
		 * and reserved slot would otherwise read as "its database left the
		 * enabled set," and this cycle would tear all of them down on what
		 * may be a transient failure (already logged by ReadDatabaseRows).
		 * Skip reconciling entirely and retry soon.
		 */
		MemoryContextSwitchTo(oldCtx);
		MemoryContextDelete(cycleCtx);
		return VAMANA_LAUNCHER_MIN_NAPTIME_MS;
	}

	PublishEnabledState(rows);

	ReconcileLedgerLiveness(rows, now);
	TerminateDisabledWorkers(rows);
	if (WorkerLedger != NIL)
		ReconcileRestartConvergence(rows, now);

	/*
	 * Collected once per cycle and shared by both passes below: each would
	 * otherwise call VamanaWorkerForEachReserved independently, walking the
	 * reserved array under the header lock twice for the same result.
	 */
	{
		VamanaReservedOidCollector collector;

		collector.capacity = VamanaWorkerSlotCapacity();
		collector.oids = palloc(sizeof(Oid) * collector.capacity);
		collector.count = 0;

		VamanaWorkerForEachReserved(CollectReservedDbOids, &collector);

		naptime = Min(naptime, ReconcileUnledgeredWorkers(rows, collector.oids, collector.count));
		naptime = Min(naptime, ReleaseOrphanedReservedSlots(rows, now, collector.oids, collector.count));
	}

	PublishCpuGrants(rows);
	PublishMemoryOverrides(rows);

	foreach(lc, EnabledRowsOf(rows))
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);
		VamanaLauncherBackoff backoff;
		long		remaining;

		if (FindLedgerEntry(db->dbOid) != NULL)
			continue;

		/*
		 * A restarted launcher's ledger is empty; don't spawn into an
		 * already-live worker's slot.  Read-only and stale-tolerant: the worst a
		 * recycled entry costs is one skipped spawn, which the next reconcile
		 * makes good.
		 */
		{
			VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(db->dbOid);

			if (entry != NULL && VamanaWorkerEntryIsLive(entry))
				continue;
		}

		VamanaWorkerBackoffSnapshot(db->dbOid, &backoff);
		remaining = BackoffRemainingMs(&backoff, now);

		if (remaining <= 0)
			SpawnWorker(db, now);
		else
			naptime = Min(naptime, remaining);
	}

	MemoryContextSwitchTo(oldCtx);
	MemoryContextDelete(cycleCtx);

	return Max(naptime, VAMANA_LAUNCHER_MIN_NAPTIME_MS);
}

/* -----------------------------------------------------------------------
 * Initial scan: materialize the enablement config into shmem
 * ----------------------------------------------------------------------- */

/*
 * Reserve dbOid's slot, logging the launcher's standard capacity-exceeded
 * message on failure.  Returns whether the reservation succeeded.
 */
static bool
VamanaWorkerReserveSlotOrLog(Oid dbOid, const char *datname)
{
	char		safeDatname[NAMEDATALEN * 4];

	if (VamanaWorkerReserveSlot(dbOid, NULL) != NULL)
		return true;

	CopySanitizedDatname(safeDatname, sizeof(safeDatname), datname);
	ereport(LOG,
			(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
			 errmsg("vamana launcher could not reserve a slot for database \"%s\"",
					safeDatname),
			 errhint("Increase svs.max_databases and restart.")));
	return false;
}

/*
 * Reserve a slot for every enabled database before any worker is registered,
 * then publish initialScanDone.  This is the restart-durable projection of the
 * config table into shmem: at postmaster start slots[] is empty, and without
 * this a CREATE INDEX / INSERT in a long-enabled database would read "no slot"
 * and hard-fail "not enabled" in the window before that database's worker
 * self-reserves.
 *
 * Reservation is idempotent (VamanaWorkerReserveSlot), so overlap with the
 * PRE_COMMIT trigger or a worker's own startup reservation is a no-op.
 */
static void
MaterializeInitialConfig(void)
{
	MemoryContext scanCtx;
	MemoryContext oldCtx;
	List	   *rows;
	ListCell   *lc;
	bool		ok;

	scanCtx = AllocSetContextCreate(TopMemoryContext,
									"vamana launcher initial scan",
									ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(scanCtx);

	/*
	 * A failed read here only means fewer slots get pre-reserved at startup,
	 * the same outcome as a legitimately empty table; each one is reserved
	 * again idempotently once ReadDatabaseRows succeeds on the launcher's
	 * first reconcile pass, so the failure is not specially handled here.
	 */
	rows = ReadDatabaseRows(&ok);

	foreach(lc, EnabledRowsOf(rows))
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);

		(void) VamanaWorkerReserveSlotOrLog(db->dbOid, db->datname);
	}

	VamanaWorkerSetInitialScanDone();

	MemoryContextSwitchTo(oldCtx);
	MemoryContextDelete(scanCtx);
}

/* -----------------------------------------------------------------------
 * Table read (SPI)
 * ----------------------------------------------------------------------- */

/*
 * Append a row, capturing its name, in callerCtx.  Both the list cell and the
 * name string outlive the SPI transaction, so the spawn and initial-scan paths
 * never re-enter the catalogs.  Deduplicates by OID.
 */
static List *
AppendDatabaseRow(List *list, Oid dbOid, const char *datname,
				  int64 restart_generation, bool enabled,
				  const SvsDbCpuColumns *cpu, const SvsDbMemoryColumns *memory,
				  MemoryContext callerCtx)
{
	VamanaDatabaseRow *db;
	MemoryContext oldCtx;
	ListCell   *lc;

	foreach(lc, list)
		if (((VamanaDatabaseRow *) lfirst(lc))->dbOid == dbOid)
			return list;

	oldCtx = MemoryContextSwitchTo(callerCtx);
	db = palloc(sizeof(VamanaDatabaseRow));
	db->dbOid = dbOid;
	db->datname = pstrdup(datname);
	db->restart_generation = restart_generation;
	db->enabled = enabled;
	db->cpu = *cpu;
	db->memory = *memory;
	list = lappend(list, db);
	MemoryContextSwitchTo(oldCtx);

	return list;
}

/* NULL and an explicit 0 both mean "no floor," so both resolve to 0. */
static int32
ResolveReservedFloor(bool isNull, int32 value)
{
	return isNull ? 0 : value;
}

/*
 * Return every row of vamana_databases, allocated in the caller's memory
 * context (which must outlive the SPI transaction opened here).  Name-to-OID
 * resolution is tolerant: a row whose database no longer exists is skipped and
 * logged rather than aborting the scan.
 *
 * Every row is returned regardless of its enabled flag: callers that need only
 * the enabled subset filter with EnabledRowsOf(), and callers that need to
 * distinguish "disabled" from "removed" (no row at all) can only do so by
 * having the full set to check membership against.
 *
 * *ok is set to false on a failed read (SPI_connect failure, or a caught
 * SPI_execute error) and true otherwise, including the legitimate "table has
 * no rows yet" and "extension not created yet" cases.  This distinction
 * matters to the caller: an empty result from a failed read is not ground
 * truth and must not be reconciled against as though it were -- every row
 * missing its own database would otherwise read as "disabled" or "removed."
 */
static List *
ReadDatabaseRows(bool *ok)
{
	/*
	 * volatile: read after PG_END_TRY() but assigned inside PG_CATCH(), so it
	 * must survive the longjmp back to the PG_TRY() setjmp point
	 * (-Wclobbered).
	 */
	List * volatile result = NIL;
	MemoryContext callerCtx = CurrentMemoryContext;

	*ok = true;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();

	/*
	 * An enrolling transaction reserves its slot at PRE_COMMIT, before its
	 * row is visible to the snapshot this function is about to take; that
	 * transaction's own INSERT/UPDATE/DELETE already holds RowExclusiveLock
	 * on vamana_databases for as long as it remains open, so a conflicting
	 * conditional probe here is a reliable, non-blocking way to tell "no
	 * matching row because none exists" apart from "no matching row yet,
	 * because a writer is still mid-transaction."  Deferring the whole cycle
	 * on a miss, rather than only the orphan-release pass, keeps this one
	 * fact in one place rather than threading it through every consumer of
	 * the row set.
	 *
	 * Primary only. A standby never runs the write transaction this probe
	 * defends against -- reservation is a PRE_COMMIT callback on a live
	 * INSERT/UPDATE, and nothing executes DML during WAL replay -- so there
	 * is nothing here to detect. Skipping it in recovery matters beyond
	 * being merely redundant: a standby backend holding even a briefly-held,
	 * conditional lock on a relation being replayed can stall the startup
	 * process behind hot standby's recovery-conflict wait, which is exactly
	 * the kind of interference a standby-side reconcile pass must not cause.
	 */
	if (!RecoveryInProgress())
	{
		Oid			relid = SvsDatabasesRelid();

		if (OidIsValid(relid))
		{
			if (!ConditionalLockRelationOid(relid, ShareLock))
			{
				AbortCurrentTransaction();
				*ok = false;
				return NIL;
			}
			UnlockRelationOid(relid, ShareLock);
		}
	}

	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		PopActiveSnapshot();
		AbortCurrentTransaction();
		ereport(WARNING, (errmsg("vamana launcher: SPI_connect failed")));
		*ok = false;
		return NIL;
	}

	/*
	 * SPI_execute ereports ERROR rather than returning a bad status for a
	 * failing query (a dropped column, a lock conflict, ...); without this
	 * PG_TRY that error unwinds out of the caller's main loop and the
	 * launcher exits, which the postmaster respawns into the same failure
	 * forever. Catching it here degrades to the WARNING below and lets the
	 * next wake retry.
	 */
	PG_TRY();
	{
		char	   *qualifiedName = SvsDatabasesQualifiedName();

		if (qualifiedName != NULL)
		{
			/*
			 * Column order is positional (SPI_getbinval below reads by
			 * index): datname, restart_generation, enabled,
			 * search_num_threads, search_threads_reserved,
			 * maintenance_num_threads, residency_memory, search_work_mem.
			 * A future column belongs at the end, with a matching new
			 * index -- never inserted between existing ones.
			 */
			int			ret = SPI_execute(psprintf("SELECT datname, restart_generation, enabled, "
													"search_num_threads, search_threads_reserved, "
													"maintenance_num_threads, residency_memory, "
													"search_work_mem FROM %s",
													qualifiedName),
										  true, 0);

			if (ret != SPI_OK_SELECT)
				ereport(WARNING, (errmsg("vamana launcher: failed to read vamana_databases")));

			for (uint64 i = 0; ret == SPI_OK_SELECT && i < SPI_processed; i++)
			{
				HeapTuple	tuple = SPI_tuptable->vals[i];
				TupleDesc	tupdesc = SPI_tuptable->tupdesc;
				bool		datnameIsNull;
				bool		restartGenIsNull;
				bool		enabledIsNull;
				bool		searchNumThreadsIsNull;
				bool		searchThreadsReservedIsNull;
				bool		maintenanceNumThreadsIsNull;
				bool		residencyMemoryIsNull;
				bool		searchWorkMemIsNull;
				Name		datname = DatumGetName(SPI_getbinval(tuple, tupdesc, 1, &datnameIsNull));
				int64		restart_generation = DatumGetInt64(SPI_getbinval(tuple, tupdesc, 2, &restartGenIsNull));
				bool		enabled = DatumGetBool(SPI_getbinval(tuple, tupdesc, 3, &enabledIsNull));
				int32		searchNumThreads = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 4, &searchNumThreadsIsNull));
				int32		searchThreadsReserved = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 5, &searchThreadsReservedIsNull));
				int32		maintenanceNumThreads = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 6, &maintenanceNumThreadsIsNull));
				int32		residencyMemoryMb = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 7, &residencyMemoryIsNull));
				int32		searchWorkMemMb = DatumGetInt32(SPI_getbinval(tuple, tupdesc, 8, &searchWorkMemIsNull));
				SvsDbCpuColumns cpu;
				SvsDbMemoryColumns memory;
				Oid			dbOid;

				if (datnameIsNull || restartGenIsNull || enabledIsNull)
					continue;

				dbOid = get_database_oid(NameStr(*datname), true);
				if (!OidIsValid(dbOid))
				{
					char		safeDatname[NAMEDATALEN * 4];

					CopySanitizedDatname(safeDatname, sizeof(safeDatname), NameStr(*datname));
					ereport(LOG,
							(errmsg("vamana launcher: database \"%s\" does not exist; skipping",
									safeDatname)));
					continue;
				}

				cpu.searchNumThreads = SvsResolveNullableThreadCount(searchNumThreadsIsNull, searchNumThreads);
				cpu.searchThreadsReserved = ResolveReservedFloor(searchThreadsReservedIsNull, searchThreadsReserved);
				cpu.maintenanceNumThreads = SvsResolveNullableThreadCount(maintenanceNumThreadsIsNull, maintenanceNumThreads);

				memory.residencyMemoryMbOverride = residencyMemoryIsNull ? 0 : residencyMemoryMb;
				memory.searchWorkMemMbOverride = searchWorkMemIsNull ? 0 : searchWorkMemMb;

				result = AppendDatabaseRow(result, dbOid, NameStr(*datname),
										   restart_generation, enabled, &cpu, &memory, callerCtx);
			}
		}

		SPI_finish();
		PopActiveSnapshot();
		CommitTransactionCommand();
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		/*
		 * PG_TRY/PG_CATCH save and restore only PG_exception_stack and
		 * error_context_stack; CurrentMemoryContext is left wherever the
		 * error occurred (inside SPI's own execution context), so it must be
		 * restored here before anything is allocated, or the caller resumes
		 * in a context SPI_finish() -- called via AtEOXact_SPI() below -- is
		 * about to tear down.
		 */
		MemoryContextSwitchTo(callerCtx);

		edata = CopyErrorData();
		FlushErrorState();

		/*
		 * AbortCurrentTransaction runs AtEOXact_SPI(false), which pops any
		 * SPI connection left open by the failing SPI_execute; there is no
		 * separate SPI_finish() to call here.
		 */
		if (ActiveSnapshotSet())
			PopActiveSnapshot();
		if (IsTransactionState())
			AbortCurrentTransaction();

		ereport(WARNING,
				(errmsg("vamana launcher: failed to read vamana_databases: %s",
						edata->message)));
		FreeErrorData(edata);

		result = NIL;
		*ok = false;
	}
	PG_END_TRY();

	return result;
}

/*
 * The enabled subset of rows, as a freshly-built list.  A pure derivation of
 * rows, not a second independently-sourced result: nothing to keep in sync.
 */
static List *
EnabledRowsOf(List *rows)
{
	List	   *result = NIL;
	ListCell   *lc;

	foreach(lc, rows)
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);

		if (db->enabled)
			result = lappend(result, db);
	}
	return result;
}

/* -----------------------------------------------------------------------
 * CPU governance
 *
 * The launcher is the sole caller of SvsComputeCpuGrants and the sole writer
 * of the grant fields it publishes; a worker or build backend only ever
 * applies a grant it already finds published, never computes one itself.
 * ----------------------------------------------------------------------- */

/*
 * Gather every enabled database's pending build requests into claims,
 * appending them to builds[nbuilds..] and returning the new count.  entry is
 * NULL for a database with no shmem control block yet (nothing to scan).
 */
static int
AppendPendingBuildRequests(SvsBuildCpuRequest *builds, int nbuilds,
						   Oid dbOid, VamanaWorkerShmem *entry)
{
	if (entry == NULL)
		return nbuilds;

	for (int i = 0; i < SVS_MAX_PENDING_BUILDS; i++)
	{
		SvsBuildRequest *req = &entry->buildRequests[i];
		pid_t		pid = (pid_t) pg_atomic_read_u32(&req->pid);

		if (pid == 0)
			continue;

		/*
		 * Structural backstop, not a crash handler: every exit path a build
		 * backend can take today (success, error, timeout, SIGTERM mid-wait)
		 * already releases its own slot via SvsRunGovernedBuild/
		 * SvsWaitForBuildGrant, and a true crash forces PostgreSQL to
		 * reinitialize shared memory before this code would ever run.  Kept
		 * anyway, matching the same defense-in-depth the design gives
		 * search's fiction-worker orphans: SVS_MAX_PENDING_BUILDS is a
		 * small, shared pool, and a future change to the primary cleanup
		 * path silently leaking one slot would otherwise degrade capacity
		 * until the next restart, with nothing to point at why.
		 */
		if (BackendPidGetProc(pid) == NULL)
		{
			SvsReleaseBuildRequestSlot(req);
			continue;
		}

		if (pg_atomic_read_u32(&req->status) != SVS_BUILD_REQUEST_PENDING)
			continue;

		pg_read_barrier();

		builds[nbuilds].dbOid = dbOid;
		builds[nbuilds].requestPid = pid;
		builds[nbuilds].maintenanceNumThreads = req->requested;
		nbuilds++;
	}

	return nbuilds;
}

/*
 * Hand a build's grant back to the requester: publish requested/granted
 * before flipping status, mirroring VamanaWorkerSlot's write-then-publish
 * protocol, then wake the backend waiting on it.
 */
static void
PublishBuildGrant(VamanaWorkerShmem *entry, const SvsBuildCpuGrant *grant)
{
	for (int i = 0; i < SVS_MAX_PENDING_BUILDS; i++)
	{
		SvsBuildRequest *req = &entry->buildRequests[i];

		if ((pid_t) pg_atomic_read_u32(&req->pid) != grant->requestPid)
			continue;

		req->granted = grant->grantedThreads;
		pg_write_barrier();
		pg_atomic_write_u32(&req->status, SVS_BUILD_REQUEST_GRANTED);
		SvsWakeBackend(grant->requestPid);
		return;
	}
}

/* One enabled database's control-block pointer, as resolved while gathering
 * this reconcile's requests. Grant application below matches on dbOid, not
 * position: nothing guarantees budget->dbGrants/buildGrants track
 * enabledRows' order or count.
 */
typedef struct GatheredDbEntry
{
	Oid					dbOid;
	VamanaWorkerShmem  *entry;
} GatheredDbEntry;

static VamanaWorkerShmem *
FindGatheredEntry(const GatheredDbEntry *entries, int nentries, Oid dbOid)
{
	for (int i = 0; i < nentries; i++)
		if (entries[i].dbOid == dbOid)
			return entries[i].entry;

	return NULL;
}

/*
 * Publish this reconcile's CPU grants: gather the projected catalog columns,
 * the GUC snapshot, and every live database's pending build requests; call
 * the calculator once; write back only what changed.
 */
static void
PublishCpuGrants(List *rows)
{
	List	   *enabledRows;
	int			ndbs;
	SvsDbCpuRequest *dbs;
	GatheredDbEntry *entries;
	SvsBuildCpuRequest *builds;
	int			nbuilds = 0;
	int			i = 0;
	ListCell   *lc;
	SvsCpuGucs	gucs;
	SvsCpuBudgetInput input;
	SvsCpuBudget *budget;

	INJECTION_POINT("svs-build-thread-grant-publish", NULL);

	enabledRows = EnabledRowsOf(rows);
	ndbs = list_length(enabledRows);
	dbs = palloc(sizeof(SvsDbCpuRequest) * ndbs);
	entries = palloc(sizeof(GatheredDbEntry) * ndbs);
	builds = palloc(sizeof(SvsBuildCpuRequest) * ndbs * SVS_MAX_PENDING_BUILDS);

	foreach(lc, enabledRows)
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);
		VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(db->dbOid);
		bool		live = (entry != NULL && VamanaWorkerEntryIsLive(entry));

		entries[i].dbOid = db->dbOid;
		entries[i].entry = entry;

		dbs[i].dbOid = db->dbOid;
		dbs[i].live = live;
		dbs[i].searchNumThreads = db->cpu.searchNumThreads;
		dbs[i].searchThreadsReserved = db->cpu.searchThreadsReserved;
		i++;

		/*
		 * Not gated on live: a build-thread request is meaningful as soon as
		 * the database has a reserved entry, independent of whether a
		 * worker is currently, healthily serving it (the worker's own
		 * startup path requests build threads for itself before publishing
		 * its own liveness).
		 */
		nbuilds = AppendPendingBuildRequests(builds, nbuilds, db->dbOid, entry);
	}

	gucs.searchNumThreadsDefault = vamana_search_num_threads;
	gucs.maxSearchThreadsPerDb = svs_max_search_threads_per_db;
	gucs.maxTotalSearchThreads = svs_max_total_search_threads;
	gucs.maxParallelWorkers = max_parallel_workers;

	input.gucs = &gucs;
	input.dbs = dbs;
	input.ndbs = ndbs;
	input.builds = builds;
	input.nbuilds = nbuilds;

	budget = SvsComputeCpuGrants(&input, CurrentMemoryContext);

	for (i = 0; i < budget->ndbGrants; i++)
	{
		const SvsDbCpuGrant *grant = &budget->dbGrants[i];
		VamanaWorkerShmem *entry = FindGatheredEntry(entries, ndbs, grant->dbOid);
		uint32		previousGranted;

		if (entry == NULL || entry->dbOid != grant->dbOid)
			continue;

		previousGranted = pg_atomic_read_u32(&entry->grantedSearchThreads);

		pg_atomic_write_u32(&entry->desiredSearchThreads, (uint32) grant->desiredSearchThreads);
		pg_atomic_write_u32(&entry->reservedSearchThreads, (uint32) grant->reservedSearchThreads);

		if ((uint32) grant->grantedSearchThreads != previousGranted)
		{
			pg_atomic_write_u32(&entry->grantedSearchThreads, (uint32) grant->grantedSearchThreads);
			SetLatch(&entry->workerLatch);
		}
	}

	for (i = 0; i < budget->nbuildGrants; i++)
	{
		const SvsBuildCpuGrant *grant = &budget->buildGrants[i];
		VamanaWorkerShmem *entry = FindGatheredEntry(entries, ndbs, grant->dbOid);

		if (entry != NULL && entry->dbOid == grant->dbOid)
			PublishBuildGrant(entry, grant);
	}

	if (budget->reservedFloorsExceedPool)
		ereport(LOG,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("vamana launcher: configured search_threads_reserved values sum to more "
						"than the pool; floors were clamped")));
}

/*
 * Re-validate dbOid's admitted residency budget, for a change with no
 * catalog row to hang a synchronous trigger on: svs.default_residency_memory
 * or svs.max_residency_memory via SIGHUP. One rejection is caught and
 * logged so it can't stop the rest of this cycle's databases from
 * reconciling.
 */
static void
ReconcileResidencyAdmission(Oid dbOid)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);

	if (entry == NULL)
		return;

	PG_TRY();
	{
		uint64		durableFloor;
		uint64		residencyBudget;

		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		durableFloor = SvsIndexResidencyDurableFloor(dbOid, entry);
		PopActiveSnapshot();
		CommitTransactionCommand();

		residencyBudget = SvsMemoryResolveResidencyBudget(entry);
		SvsMemoryAdmitDatabase(dbOid, residencyBudget, durableFloor);
	}
	PG_CATCH();
	{
		if (IsTransactionState())
			AbortCurrentTransaction();
		EmitErrorReport();
		FlushErrorState();
	}
	PG_END_TRY();
}

/*
 * Materialize every enabled row's memory-governance overrides into its
 * reserved shmem entry, same "reserves or refreshes the slot" cadence as
 * PublishCpuGrants: an override set after enrollment (an UPDATE, not just
 * the original INSERT) reaches shmem on the next reconcile, not only at
 * first reservation. A row with no reserved entry yet is skipped; the next
 * reconcile after it spawns picks it up.
 */
static void
PublishMemoryOverrides(List *rows)
{
	ListCell   *lc;

	foreach(lc, EnabledRowsOf(rows))
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);

		VamanaWorkerSetMemoryOverrides(db->dbOid,
										db->memory.residencyMemoryMbOverride,
										db->memory.searchWorkMemMbOverride);

		ReconcileResidencyAdmission(db->dbOid);
	}
}

/* -----------------------------------------------------------------------
 * Crash-backoff policy
 * ----------------------------------------------------------------------- */

/*
 * Milliseconds to wait between respawns: the base backoff doubled per failure,
 * capped at the ceiling.  Exponential because a persistently broken database
 * gains nothing from retrying every base interval.
 */
static long
BackoffThresholdMs(uint32 consecutiveFailures)
{
	uint32		shift = Min(consecutiveFailures, VAMANA_BACKOFF_MAX_SHIFT);
	long		threshold = (long) vamana_worker_restart_backoff << shift;

	return Min(threshold, VAMANA_RESTART_BACKOFF_CEILING_MS);
}

/* Milliseconds left before the next respawn is allowed; <= 0 means spawn now. */
static long
BackoffRemainingMs(const VamanaLauncherBackoff *backoff, TimestampTz now)
{
	long		elapsed;

	if (backoff->last_attempt_time == 0)
		return 0;

	elapsed = TimestampDifferenceMilliseconds(backoff->last_attempt_time, now);

	return BackoffThresholdMs(backoff->consecutive_failures) - elapsed;
}

/* -----------------------------------------------------------------------
 * Worker ledger and spawning
 * ----------------------------------------------------------------------- */

static VamanaLauncherWorker *
FindLedgerEntry(Oid dbOid)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *w = (VamanaLauncherWorker *) lfirst(lc);

		if (w->dbOid == dbOid)
			return w;
	}
	return NULL;
}

static VamanaDatabaseRow *
FindDatabaseRow(List *rows, Oid dbOid)
{
	ListCell   *lc;

	foreach(lc, rows)
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);

		if (db->dbOid == dbOid)
			return db;
	}
	return NULL;
}

static VamanaDatabaseRow *
FindEnabledDatabase(List *rows, Oid dbOid)
{
	VamanaDatabaseRow *db = FindDatabaseRow(rows, dbOid);

	return (db != NULL && db->enabled) ? db : NULL;
}

static bool
IsDatabaseEnabled(List *rows, Oid dbOid)
{
	return FindEnabledDatabase(rows, dbOid) != NULL;
}

/*
 * Classify why a worker's handle stopped, so exactly one machine owns the
 * transition.  A disable or removal outranks an in-flight restart: a database
 * leaving the enabled set is torn down here (drop, no accrual) even
 * mid-restart, since the restart convergence pass only visits enabled
 * databases and would otherwise leave the entry orphaned between the two
 * owners.
 */
static VamanaStopReason
ClassifyWorkerStop(List *rows, const VamanaLauncherWorker *w)
{
	VamanaDatabaseRow *db = FindDatabaseRow(rows, w->dbOid);

	if (db == NULL)
		return STOP_REMOVED;
	if (!db->enabled)
		return STOP_DISABLED;
	if (w->restart_state.restarting)
		return STOP_RESTART_DRAIN;
	return STOP_CRASH;
}

/*
 * Advance the restart state machine toward convergence with the current
 * restart_generation read from the database.  The state is launcher-local
 * (survives launcher restarts automatically by being rebuilt from ground truth)
 * and tracks: (1) whether a restart is in flight, (2) what generation we're
 * converging to. Coalescing falls out: if multiple restart calls land before
 * the first drain finishes, the generation increments each time but the state
 * records the latest target; after the drain, convergence sees the gap and
 * does exactly one more restart.
 *
 * The terminal RESPAWN transition (clearing restarting, advancing
 * serviced_generation) is left to the caller and applied only once the respawn
 * actually succeeds: a failed registration keeps the state RESPAWN-pending, so
 * the next cycle sees the still-stopped handle and retries rather than dropping
 * the restart on the floor.
 *
 * Returns the action the caller should take: NOOP (no restart needed),
 * TERMINATE (start draining), WAIT (still draining), WAIT_TIMEOUT (timeout
 * exceeded, still waiting), or RESPAWN (stopped: respawn in place).
 */
static VamanaRestartAction
VamanaRestartStateAdvance(VamanaRestartState *state,
						  int64 current_generation,
						  BgwHandleStatus handle_status,
						  TimestampTz now)
{
	if (!state->restarting && state->serviced_generation == current_generation)
	{
		/* No restart needed; idle. */
		return RESTART_NOOP;
	}

	if (!state->restarting && state->serviced_generation != current_generation)
	{
		/* Mismatch detected: start a restart. */
		state->restarting = true;
		state->target_generation = current_generation;
		state->wait_started = 0;
		return RESTART_TERMINATE;
	}

	if (state->restarting && handle_status != BGWH_STOPPED)
	{
		/* First time waiting: record when we started. */
		if (state->wait_started == 0)
			state->wait_started = now;

		/* Check if timeout exceeded. */
		if (TimestampDifferenceExceeds(state->wait_started, now,
									   vamana_worker_stop_timeout_ms))
			return RESTART_WAIT_TIMEOUT;

		/* Still waiting within timeout. */
		return RESTART_WAIT;
	}

	if (state->restarting && handle_status == BGWH_STOPPED)
	{
		/* Handle stopped: caller respawns and completes the transition. */
		return RESTART_RESPAWN;
	}

	/* Should not reach. */
	return RESTART_NOOP;
}

/*
 * Reserve a slot and register a per-database worker, returning its handle (in
 * TopMemoryContext) or NULL on failure.  The worker is BGW_NEVER_RESTART with
 * bgw_notify_pid set to the launcher, so the postmaster never respawns it and
 * instead signals the launcher on its death.
 *
 * The slot is reserved here, before registration, for two reasons: it gives the
 * backoff counters a durable home even for a worker that FATALs at startup
 * before it can self-reserve (the crash-loop case), and it avoids registering a
 * worker that could only fail the capacity check.  Reservation is idempotent,
 * so overlap with the worker's own startup reservation is a no-op.
 *
 * The handle is palloc'd in TopMemoryContext because the ledger outlives the
 * per-cycle reconcile context; a cycle-context handle would dangle once that
 * context is freed.
 */
static BackgroundWorkerHandle *
RegisterDatabaseWorker(const VamanaDatabaseRow *db, TimestampTz now)
{
	BackgroundWorker bgw;
	BackgroundWorkerHandle *handle;
	MemoryContext oldCtx;
	char		safeDatname[BGW_MAXLEN];

	if (!VamanaWorkerReserveSlotOrLog(db->dbOid, db->datname))
		return NULL;

	memset(&bgw, 0, sizeof(bgw));
	CopySanitizedDatname(safeDatname, sizeof(safeDatname), db->datname);
	snprintf(bgw.bgw_name, BGW_MAXLEN, "vamana worker: %s", safeDatname);
	snprintf(bgw.bgw_type, BGW_MAXLEN, "vamana worker");
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "svs");
	snprintf(bgw.bgw_function_name, BGW_MAXLEN, "VamanaWorkerMain");
	bgw.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;
	bgw.bgw_start_time = BgWorkerStart_ConsistentState;
	bgw.bgw_restart_time = BGW_NEVER_RESTART;
	bgw.bgw_main_arg = ObjectIdGetDatum(db->dbOid);
	bgw.bgw_notify_pid = MyProcPid;

	oldCtx = MemoryContextSwitchTo(TopMemoryContext);

	if (!RegisterDynamicBackgroundWorker(&bgw, &handle))
	{
		MemoryContextSwitchTo(oldCtx);
		ereport(LOG,
				(errmsg("vamana launcher could not register worker for database \"%s\"",
						safeDatname),
				 errhint("Consider increasing max_worker_processes.")));
		return NULL;
	}

	MemoryContextSwitchTo(oldCtx);

	VamanaWorkerBackoffStampAttempt(db->dbOid, now);
	return handle;
}

/*
 * Spawn a fresh worker and append its ledger entry.  serviced_generation is
 * seeded from the database's current restart_generation so a newly spawned
 * worker is never mistaken for one lagging a past restart: only a subsequent
 * svs_restart_worker() bump makes convergence see a gap.
 */
static void
SpawnWorker(const VamanaDatabaseRow *db, TimestampTz now)
{
	BackgroundWorkerHandle *handle;
	VamanaLauncherWorker *entry;
	MemoryContext oldCtx;

	handle = RegisterDatabaseWorker(db, now);
	if (handle == NULL)
		return;

	/*
	 * The ledger List's cells, not just entry itself, must live in
	 * TopMemoryContext: lappend() outside this switch would link the new cell
	 * into the per-cycle reconcile context, leaving WorkerLedger dangling once
	 * that context is deleted at the end of the cycle.
	 */
	oldCtx = MemoryContextSwitchTo(TopMemoryContext);
	entry = palloc(sizeof(VamanaLauncherWorker));

	entry->dbOid = db->dbOid;
	entry->handle = handle;
	entry->started_time = 0;
	entry->restart_state.restarting = false;
	entry->restart_state.serviced_generation = db->restart_generation;
	entry->restart_state.target_generation = db->restart_generation;
	entry->restart_state.wait_started = 0;
	WorkerLedger = lappend(WorkerLedger, entry);
	MemoryContextSwitchTo(oldCtx);

	VamanaWorkerSetServicedRestartGeneration(db->dbOid, db->restart_generation);
}

/*
 * Respawn a stopped worker in place, completing the restart transition.  The
 * existing ledger entry is reused so it is never orphaned between the liveness
 * and convergence owners, and its backoff is preserved (a deliberate restart is
 * not a crash).  On success the entry adopts the target generation and clears
 * the in-flight flag; on registration failure the entry is left RESPAWN-pending
 * so the next cycle retries.  Returns true on success.
 */
static bool
RespawnWorker(VamanaLauncherWorker *w, const VamanaDatabaseRow *db,
			  TimestampTz now)
{
	BackgroundWorkerHandle *handle = RegisterDatabaseWorker(db, now);

	if (handle == NULL)
		return false;

	pfree(w->handle);
	w->handle = handle;
	w->started_time = 0;
	w->restart_state.restarting = false;
	w->restart_state.serviced_generation = w->restart_state.target_generation;
	w->restart_state.wait_started = 0;

	VamanaWorkerSetServicedRestartGeneration(db->dbOid, w->restart_state.serviced_generation);

	return true;
}

/*
 * Finish the slot drops a removed database's worker was handed but never got to.
 * Its shmem entry is about to be released, which discards the queue, and each
 * relid there is the only remaining name for a slot whose index is already gone.
 *
 * A worker drains its queue on shutdown, so this only has work when it died
 * first.  It is dead either way by the time we get here, so nothing holds these
 * slots and the drop belongs to whoever is retiring the entry.  Dropping a
 * logical slot does not require being connected to its database -- only decoding
 * from it does -- so the launcher can do it from its own.
 */
static void
DropSlotsAbandonedByStoppedWorker(Oid dbOid)
{
	Oid			relids[VAMANA_MAX_SLOT_DROP_QUEUE];
	int			count = VamanaWorkerTakePendingSlotDrops(dbOid, relids,
														VAMANA_MAX_SLOT_DROP_QUEUE);

	for (int i = 0; i < count; i++)
	{
		VamanaSlotDropResult result = VamanaReplicationDropIfExists(dbOid, relids[i]);

		if (result == VAMANA_SLOT_DROP_DONE)
			ereport(LOG,
					(errmsg("vamana launcher: dropped replication slot of removed index %u in database %u",
							relids[i], dbOid)));
		else if (result == VAMANA_SLOT_DROP_BUSY)
			ereport(WARNING,
					(errmsg("vamana launcher: replication slot of removed index %u in database %u is still held",
							relids[i], dbOid),
					 errhint("Drop it with pg_drop_replication_slot() once it is inactive.")));
		else
		{
			/*
			 * FAILED: TryDropSlot already logged the underlying error. There
			 * is no worker left to hand this back to -- the entry's dead
			 * worker's queue is what we just drained, and its shmem slot is
			 * about to be released -- so unlike the BUSY case this will not
			 * be retried automatically. Say so explicitly rather than letting
			 * the one earlier WARNING be the only trace.
			 */
			ereport(WARNING,
					(errmsg("vamana launcher: could not drop replication slot of removed index %u in database %u",
							relids[i], dbOid),
					 errdetail("The worker that owned this request is gone and nothing will retry the drop automatically."),
					 errhint("Drop it with pg_drop_replication_slot() once it is inactive.")));
		}
	}
}

/*
 * Mirror every reserved database's current enabled flag into its control
 * block.  This is what lets a backend waiting for a worker (see
 * VamanaWorkerWaitUntilAvailable) tell "disabled, no replacement is ever
 * coming" apart from "enabled, a replacement just hasn't published its pid
 * yet": heartbeat staleness alone cannot make that distinction once
 * heartbeat_ts is cleared uniformly on every deliberate stop. A database with
 * no row at all is left untouched here; F1's orphan-release pass owns that
 * case, and a released slot's baseline default (true) is irrelevant until
 * some future reservation republishes it.
 */
static void
PublishEnabledState(List *rows)
{
	ListCell   *lc;

	foreach(lc, rows)
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);
		VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(db->dbOid);

		if (entry != NULL)
			pg_atomic_write_u32(&entry->dbEnabled, db->enabled ? 1 : 0);
	}
}

/*
 * Update the ledger against the live worker set, and account for every death in
 * the shmem backoff state.  Liveness ground truth is the handle, never the
 * slot's workerPid.
 *
 * A running handle that has not yet been seen started gets its start time
 * stamped, so its eventual uptime can be measured.  A stopped handle is settled
 * by its stop reason: a crash is charged to backoff (a recovery if it stayed up
 * past the dwell threshold, an escalation otherwise) and dropped, keeping its
 * slot reserved so the next pass respawns; a disable is dropped with no
 * accrual, since a deliberate disable must never read as a crash-loop, and its
 * slot stays reserved so the paused database stays configured; a removal is
 * dropped with no accrual and its slot released, since there is no row left to
 * respawn for, after any replication-slot drops queued for that worker are
 * finished here rather than lost with the entry.  A stop that is part of an in-flight restart is left untouched
 * here: the restart convergence pass owns that handle and respawns it in
 * place.
 */
static void
ReconcileLedgerLiveness(List *rows, TimestampTz now)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *w = (VamanaLauncherWorker *) lfirst(lc);
		pid_t		pid;
		BgwHandleStatus status = GetBackgroundWorkerPid(w->handle, &pid);

		if (status == BGWH_STARTED && w->started_time == 0)
			w->started_time = now;

		if (status != BGWH_STOPPED)
			continue;

		switch (ClassifyWorkerStop(rows, w))
		{
			case STOP_RESTART_DRAIN:
				{
					/*
					 * Convergence owns this handle and will respawn it; do
					 * not drop the entry. But do clear heartbeat_ts here,
					 * the one point that knows this stop is a restart (as
					 * opposed to STOP_DISABLED, where nothing will ever
					 * spawn a replacement): otherwise a backend reaching
					 * VamanaWorkerWaitUntilAvailable during the window
					 * before the replacement publishes its own pid would
					 * see a heartbeat that ages into looking stale the
					 * longer this window stays open, defeating the bounded
					 * wait for exactly the case it exists to cover.
					 */
					VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(w->dbOid);

					if (entry != NULL)
						pg_atomic_write_u64(&entry->heartbeat_ts, 0);
				}
				continue;

			case STOP_DISABLED:
				VamanaWorkerBackoffClear(w->dbOid);
				break;

			case STOP_REMOVED:
				VamanaWorkerBackoffClear(w->dbOid);
				DropSlotsAbandonedByStoppedWorker(w->dbOid);
				VamanaWorkerReleaseSlot(w->dbOid);
				break;

			case STOP_CRASH:
				{
					bool		recovered = w->started_time != 0 &&
						TimestampDifferenceMilliseconds(w->started_time, now) >=
						VAMANA_BACKOFF_DWELL_RESET_MS;

					VamanaWorkerBackoffRecordDeath(w->dbOid, recovered);
					VamanaWorkerClearDeadEntry(w->dbOid);
					break;
				}
		}

		WorkerLedger = foreach_delete_current(WorkerLedger, lc);
		pfree(w->handle);
		pfree(w);
	}
}

/*
 * Stop every live worker whose database has left the enabled set (disabled or
 * removed). TerminateBackgroundWorker delivers SIGTERM, which the flag-only
 * handler turns into the graceful drain-and-stop; the next reconcile pass
 * observes the stopped handle and settles it via ClassifyWorkerStop.
 * Idempotent: a worker still draining reports BGWH_STARTED, so a repeat
 * wakeup re-signals it harmlessly.
 */
static void
TerminateDisabledWorkers(List *rows)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *w = (VamanaLauncherWorker *) lfirst(lc);
		pid_t		pid;

		if (IsDatabaseEnabled(rows, w->dbOid))
			continue;

		if (GetBackgroundWorkerPid(w->handle, &pid) == BGWH_STARTED)
			TerminateBackgroundWorker(w->handle);
	}
}

static void
ExecuteRestartAction(VamanaRestartAction action, VamanaLauncherWorker *ledger,
					  const VamanaDatabaseRow *db, TimestampTz now)
{
	switch (action)
	{
		case RESTART_NOOP:
		case RESTART_WAIT:
			break;

		case RESTART_TERMINATE:
			TerminateBackgroundWorker(ledger->handle);
			break;

		case RESTART_WAIT_TIMEOUT:
			{
				char		safeDatname[NAMEDATALEN * 4];

				CopySanitizedDatname(safeDatname, sizeof(safeDatname), db->datname);
				ereport(WARNING,
						(errmsg("vamana launcher: worker for database \"%s\" did not stop within %d ms",
								safeDatname, vamana_worker_stop_timeout_ms),
						 errhint("Restart remains pending until worker exits.")));
			}
			break;

		case RESTART_RESPAWN:
			RespawnWorker(ledger, db, now);
			break;
	}
}

static void
ReconcileRestartConvergence(List *rows, TimestampTz now)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *ledger_entry = (VamanaLauncherWorker *) lfirst(lc);
		VamanaDatabaseRow *db;
		BgwHandleStatus handle_status;
		VamanaRestartAction action;
		pid_t		pid;

		db = FindEnabledDatabase(rows, ledger_entry->dbOid);
		if (db == NULL)
			continue;

		handle_status = GetBackgroundWorkerPid(ledger_entry->handle, &pid);
		action = VamanaRestartStateAdvance(&ledger_entry->restart_state,
										   db->restart_generation,
										   handle_status,
										   now);

		ExecuteRestartAction(action, ledger_entry, db, now);
	}
}

/* Writes into the pre-sized VamanaReservedOidCollector; see its own comment above. */
static void
CollectReservedDbOids(VamanaWorkerShmem *entry, void *ctxArg)
{
	VamanaReservedOidCollector *ctx = (VamanaReservedOidCollector *) ctxArg;

	Assert(ctx->count < ctx->capacity);
	ctx->oids[ctx->count++] = entry->dbOid;
}

/* dbOid is among the first count entries of oids, linearly; count is bounded by svs.max_databases. */
static bool
ReservedOidsContains(const Oid *oids, int count, Oid dbOid)
{
	for (int i = 0; i < count; i++)
		if (oids[i] == dbOid)
			return true;
	return false;
}

/*
 * Release any reserved control block whose database matches no row in the
 * table at all, independent of WorkerLedger.  This is the pass a paused
 * (STOP_DISABLED) database's slot needs once its row is later deleted: by
 * then the ledger entry is long gone, correctly dropped the cycle its worker
 * stopped for the disable, so ClassifyWorkerStop never gets a second look
 * with both "handle observed stopped" and "row already gone" true at once.
 * The same gap strands a database dropped without ever being disabled first.
 *
 * A slot reserved for an enrollment whose transaction has not yet committed
 * looks identical, briefly, to a genuinely orphaned one: reservation happens
 * at that transaction's PRE_COMMIT, a moment before its row becomes visible
 * to this launcher's own snapshot.  So a slot is not released the first
 * cycle it is found with no matching row; it is tracked in OrphanCandidates
 * and only released once that state has persisted for at least
 * VAMANA_ORPHAN_SLOT_GRACE_MS.  A candidate that regains a row, or stops
 * being reserved, before then is simply dropped with no side effect.
 *
 * Returns the naptime contribution: milliseconds until the earliest
 * surviving candidate clears its grace period, or the launcher's normal
 * naptime if there are none, so a pending release is not made to oversleep.
 *
 * reservedOids/reservedCount is the caller's single collection for this
 * cycle (ReconcileUnledgeredWorkers shares it too), not re-collected here:
 * one walk of the reserved array under the header lock per cycle, not two.
 */
static long
ReleaseOrphanedReservedSlots(List *rows, TimestampTz now,
							  const Oid *reservedOids, int reservedCount)
{
	long		naptime = VAMANA_LAUNCHER_NAPTIME_MS;
	MemoryContext oldCtx;
	ListCell   *lc;

	/*
	 * OrphanCandidates, like WorkerLedger, must outlive this cycle's context;
	 * every mutation of it happens in TopMemoryContext.
	 */
	oldCtx = MemoryContextSwitchTo(TopMemoryContext);

	/* A candidate that regained a row or is no longer reserved starts over if it orphans again. */
	foreach(lc, OrphanCandidates)
	{
		VamanaOrphanCandidate *c = (VamanaOrphanCandidate *) lfirst(lc);

		if (FindDatabaseRow(rows, c->dbOid) != NULL ||
			!ReservedOidsContains(reservedOids, reservedCount, c->dbOid))
		{
			OrphanCandidates = foreach_delete_current(OrphanCandidates, lc);
			pfree(c);
		}
	}

	for (int i = 0; i < reservedCount; i++)
	{
		Oid			dbOid = reservedOids[i];
		VamanaOrphanCandidate *candidate = NULL;
		long		remaining;

		if (FindDatabaseRow(rows, dbOid) != NULL)
			continue;

		foreach(lc, OrphanCandidates)
		{
			VamanaOrphanCandidate *c = (VamanaOrphanCandidate *) lfirst(lc);

			if (c->dbOid == dbOid)
			{
				candidate = c;
				break;
			}
		}

		if (candidate == NULL)
		{
			candidate = palloc(sizeof(VamanaOrphanCandidate));
			candidate->dbOid = dbOid;
			candidate->firstSeenOrphaned = now;
			OrphanCandidates = lappend(OrphanCandidates, candidate);
		}

		if (TimestampDifferenceExceeds(candidate->firstSeenOrphaned, now,
										VAMANA_ORPHAN_SLOT_GRACE_MS))
		{
			VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);

			/*
			 * A live worker with no row and no ledger entry is exactly the
			 * survivor ReconcileUnledgeredWorkers is asking to stop, in this
			 * same cycle, via stopRequested; releasing its slot out from
			 * under it here would hand a still-running process's control
			 * block to whatever reserves it next. Wait for that ask to take
			 * effect instead of racing it.
			 */
			if (entry == NULL || !VamanaWorkerEntryIsLive(entry))
			{
				DropSlotsAbandonedByStoppedWorker(dbOid);
				VamanaWorkerReleaseSlot(dbOid);
				OrphanCandidates = list_delete_ptr(OrphanCandidates, candidate);
				pfree(candidate);
				continue;
			}

			naptime = Min(naptime, VAMANA_LAUNCHER_MIN_NAPTIME_MS);
			continue;
		}

		remaining = VAMANA_ORPHAN_SLOT_GRACE_MS -
			TimestampDifferenceMilliseconds(candidate->firstSeenOrphaned, now);
		naptime = Min(naptime, remaining);
	}

	MemoryContextSwitchTo(oldCtx);

	return naptime;
}

/*
 * Ask a live, reserved worker with no ledger entry to stop, when its database
 * is disabled or removed, or its row's restart_generation no longer matches
 * what this control block records as served.  This is the survivor case: a
 * worker inherited live across this launcher's own restart has no ledger
 * entry (the ledger is rebuilt empty on every launcher restart) and so no
 * BackgroundWorkerHandle either, which rules out TerminateBackgroundWorker.
 * The shared control block is not opaque the way a handle is, so it is the
 * channel used instead: set stopRequested and wake the worker's own latch
 * directly, no handle needed.
 *
 * This pass owns only the ask. Once the worker actually stops,
 * VamanaWorkerEntryIsLive turns false and the ordinary spawn-diff loop in
 * VamanaLauncherReconcileWorkers picks the database back up exactly like any
 * other missing worker, registering it (and a fresh ledger entry) for the
 * first time -- there is no separate respawn path for this case.
 *
 * Idempotent to repeat every cycle until the worker exits: setting an
 * already-set flag and waking an already-woken latch cost nothing.
 *
 * Returns the naptime contribution: a short retry whenever a stop was just
 * requested, since this survivor's bgw_notify_pid names the launcher
 * instance that registered it, not this one, so nothing else wakes this
 * launcher when it actually stops; the launcher's normal naptime otherwise.
 *
 * reservedOids/reservedCount is the caller's single collection for this
 * cycle (shared with ReleaseOrphanedReservedSlots), not re-collected here.
 *
 * Known gap, pre-existing and not specific to this pass: a survivor that
 * crashes on its own, rather than being asked to stop, never gets a ledger
 * entry either way, so ReconcileLedgerLiveness's STOP_CRASH arm -- the only
 * caller of VamanaWorkerBackoffRecordDeath -- never sees that death. The
 * ordinary spawn-diff loop below still respawns it (backoff-gated, since
 * BackoffRemainingMs is checked there regardless of ledger membership), but
 * with no failure recorded for this crash, so it gets one free, unthrottled
 * respawn before backoff starts applying on a second consecutive failure.
 * The survivor scenario itself predates this pass (the pre-existing "don't
 * spawn into an already-live worker's slot" guard); this pass is only the
 * first to deliberately manage survivors, which is why the gap is noted
 * here rather than fixed here.
 */
static long
ReconcileUnledgeredWorkers(List *rows, const Oid *reservedOids, int reservedCount)
{
	long		naptime = VAMANA_LAUNCHER_NAPTIME_MS;

	for (int i = 0; i < reservedCount; i++)
	{
		Oid			dbOid = reservedOids[i];
		VamanaWorkerShmem *entry;
		VamanaDatabaseRow *db;
		bool		wantStop;

		if (FindLedgerEntry(dbOid) != NULL)
			continue;

		entry = VamanaWorkerLookupSlot(dbOid);
		if (entry == NULL || !VamanaWorkerEntryIsLive(entry))
			continue;

		db = FindEnabledDatabase(rows, dbOid);
		wantStop = (db == NULL) || (db->restart_generation != entry->servicedRestartGeneration);

		if (wantStop)
		{
			pg_atomic_write_u32(&entry->stopRequested, 1);
			SetLatch(&entry->workerLatch);

			/*
			 * This survivor was registered by a launcher instance that no
			 * longer exists, so its bgw_notify_pid names a dead process:
			 * nothing wakes this launcher when it actually stops. Fold in a
			 * short retry so the spawn-diff loop below picks up the
			 * replacement soon after, rather than waiting out the full
			 * naptime (backoff-remaining aside).
			 */
			naptime = Min(naptime, VAMANA_LAUNCHER_MIN_NAPTIME_MS);
		}
	}

	return naptime;
}
