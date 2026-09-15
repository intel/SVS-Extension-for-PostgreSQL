/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cpu_slots.c
 *
 * A pool of parked BGWORKER_CLASS_PARALLEL slots, registered one at a time
 * with raw RegisterDynamicBackgroundWorker rather than through a
 * ParallelContext (compare svs_parallel_build.c).  That distinction is the
 * whole point of this module: a build's parked workers are scoped to one
 * backend's statement and torn down when that statement's resource owner
 * releases, but a search slot set must survive across many statements and
 * transactions for as long as its owner decides to hold capacity.  There is
 * no ParallelContext, DSM segment, or shm_mq here, and none is needed: a
 * parked slot carries nothing but its own app-name description, which it
 * reads out of bgw_extra once at startup.
 *
 * This module only converges a set of slots on a target count and proves the
 * launch/park/terminate/reap lifecycle.  It grants no capacity of its own and
 * reads no grant; a later task decides when SvsSlotSetResize is called and
 * why (see the policy-seam comment on SvsSlotSetResize in svs_cpu_slots.h).
 */

#include "postgres.h"

#include "svs_cpu_slots.h"

#include "miscadmin.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/proc.h"
#include "utils/backend_status.h"
#include "utils/timestamp.h"

#include "svs_slot_naming.h"

#if PG_VERSION_NUM >= 170000
#include "utils/wait_classes.h"
#else
#include "pgstat.h"
#endif
#include "utils/wait_event.h"

/*
 * How long SvsSlotSetResize() waits for one slot to actually exit after
 * TerminateBackgroundWorker() before giving up and logging instead of
 * blocking forever.  parallel_terminate_count is only incremented once the
 * slot has actually exited, so a caller that never learns the wait expired
 * could believe capacity was released sooner than it really was; the
 * WARNING logged on expiry makes that gap visible rather than silent.
 */
#define SVS_SLOT_SHUTDOWN_TIMEOUT_MS	10000
#define SVS_SLOT_SHUTDOWN_POLL_MS		1000

/*
 * What a parked slot needs to describe itself in pg_stat_activity, carried in
 * bgw_extra rather than bgw_main_arg.  bgw_extra is memcpy'd into the shared
 * BackgroundWorkerSlot by RegisterDynamicBackgroundWorker, so this is a copy
 * the worker reads out of shared memory by value, never a pointer or an
 * index into memory that could have been freed or repurposed by the time the
 * worker starts.
 */
typedef struct SvsParkedSlotArg
{
	int32		slotIndex;
	int32		slotTotal;
	int32		reserved;
	char		datname[NAMEDATALEN];
} SvsParkedSlotArg;

typedef struct SvsSlotEntry
{
	BackgroundWorkerHandle *handle;
	int32		slotIndex;		/* label this entry's worker was given at
								 * registration; see AllocateSlotIndex() */
} SvsSlotEntry;

struct SvsSlotSet
{
	MemoryContext ctx;
	char		libraryName[MAXPGPATH];
	char		datname[NAMEDATALEN];

	SvsSlotEntry *entries;		/* array in ctx, capacity slots */
	int			capacity;
	int			count;			/* slots believed live right now */

	/*
	 * Set once a resize leaves count < target, cleared once a later resize
	 * closes the gap, so shortfall is logged only on the transition into and
	 * out of it rather than once per resize call.  A steady shortfall would
	 * otherwise log at whatever rate the caller resizes, and a caller
	 * re-asserting the same target every few seconds is exactly the
	 * fixed-grant-for-lifetime policy this module is meant to support (see
	 * the policy-seam comment in svs_cpu_slots.h).
	 */
	bool		inShortfall;
};

static volatile sig_atomic_t SvsParkedSlotGotSigterm = false;

static void EnsureCapacity(SvsSlotSet *set, int needed);
static void ReapDeadSlots(SvsSlotSet *set);
static bool WaitForSlotShutdownBounded(BackgroundWorkerHandle *handle, long timeoutMs);
static void LogShortfallTransition(SvsSlotSet *set, int target);
static int32 AllocateSlotIndex(SvsSlotSet *set);

SvsSlotSet *
SvsSlotSetCreate(MemoryContext ctx, const char *libraryName,
				  const char *datname)
{
	MemoryContext oldCtx = MemoryContextSwitchTo(ctx);
	SvsSlotSet *set = palloc0(sizeof(SvsSlotSet));

	set->ctx = ctx;
	strlcpy(set->libraryName, libraryName, sizeof(set->libraryName));
	strlcpy(set->datname, datname, sizeof(set->datname));
	set->entries = NULL;
	set->capacity = 0;
	set->count = 0;
	set->inShortfall = false;

	MemoryContextSwitchTo(oldCtx);
	return set;
}

int
SvsSlotSetResize(SvsSlotSet *set, int target)
{
	if (target < 0)
		target = 0;

	ReapDeadSlots(set);

	/*
	 * Shrink first: terminate most-recently-registered first, so a caller
	 * that oscillates the target by one or two does not churn the whole
	 * set's registration order on every call.
	 */
	while (set->count > target)
	{
		SvsSlotEntry *entry = &set->entries[set->count - 1];

		TerminateBackgroundWorker(entry->handle);

		if (!WaitForSlotShutdownBounded(entry->handle, SVS_SLOT_SHUTDOWN_TIMEOUT_MS))
			ereport(WARNING,
					(errmsg("svs cpu slots: timed out waiting for a %s slot to shut down after termination",
							SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH))));

		pfree(entry->handle);
		set->count--;
	}

	while (set->count < target)
	{
		BackgroundWorker bgw;
		BackgroundWorkerHandle *handle;
		SvsParkedSlotArg arg;
		pid_t		pid;
		BgwHandleStatus status;

		EnsureCapacity(set, set->count + 1);

		memset(&bgw, 0, sizeof(bgw));
		snprintf(bgw.bgw_name, BGW_MAXLEN, "%s", SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH));
		snprintf(bgw.bgw_type, BGW_MAXLEN, "%s", SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH));
		snprintf(bgw.bgw_library_name, BGW_MAXLEN, "%s", set->libraryName);
		snprintf(bgw.bgw_function_name, BGW_MAXLEN, "SvsParkedSlotMain");

		/*
		 * BGWORKER_CLASS_PARALLEL is the whole point of this module: without
		 * it, registration is checked against max_worker_processes instead
		 * of max_parallel_workers, and the pool model silently binds the
		 * wrong ceiling.  No BGWORKER_BACKEND_DATABASE_CONNECTION: a parked
		 * slot touches no database, and omitting the flag skips the whole
		 * InitPostgres path.
		 */
		bgw.bgw_flags = BGWORKER_SHMEM_ACCESS | BGWORKER_CLASS_PARALLEL;
		bgw.bgw_start_time = BgWorkerStart_ConsistentState;

		/*
		 * Required: SanityCheckBackgroundWorker rejects any other restart
		 * interval for a BGWORKER_CLASS_PARALLEL worker.
		 */
		bgw.bgw_restart_time = BGW_NEVER_RESTART;
		bgw.bgw_main_arg = (Datum) 0;
		bgw.bgw_notify_pid = MyProcPid;

		memset(&arg, 0, sizeof(arg));
		arg.slotIndex = AllocateSlotIndex(set);
		arg.slotTotal = target;
		arg.reserved = target;
		strlcpy(arg.datname, set->datname, sizeof(arg.datname));
		StaticAssertStmt(sizeof(SvsParkedSlotArg) <= BGW_EXTRALEN,
						  "SvsParkedSlotArg must fit in bgw_extra");
		memcpy(bgw.bgw_extra, &arg, sizeof(arg));

		{
			/*
			 * RegisterDynamicBackgroundWorker() palloc's the handle in
			 * whatever context is current when it is called, not in any
			 * context of its own choosing.  This set's handles must survive
			 * past the end of the calling statement (that persistence is
			 * this whole module's reason to exist), so the handle has to
			 * land in set->ctx, not in a per-statement context that gets
			 * reset once this call returns; the same reasoning is why
			 * RegisterDatabaseWorker() in vamanalauncher.c switches to
			 * TopMemoryContext before its own registration call.
			 */
			MemoryContext handleCtx = MemoryContextSwitchTo(set->ctx);
			bool		registered = RegisterDynamicBackgroundWorker(&bgw, &handle);

			MemoryContextSwitchTo(handleCtx);
			if (!registered)
				break;			/* pool or slot array exhausted */
		}

		status = WaitForBackgroundWorkerStartup(handle, &pid);
		if (status != BGWH_STARTED)
		{
			/* Registered but never actually started; do not count it. */
			pfree(handle);
			break;
		}

		set->entries[set->count].handle = handle;
		set->entries[set->count].slotIndex = arg.slotIndex;
		set->count++;
	}

	LogShortfallTransition(set, target);

	return set->count;
}

void
SvsSlotSetReleaseAll(SvsSlotSet *set)
{
	SvsSlotSetResize(set, 0);
}

int
SvsSlotSetCount(SvsSlotSet *set)
{
	ReapDeadSlots(set);
	return set->count;
}

static void
EnsureCapacity(SvsSlotSet *set, int needed)
{
	int			newCapacity;
	MemoryContext oldCtx;

	if (needed <= set->capacity)
		return;

	newCapacity = Max(needed, Max(set->capacity * 2, 8));
	oldCtx = MemoryContextSwitchTo(set->ctx);
	if (set->entries == NULL)
		set->entries = palloc(sizeof(SvsSlotEntry) * newCapacity);
	else
		set->entries = repalloc(set->entries, sizeof(SvsSlotEntry) * newCapacity);
	MemoryContextSwitchTo(oldCtx);
	set->capacity = newCapacity;
}

/*
 * Remove any entry whose handle has already stopped, on its own or via a
 * termination whose bounded wait expired before this call.  Slides the
 * remaining entries down rather than swapping with the tail, so
 * "most-recently-registered" stays well defined for the shrink order in
 * SvsSlotSetResize even when a slot exits out of turn.
 */
static void
ReapDeadSlots(SvsSlotSet *set)
{
	int			i = 0;

	while (i < set->count)
	{
		pid_t		pid;
		BgwHandleStatus status = GetBackgroundWorkerPid(set->entries[i].handle, &pid);

		if (status == BGWH_STOPPED || status == BGWH_POSTMASTER_DIED)
		{
			pfree(set->entries[i].handle);
			memmove(&set->entries[i], &set->entries[i + 1],
					(set->count - i - 1) * sizeof(SvsSlotEntry));
			set->count--;
			/* re-check the entry that just slid into position i */
		}
		else
		{
			i++;
		}
	}
}

/*
 * The smallest positive index not already held by a live entry.  Every live
 * slot's self-reported "X/Y" label must be unique among current holders and
 * stay within 1..slotTotal, so the index a new slot gets can be neither a
 * number already in use by a still-running survivor nor a value drawn from
 * an ever-increasing source that would eventually exceed the total.  Callers
 * always run ReapDeadSlots() first, so set->entries here holds only slots
 * actually believed live right now.
 *
 * O(count^2) across a full resize, which is fine: count is bounded by
 * max_parallel_workers, at most a few hundred even in an extreme
 * configuration.
 */
static int32
AllocateSlotIndex(SvsSlotSet *set)
{
	int32		candidate;

	for (candidate = 1; candidate <= set->count + 1; candidate++)
	{
		bool		inUse = false;
		int			i;

		for (i = 0; i < set->count; i++)
		{
			if (set->entries[i].slotIndex == candidate)
			{
				inUse = true;
				break;
			}
		}
		if (!inUse)
			return candidate;
	}

	pg_unreachable();
}

/*
 * Bounded stand-in for core's WaitForBackgroundWorkerShutdown(), which has no
 * timeout at all.  Polls in short intervals rather than blocking on the
 * final wait so a slot that never exits cannot hang the caller indefinitely.
 */
static bool
WaitForSlotShutdownBounded(BackgroundWorkerHandle *handle, long timeoutMs)
{
	TimestampTz startTime = GetCurrentTimestamp();

	for (;;)
	{
		pid_t		pid;
		BgwHandleStatus status = GetBackgroundWorkerPid(handle, &pid);
		long		elapsedMs;
		long		remainingMs;
		int			rc;

		if (status == BGWH_STOPPED)
			return true;
		if (status == BGWH_POSTMASTER_DIED)
			return false;

		CHECK_FOR_INTERRUPTS();

		elapsedMs = TimestampDifferenceMilliseconds(startTime, GetCurrentTimestamp());
		remainingMs = timeoutMs - elapsedMs;
		if (remainingMs <= 0)
			return false;

		rc = WaitLatch(MyLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   Min(remainingMs, SVS_SLOT_SHUTDOWN_POLL_MS),
					   PG_WAIT_EXTENSION);

		if (rc & WL_POSTMASTER_DEATH)
			return false;
		if (rc & WL_LATCH_SET)
			ResetLatch(MyLatch);
	}
}

/*
 * Log on transition into or out of shortfall only, not once per resize:
 * a caller re-asserting the same target repeatedly (the "hold for a grant's
 * lifetime" policy) must not turn a steady, already-reported shortfall into
 * a disk-fill vector.
 *
 * RegisterDynamicBackgroundWorker() gives no reason code for its failure, so
 * this deliberately reports only what is known for certain (how many slots
 * are held versus requested), not a guess at which limit is binding: the
 * held count alone already makes a max_parallel_workers shortfall and a
 * max_worker_processes shortfall distinguishable in the log, without risking
 * a wrong causal claim the caller cannot independently verify.
 */
static void
LogShortfallTransition(SvsSlotSet *set, int target)
{
	bool		nowShort = (set->count < target);

	if (nowShort && !set->inShortfall)
	{
		ereport(LOG,
				(errmsg("svs cpu slots: holding %d of %d requested %s slots for database \"%s\"",
						set->count, target, SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH), set->datname)));
	}
	else if (!nowShort && set->inShortfall)
	{
		ereport(LOG,
				(errmsg("svs cpu slots: shortfall cleared, holding %d of %d requested %s slots for database \"%s\"",
						set->count, target, SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH), set->datname)));
	}

	set->inShortfall = nowShort;
}

/* -----------------------------------------------------------------------
 * Parked worker entry point
 * ----------------------------------------------------------------------- */

static void
SvsParkedSlotSigterm(SIGNAL_ARGS)
{
	int			save_errno = errno;

	/*
	 * Flag-and-latch only, no die(): a parked slot has nothing to unwind
	 * (no transaction, no database connection, no lock to release beyond
	 * what proc_exit already handles), so there is no drain to interrupt
	 * with a catchable cancel.  A plain flag lets the main loop reach a
	 * clean proc_exit(0) on its own, which keeps the server log quiet
	 * across the repeated register/terminate cycles this module exists to
	 * survive; a FATAL from die() would log one line per cycle instead.
	 */
	SvsParkedSlotGotSigterm = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

void
SvsParkedSlotMain(Datum main_arg)
{
	SvsParkedSlotArg arg;
	char		appName[NAMEDATALEN + 64];
	uint32		waitEventSearchSlot;

	memcpy(&arg, MyBgworkerEntry->bgw_extra, sizeof(arg));

	pqsignal(SIGTERM, SvsParkedSlotSigterm);
	BackgroundWorkerUnblockSignals();

	/*
	 * No BackgroundWorkerInitializeConnection call: this worker was
	 * registered without BGWORKER_BACKEND_DATABASE_CONNECTION, so it has no
	 * database to connect to and none of the transaction machinery that
	 * would require.
	 *
	 * That also means InitPostgres never runs, and pgstat_beinit()/
	 * pgstat_bestart*() are normally only called from there (or from
	 * AuxiliaryProcessMainCommon() for built-in auxiliary processes).
	 * Without them this worker would be invisible in pg_stat_activity and
	 * pgstat_report_appname() below would silently do nothing, which defeats
	 * the whole point of a fiction worker that exists to be counted and
	 * observed.  Establish backend status the same way
	 * AuxiliaryProcessMainCommon() does for an aux process with no database
	 * connection.  The final bestart step calls GetSessionUserId() for any
	 * B_BG_WORKER, which asserts a valid SessionUserId that InitPostgres
	 * would normally have set; InitializeSessionUserIdStandalone() is the
	 * documented way for a background worker to establish that identity
	 * without a database connection or catalog access (it is the same call
	 * autovacuum workers use for the same reason).
	 *
	 * PostgreSQL 18 split the single pgstat_bestart() call into
	 * pgstat_bestart_initial() (report before SessionUserId exists) and
	 * pgstat_bestart_final() (report once it does); pgstat_bestart_initial
	 * and pgstat_bestart_final do not exist before 18, where a single
	 * pgstat_bestart() call does both steps after SessionUserId is set.
	 */
	pgstat_beinit();
#if PG_VERSION_NUM >= 180000
	pgstat_bestart_initial();
	InitializeSessionUserIdStandalone();
	pgstat_bestart_final();
#else
	InitializeSessionUserIdStandalone();
	pgstat_bestart();
#endif

	/*
	 * InitProcess() (already run before this function, from
	 * BackgroundWorkerMain()) allocates MyProc but does not make it visible
	 * in the shared ProcArray; that step, InitProcessPhase2(), is normally
	 * only reached via InitPostgres(), which this worker never calls.
	 * Without it, BackendPidGetProc() cannot find this process by pid, and
	 * pg_stat_activity's wait_event/wait_event_type columns (which are read
	 * from the PGPROC that lookup returns) stay NULL no matter what this
	 * worker reports through WaitLatch below.  InitProcessPhase2() needs
	 * nothing a database connection would have provided and registers its
	 * own ProcArray removal on exit, so it is safe to call directly here.
	 */
	InitProcessPhase2();

	SvsFormatSearchSlotAppName(appName, sizeof(appName), arg.datname,
							   arg.slotIndex, arg.slotTotal, arg.reserved);
	pgstat_report_appname(appName);

	/*
	 * WaitEventExtensionNew() dedupes by name through a shared hash, so every
	 * parked slot across every backend registering "VamanaSearchSlot" gets
	 * back the same id with no coordination needed; each process still only
	 * calls it the once, here, before entering its park loop.
	 */
	waitEventSearchSlot = WaitEventExtensionNew("VamanaSearchSlot");

	for (;;)
	{
		int			rc;

		CHECK_FOR_INTERRUPTS();

		if (SvsParkedSlotGotSigterm)
			break;

		rc = WaitLatch(MyLatch, WL_LATCH_SET | WL_EXIT_ON_PM_DEATH, -1,
						waitEventSearchSlot);
		if (rc & WL_LATCH_SET)
			ResetLatch(MyLatch);
	}

	/*
	 * Clean exit only.  Exit status 0 or 1 is not a crash; any other status
	 * makes the postmaster SIGQUIT every process in the cluster and run
	 * crash recovery.  Never abort(), never let an uncaught ereport(ERROR)
	 * escape this function.
	 */
	proc_exit(0);
}
