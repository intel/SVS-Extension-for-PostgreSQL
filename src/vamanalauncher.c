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
#include "vamanalauncher.h"
#include "vamanaworker.h"

#include "access/xact.h"
#include "catalog/namespace.h"
#include "commands/async.h"
#include "commands/dbcommands.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "postmaster/interrupt.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"
#include "utils/wait_classes.h"

/* Fallback wake interval when nothing else wakes the loop; matches core. */
#define VAMANA_LAUNCHER_NAPTIME_MS		180000L

/* NOTIFY channel published by the vamana_databases_changed trigger (M1). */
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
 * the worker reaches readiness (see B1 Decision 4).  The ledger is
 * launcher-local and correctly rebuilt from a fresh scan after a launcher
 * restart.
 */
typedef enum VamanaRestartAction
{
	RESTART_NOOP,				/* no restart needed */
	RESTART_TERMINATE,			/* mismatch: terminate and wait */
	RESTART_WAIT,				/* waiting for handle to stop */
	RESTART_WAIT_TIMEOUT,		/* wait timeout exceeded */
	RESTART_RESPAWN				/* handle stopped: caller respawns */
} VamanaRestartAction;

typedef struct VamanaRestartState
{
	bool		restarting;			/* is a restart in flight? */
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

	int64		serviced_generation;
	VamanaRestartState restart_state;
} VamanaLauncherWorker;

/*
 * One enabled database, as read from the config table.  The name is captured
 * during the SPI scan and carried alongside the OID so the spawn and
 * initial-scan paths never re-enter the catalogs: those paths run outside the
 * scan's transaction, where a syscache lookup would have no snapshot.
 */
typedef struct VamanaEnabledDatabase
{
	Oid			dbOid;
	char	   *datname;
	int64		restart_generation;
} VamanaEnabledDatabase;

/*
 * The launcher's handle ledger, in TopMemoryContext for the process lifetime.
 * Distinct from the per-cycle context used for the enabled-database list.
 */
static List *WorkerLedger = NIL;

static long VamanaLauncherReconcileWorkers(void);
static List *ReadEnabledDatabases(void);
static void MaterializeInitialConfig(void);
static VamanaLauncherWorker *FindLedgerEntry(Oid dbOid);
static bool IsDatabaseEnabled(List *enabled, Oid dbOid);
static bool IsDeliberateStop(List *enabled, const VamanaLauncherWorker *w);
static VamanaRestartAction VamanaRestartStateAdvance(VamanaRestartState *state,
													 int64 serviced_generation,
													 int64 current_generation,
													 BgwHandleStatus handle_status,
													 TimestampTz now);
static void SpawnWorker(const VamanaEnabledDatabase *db, TimestampTz now);
static void ReconcileLedgerLiveness(List *enabled, TimestampTz now);
static void TerminateDisabledWorkers(List *enabled);
static void ReconcileRestartConvergence(List *enabled, TimestampTz now);
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
		 * leak and is where a payload-parsing future (M9's restart:<dbname>)
		 * will hook in.  ProcessNotifyInterrupt refuses to run inside a
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
 * naptime for the following WaitLatch.  The enabled set is read first so the
 * liveness pass can tell a crash (accrue backoff) from a legitimate disable
 * (drop with no accrual); the spawn diff then respawns any enabled database
 * whose worker is gone, subject to its backoff, folding the naptime down to the
 * soonest eligible retry so a backing-off database is not made to oversleep.
 */
static long
VamanaLauncherReconcileWorkers(void)
{
	MemoryContext cycleCtx;
	MemoryContext oldCtx;
	List	   *enabled;
	ListCell   *lc;
	TimestampTz now = GetCurrentTimestamp();
	long		naptime = VAMANA_LAUNCHER_NAPTIME_MS;

	cycleCtx = AllocSetContextCreate(TopMemoryContext,
									 "vamana launcher reconcile",
									 ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(cycleCtx);

	enabled = ReadEnabledDatabases();

	ReconcileLedgerLiveness(enabled, now);
	TerminateDisabledWorkers(enabled);
	if (WorkerLedger != NIL)
		ReconcileRestartConvergence(enabled, now);

	foreach(lc, enabled)
	{
		VamanaEnabledDatabase *db = (VamanaEnabledDatabase *) lfirst(lc);
		VamanaLauncherBackoff backoff;
		long		remaining;

		if (FindLedgerEntry(db->dbOid) != NULL)
			continue;

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
 * Reserve a slot for every enabled database before any worker is registered,
 * then publish initialScanDone.  This is the restart-durable projection of the
 * config table into shmem: at postmaster start slots[] is empty, and without
 * this a CREATE INDEX / INSERT in a long-enabled database would read "no slot"
 * and hard-fail "not enabled" in the window before that database's worker
 * self-reserves (see B1 Decision 2).
 *
 * Reservation is idempotent (VamanaWorkerReserveSlot), so overlap with M3's
 * PRE_COMMIT trigger or a worker's own startup reservation is a no-op.
 */
static void
MaterializeInitialConfig(void)
{
	MemoryContext scanCtx;
	MemoryContext oldCtx;
	List	   *enabled;
	ListCell   *lc;

	scanCtx = AllocSetContextCreate(TopMemoryContext,
									"vamana launcher initial scan",
									ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(scanCtx);

	enabled = ReadEnabledDatabases();

	foreach(lc, enabled)
	{
		VamanaEnabledDatabase *db = (VamanaEnabledDatabase *) lfirst(lc);

		if (VamanaWorkerReserveSlot(db->dbOid) == NULL)
			ereport(LOG,
					(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
					 errmsg("vamana launcher could not reserve a slot for database \"%s\"",
							db->datname),
					 errhint("Increase svs.max_databases and restart.")));
	}

	VamanaWorkerSetInitialScanDone();

	MemoryContextSwitchTo(oldCtx);
	MemoryContextDelete(scanCtx);
}

/* -----------------------------------------------------------------------
 * Table read (SPI)
 * ----------------------------------------------------------------------- */

/*
 * Append an enabled-database entry, capturing its name, in callerCtx.  Both the
 * list cell and the name string outlive the SPI transaction, so the spawn and
 * initial-scan paths never re-enter the catalogs.  Deduplicates by OID.
 */
static List *
AppendEnabledDatabase(List *list, Oid dbOid, const char *datname,
					  int64 restart_generation, MemoryContext callerCtx)
{
	VamanaEnabledDatabase *db;
	MemoryContext oldCtx;
	ListCell   *lc;

	foreach(lc, list)
		if (((VamanaEnabledDatabase *) lfirst(lc))->dbOid == dbOid)
			return list;

	oldCtx = MemoryContextSwitchTo(callerCtx);
	db = palloc(sizeof(VamanaEnabledDatabase));
	db->dbOid = dbOid;
	db->datname = pstrdup(datname);
	db->restart_generation = restart_generation;
	list = lappend(list, db);
	MemoryContextSwitchTo(oldCtx);

	return list;
}

/*
 * Return the currently-enabled databases, allocated in the caller's memory
 * context (which must outlive the SPI transaction opened here).  Name-to-OID
 * resolution is tolerant: a row whose database no longer exists is skipped and
 * logged rather than aborting the scan (see B1 Decision 1 and 5).
 */
static List *
ReadEnabledDatabases(void)
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

	/*
	 * The launcher may connect before CREATE EXTENSION has run in
	 * launcher_database.  A missing table is not an error: a later NOTIFY or
	 * the fallback timeout picks it up once the table exists.
	 */
	if (OidIsValid(RelnameGetRelid("vamana_databases")))
	{
		int			ret = SPI_execute("SELECT datname, restart_generation FROM vamana_databases WHERE enabled",
									  true, 0);

		if (ret != SPI_OK_SELECT)
			ereport(WARNING, (errmsg("vamana launcher: failed to read vamana_databases")));

		for (uint64 i = 0; ret == SPI_OK_SELECT && i < SPI_processed; i++)
		{
			bool		isnull;
			Name		datname = DatumGetName(SPI_getbinval(SPI_tuptable->vals[i],
															 SPI_tuptable->tupdesc,
															 1, &isnull));
			int64		restart_generation = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[i],
																		   SPI_tuptable->tupdesc,
																		   2, &isnull));
			Oid			dbOid;

			if (isnull)
				continue;

			dbOid = get_database_oid(NameStr(*datname), true);
			if (!OidIsValid(dbOid))
			{
				ereport(LOG,
						(errmsg("vamana launcher: enabled database \"%s\" does not exist; skipping",
								NameStr(*datname))));
				continue;
			}

			result = AppendEnabledDatabase(result, dbOid, NameStr(*datname),
										   restart_generation, callerCtx);
		}
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

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

static bool
IsDatabaseEnabled(List *enabled, Oid dbOid)
{
	ListCell   *lc;

	foreach(lc, enabled)
	{
		if (((VamanaEnabledDatabase *) lfirst(lc))->dbOid == dbOid)
			return true;
	}
	return false;
}

static VamanaEnabledDatabase *
FindEnabledDatabase(List *enabled, Oid dbOid)
{
	ListCell   *lc;

	foreach(lc, enabled)
	{
		VamanaEnabledDatabase *db = (VamanaEnabledDatabase *) lfirst(lc);

		if (db->dbOid == dbOid)
			return db;
	}
	return NULL;
}

/*
 * True when a worker's death is an operator-intended stop rather than a crash,
 * so its exit must not accrue respawn backoff.  A disabled database and an
 * in-flight restart are both deliberate stops.
 */
static bool
IsDeliberateStop(List *enabled, const VamanaLauncherWorker *w)
{
	return !IsDatabaseEnabled(enabled, w->dbOid) || w->restart_state.restarting;
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
 * Returns the action the caller should take: NOOP (no restart needed),
 * TERMINATE (start draining), WAIT (still draining), WAIT_TIMEOUT (timeout
 * exceeded, still waiting), or RESPAWN (start new).
 */
static VamanaRestartAction
VamanaRestartStateAdvance(VamanaRestartState *state,
						  int64 serviced_generation,
						  int64 current_generation,
						  BgwHandleStatus handle_status,
						  TimestampTz now)
{
	if (!state->restarting && serviced_generation == current_generation)
	{
		/* No restart needed; idle. */
		return RESTART_NOOP;
	}

	if (!state->restarting && serviced_generation != current_generation)
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
		/* Handle stopped: caller will respawn and update serviced_generation. */
		state->restarting = false;
		state->wait_started = 0;
		return RESTART_RESPAWN;
	}

	/* Should not reach. */
	return RESTART_NOOP;
}

/*
 * Register a per-database worker and record its handle in the ledger.  The
 * worker is BGW_NEVER_RESTART with bgw_notify_pid set to the launcher, so the
 * postmaster never respawns it and instead signals the launcher on its death.
 *
 * The slot is reserved here, before registration, for two reasons: it gives the
 * backoff counters a durable home even for a worker that FATALs at startup
 * before it can self-reserve (the crash-loop case), and it avoids registering a
 * worker that could only fail the capacity check.  Reservation is idempotent,
 * so overlap with the worker's own startup reservation is a no-op.
 */
static void
SpawnWorker(const VamanaEnabledDatabase *db, TimestampTz now)
{
	BackgroundWorker bgw;
	BackgroundWorkerHandle *handle;
	VamanaLauncherWorker *entry;
	MemoryContext oldCtx;

	if (VamanaWorkerReserveSlot(db->dbOid) == NULL)
	{
		ereport(LOG,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("vamana launcher could not reserve a slot for database \"%s\"",
						db->datname),
				 errhint("Increase svs.max_databases and restart.")));
		return;
	}

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

	/*
	 * RegisterDynamicBackgroundWorker palloc's the returned handle in the
	 * current context.  The ledger outlives the per-cycle reconcile context,
	 * so both the handle and its entry must be allocated in TopMemoryContext;
	 * otherwise the handle dangles once the cycle context is freed.
	 */
	oldCtx = MemoryContextSwitchTo(TopMemoryContext);

	if (!RegisterDynamicBackgroundWorker(&bgw, &handle))
	{
		MemoryContextSwitchTo(oldCtx);
		ereport(LOG,
				(errmsg("vamana launcher could not register worker for database \"%s\"",
						db->datname),
				 errhint("Consider increasing max_worker_processes.")));
		return;
	}

	entry = palloc(sizeof(VamanaLauncherWorker));
	entry->dbOid = db->dbOid;
	entry->handle = handle;
	entry->started_time = 0;
	entry->serviced_generation = 0;
	entry->restart_state.restarting = false;
	entry->restart_state.target_generation = 0;
	entry->restart_state.wait_started = 0;
	WorkerLedger = lappend(WorkerLedger, entry);

	MemoryContextSwitchTo(oldCtx);

	VamanaWorkerBackoffStampAttempt(db->dbOid, now);
}

/*
 * Update the ledger against the live worker set, and account for every death in
 * the shmem backoff state.  Liveness ground truth is the handle, never the
 * slot's workerPid.
 *
 * A running handle that has not yet been seen started gets its start time
 * stamped, so its eventual uptime can be measured.  A stopped handle is dropped
 * from the ledger (its slot stays reserved, so the next pass respawns it) and
 * its death is charged to backoff: a recovery if the worker was enabled and
 * stayed up past the dwell threshold, an escalation otherwise.  A database no
 * longer in the enabled set is dropped with no accrual — a deliberate disable
 * must never read as a crash-loop — which also covers a worker that FATALs at
 * connect on a since-dropped database.
 */
static void
ReconcileLedgerLiveness(List *enabled, TimestampTz now)
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

		if (IsDeliberateStop(enabled, w))
			VamanaWorkerBackoffClear(w->dbOid);
		else
		{
			bool		recovered = w->started_time != 0 &&
				TimestampDifferenceMilliseconds(w->started_time, now) >=
				VAMANA_BACKOFF_DWELL_RESET_MS;

			VamanaWorkerBackoffRecordDeath(w->dbOid, recovered);
		}

		WorkerLedger = foreach_delete_current(WorkerLedger, lc);
		pfree(w->handle);
		pfree(w);
	}
}

/*
 * Stop every live worker whose database has left the enabled set.
 * TerminateBackgroundWorker delivers SIGTERM, which the flag-only handler turns
 * into the graceful drain-and-stop; the next reconcile pass observes the
 * stopped handle, drops the ledger entry with no backoff accrual
 * (IsDeliberateStop), and leaves the slot reserved so the paused database stays
 * configured.  Idempotent: a worker still draining reports BGWH_STARTED, so a
 * repeat wakeup re-signals it harmlessly.
 */
static void
TerminateDisabledWorkers(List *enabled)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *w = (VamanaLauncherWorker *) lfirst(lc);
		pid_t		pid;

		if (IsDatabaseEnabled(enabled, w->dbOid))
			continue;

		if (GetBackgroundWorkerPid(w->handle, &pid) == BGWH_STARTED)
			TerminateBackgroundWorker(w->handle);
	}
}

static void
ExecuteRestartAction(VamanaRestartAction action, VamanaLauncherWorker *ledger,
					  const VamanaEnabledDatabase *db, TimestampTz now)
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
			SpawnWorker(db, now);
			ledger->serviced_generation = ledger->restart_state.target_generation;
			break;
	}
}

static void
ReconcileRestartConvergence(List *enabled, TimestampTz now)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *ledger_entry = (VamanaLauncherWorker *) lfirst(lc);
		VamanaEnabledDatabase *db;
		BgwHandleStatus handle_status;
		VamanaRestartAction action;
		pid_t		pid;

		db = FindEnabledDatabase(enabled, ledger_entry->dbOid);
		if (db == NULL)
			continue;

		handle_status = GetBackgroundWorkerPid(ledger_entry->handle, &pid);
		action = VamanaRestartStateAdvance(&ledger_entry->restart_state,
										   ledger_entry->serviced_generation,
										   db->restart_generation,
										   handle_status,
										   now);

		ExecuteRestartAction(action, ledger_entry, db, now);
	}
}
