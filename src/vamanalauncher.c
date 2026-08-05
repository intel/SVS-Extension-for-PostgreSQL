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
#include "utils/wait_classes.h"

/* Fallback wake interval when nothing else wakes the loop; matches core. */
#define VAMANA_LAUNCHER_NAPTIME_MS		180000L

/* NOTIFY channel published by the vamana_databases_changed trigger (M1). */
#define VAMANA_DATABASES_CHANNEL		"vamana_databases_changed"

/*
 * One tracked per-database worker: the handle returned by
 * RegisterDynamicBackgroundWorker is the authoritative liveness signal (via
 * GetBackgroundWorkerPid), never the slot's workerPid, which is set only once
 * the worker reaches readiness (see B1 Decision 4).  The ledger is
 * launcher-local and correctly rebuilt from a fresh scan after a launcher
 * restart.
 */
typedef struct VamanaLauncherWorker
{
	Oid			dbOid;
	BackgroundWorkerHandle *handle;
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
} VamanaEnabledDatabase;

/*
 * The launcher's handle ledger, in TopMemoryContext for the process lifetime.
 * Distinct from the per-cycle context used for the enabled-database list.
 */
static List *WorkerLedger = NIL;

static void VamanaLauncherReconcileWorkers(void);
static List *ReadEnabledDatabases(void);
static void MaterializeInitialConfig(void);
static VamanaLauncherWorker *FindLedgerEntry(Oid dbOid);
static void SpawnWorker(const VamanaEnabledDatabase *db);
static void ReapStoppedWorkers(void);

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

		VamanaLauncherReconcileWorkers();

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_EXIT_ON_PM_DEATH,
					   VAMANA_LAUNCHER_NAPTIME_MS,
					   PG_WAIT_EXTENSION);
		(void) rc;
	}
}

/*
 * Reconcile the live worker set against the table on every wake.  Reaping
 * stopped handles first keeps the ledger honest before the spawn diff reads it.
 */
static void
VamanaLauncherReconcileWorkers(void)
{
	MemoryContext cycleCtx;
	MemoryContext oldCtx;
	List	   *enabled;
	ListCell   *lc;

	ReapStoppedWorkers();

	cycleCtx = AllocSetContextCreate(TopMemoryContext,
									 "vamana launcher reconcile",
									 ALLOCSET_DEFAULT_SIZES);
	oldCtx = MemoryContextSwitchTo(cycleCtx);

	enabled = ReadEnabledDatabases();

	foreach(lc, enabled)
	{
		VamanaEnabledDatabase *db = (VamanaEnabledDatabase *) lfirst(lc);

		if (FindLedgerEntry(db->dbOid) == NULL)
			SpawnWorker(db);
	}

	MemoryContextSwitchTo(oldCtx);
	MemoryContextDelete(cycleCtx);
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
					 errhint("Increase max_vamana_databases and restart.")));
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
					  MemoryContext callerCtx)
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
		int			ret = SPI_execute("SELECT datname FROM vamana_databases WHERE enabled",
									  true, 0);

		if (ret != SPI_OK_SELECT)
			ereport(WARNING, (errmsg("vamana launcher: failed to read vamana_databases")));

		for (uint64 i = 0; ret == SPI_OK_SELECT && i < SPI_processed; i++)
		{
			bool		isnull;
			Name		datname = DatumGetName(SPI_getbinval(SPI_tuptable->vals[i],
															 SPI_tuptable->tupdesc,
															 1, &isnull));
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
										   callerCtx);
		}
	}

	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();

	return result;
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

/*
 * Register a per-database worker and record its handle in the ledger.  The
 * worker is BGW_NEVER_RESTART with bgw_notify_pid set to the launcher, so the
 * postmaster never respawns it and instead signals the launcher on its death.
 */
static void
SpawnWorker(const VamanaEnabledDatabase *db)
{
	BackgroundWorker bgw;
	BackgroundWorkerHandle *handle;
	VamanaLauncherWorker *entry;
	MemoryContext oldCtx;

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
	WorkerLedger = lappend(WorkerLedger, entry);

	MemoryContextSwitchTo(oldCtx);
}

/*
 * Drop ledger entries whose worker has exited.  Liveness ground truth is the
 * handle, never the slot's workerPid.  The stopped worker's slot stays
 * reserved (config persists); only the launcher's spawn bookkeeping is cleared,
 * so the next reconcile pass re-spawns an enabled database whose worker died.
 */
static void
ReapStoppedWorkers(void)
{
	ListCell   *lc;

	foreach(lc, WorkerLedger)
	{
		VamanaLauncherWorker *w = (VamanaLauncherWorker *) lfirst(lc);
		pid_t		pid;

		if (GetBackgroundWorkerPid(w->handle, &pid) == BGWH_STOPPED)
		{
			WorkerLedger = foreach_delete_current(WorkerLedger, lc);
			pfree(w->handle);
			pfree(w);
		}
	}
}
