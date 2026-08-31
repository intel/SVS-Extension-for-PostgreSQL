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

#include "vamana.h"
#include "vamana_replication.h"
#include "vamanalauncher.h"
#include "vamanaworker.h"

#include "access/xact.h"
#include "commands/async.h"
#include "commands/dbcommands.h"
#include "commands/extension.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
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
} VamanaDatabaseRow;

/*
 * The launcher's handle ledger, in TopMemoryContext for the process lifetime.
 * Distinct from the per-cycle context used for the row list.
 */
static List *WorkerLedger = NIL;

static long VamanaLauncherReconcileWorkers(void);
static char *VamanaDatabasesQualifiedName(void);
static List *ReadDatabaseRows(void);
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

void
VamanaLauncherMain(Datum main_arg)
{
	pqsignal(SIGHUP, SignalHandlerForConfigReload);
	pqsignal(SIGTERM, die);
	BackgroundWorkerUnblockSignals();

	BackgroundWorkerInitializeConnection(vamana_launcher_database, NULL, 0);

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

	cycleCtx = AllocSetContextCreate(TopMemoryContext,
									 "vamana launcher reconcile",
									 ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(cycleCtx);

	rows = ReadDatabaseRows();

	ReconcileLedgerLiveness(rows, now);
	TerminateDisabledWorkers(rows);
	if (WorkerLedger != NIL)
		ReconcileRestartConvergence(rows, now);

	foreach(lc, EnabledRowsOf(rows))
	{
		VamanaDatabaseRow *db = (VamanaDatabaseRow *) lfirst(lc);
		VamanaLauncherBackoff backoff;
		long		remaining;

		if (FindLedgerEntry(db->dbOid) != NULL)
			continue;

		/* A restarted launcher's ledger is empty; don't spawn into an already-live worker's slot. */
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
	if (VamanaWorkerReserveSlot(dbOid, NULL) != NULL)
		return true;

	ereport(LOG,
			(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
			 errmsg("vamana launcher could not reserve a slot for database \"%s\"",
					datname),
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

	scanCtx = AllocSetContextCreate(TopMemoryContext,
									"vamana launcher initial scan",
									ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(scanCtx);

	rows = ReadDatabaseRows();

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
	list = lappend(list, db);
	MemoryContextSwitchTo(oldCtx);

	return list;
}

/*
 * Schema-qualified "vamana_databases", resolved via the svs extension's own
 * namespace rather than search_path, so a same-named table planted earlier on
 * the path can never be read instead of the real one.  NULL if the extension
 * (and therefore the table) doesn't exist yet in this database; not an error,
 * since a later NOTIFY or the fallback timeout retries.
 */
static char *
VamanaDatabasesQualifiedName(void)
{
	Oid			extOid = get_extension_oid("svs", true);
	Oid			nspOid;

	if (!OidIsValid(extOid))
		return NULL;

	nspOid = get_extension_schema(extOid);
	if (!OidIsValid(get_relname_relid("vamana_databases", nspOid)))
		return NULL;

	return psprintf("%s.%s", quote_identifier(get_namespace_name(nspOid)),
					quote_identifier("vamana_databases"));
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
 */
static List *
ReadDatabaseRows(void)
{
	List	   *result = NIL;
	MemoryContext callerCtx = CurrentMemoryContext;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		PopActiveSnapshot();
		AbortCurrentTransaction();
		ereport(WARNING, (errmsg("vamana launcher: SPI_connect failed")));
		return NIL;
	}

	{
		char	   *qualifiedName = VamanaDatabasesQualifiedName();

		if (qualifiedName != NULL)
		{
			int			ret = SPI_execute(psprintf("SELECT datname, restart_generation, enabled FROM %s",
													qualifiedName),
										  true, 0);

			if (ret != SPI_OK_SELECT)
				ereport(WARNING, (errmsg("vamana launcher: failed to read vamana_databases")));

			for (uint64 i = 0; ret == SPI_OK_SELECT && i < SPI_processed; i++)
			{
				bool		datnameIsNull;
				bool		restartGenIsNull;
				bool		enabledIsNull;
				Name		datname = DatumGetName(SPI_getbinval(SPI_tuptable->vals[i],
																 SPI_tuptable->tupdesc,
																 1, &datnameIsNull));
				int64		restart_generation = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
																			   SPI_tuptable->tupdesc,
																			   2, &restartGenIsNull));
				bool		enabled = DatumGetBool(SPI_getbinval(SPI_tuptable->vals[i],
																 SPI_tuptable->tupdesc,
																 3, &enabledIsNull));
				Oid			dbOid;

				if (datnameIsNull || restartGenIsNull || enabledIsNull)
					continue;

				dbOid = get_database_oid(NameStr(*datname), true);
				if (!OidIsValid(dbOid))
				{
					ereport(LOG,
							(errmsg("vamana launcher: database \"%s\" does not exist; skipping",
									NameStr(*datname))));
					continue;
				}

				result = AppendDatabaseRow(result, dbOid, NameStr(*datname),
										   restart_generation, enabled, callerCtx);
			}
		}
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

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

	if (!VamanaWorkerReserveSlotOrLog(db->dbOid, db->datname))
		return NULL;

	memset(&bgw, 0, sizeof(bgw));
	snprintf(bgw.bgw_name, BGW_MAXLEN, "vamana worker: %s", db->datname);
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
						db->datname),
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

		/* FAILED is not reported here: the try-drop already logged the error. */
		if (result == VAMANA_SLOT_DROP_DONE)
			ereport(LOG,
					(errmsg("vamana launcher: dropped replication slot of removed index %u in database %u",
							relids[i], dbOid)));
		else if (result == VAMANA_SLOT_DROP_BUSY)
			ereport(WARNING,
					(errmsg("vamana launcher: replication slot of removed index %u in database %u is still held",
							relids[i], dbOid),
					 errhint("Drop it with pg_drop_replication_slot() once it is inactive.")));
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
				/* Convergence owns this handle; do not touch it. */
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
			ereport(WARNING,
					(errmsg("vamana launcher: worker for database \"%s\" did not stop within %d ms",
							db->datname, vamana_worker_stop_timeout_ms),
					 errhint("Restart remains pending until worker exits.")));
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
