/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkershmem.c
 *
 * Shared memory layout: sizing, initialisation, slot buffer accessors,
 * per-index LWLock helpers, and the slot error-category codec.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "vamana_subxid_pending_array.h"

#include "access/xact.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/itemptr.h"
#include "storage/lwlock.h"
#include "storage/lmgr.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "storage/shmem.h"
#include "utils/errcodes.h"
#include "utils/injection_point.h"
#include "utils/memutils.h"

/* -----------------------------------------------------------------------
 * Module-level state
 * ----------------------------------------------------------------------- */

/* The per-database control-block array (all processes) */
static VamanaWorkerShmemHeader *VamanaWorkerShmemHeaderPtr = NULL;

/* NULL means svs was loaded without shared_preload_libraries. */
static inline void
VamanaWorkerRequireShmemInitialized(void)
{
	if (unlikely(VamanaWorkerShmemHeaderPtr == NULL))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("vamana shared worker state is not initialized"),
				 errhint("Ensure vamana is in shared_preload_libraries and the server was restarted.")));
}

/*
 * Convenience pointer to this worker's control block.  Until the launcher
 * assigns entries per database, the single worker uses entry 0.
 */
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;

/* Named LWLock tranche backing the array-wide reservation lock. */
static const char *const VamanaWorkerHeaderLockName = "vamana_worker_header";

/* Hook chains (set by VamanaWorkerInstallHooks, used by hook functions) */
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif

/* LWLock tranche for per-index r/w locks — co-located with its initializer */
static int	VamanaIndexLockTranche = -1;
static const char *const VamanaIndexLockTrancheName = "vamana_index_rwlock";

/* -----------------------------------------------------------------------
 * Shared memory accessors
 *
 * The slot region is a separate shared-memory allocation (see "Shared
 * memory sizing and initialisation" below), laid out as:
 *   [slots[maxSlots]] [queryVecs[maxSlots][MAX_DIM]] [results[...]] [dists[...]]
 * `entry->slots` points at its start.  The accessors take the per-database
 * control block explicitly: a backend resolves it via VamanaWorkerLookupSlot,
 * the worker passes its own process-local VamanaWorkerShmemPtr.
 * ----------------------------------------------------------------------- */

/*
 * Byte offset from the start of a database's slot region to its
 * variable-length data area.
 */
static inline size_t
VamanaWorkerVarDataOffset(const VamanaWorkerShmem *entry)
{
	return (size_t) entry->maxSlots * sizeof(VamanaWorkerSlot);
}

float *
VamanaWorkerSlotQueryVec(VamanaWorkerShmem *entry, int slotIdx)
{
	size_t		offset = VamanaWorkerVarDataOffset(entry) +
		(size_t) slotIdx * VAMANA_MAX_DIM * sizeof(float);

	return (float *) ((char *) entry->slots + offset);
}

ItemPointer
VamanaWorkerSlotResults(VamanaWorkerShmem *entry, int slotIdx)
{
	int			maxSlots = entry->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset(entry) +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData);

	return (ItemPointer) ((char *) entry->slots + offset);
}

float *
VamanaWorkerSlotDistances(VamanaWorkerShmem *entry, int slotIdx)
{
	int			maxSlots = entry->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset(entry) +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) maxSlots * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(float);

	return (float *) ((char *) entry->slots + offset);
}

/* -----------------------------------------------------------------------
 * Shared memory sizing and initialisation
 *
 * Two independently allocated regions, following the same pattern PG core
 * uses for PGPROC's fast-path lock arrays: a fixed-size control block, and
 * a separate flat region for the data that scales with MaxBackends. A
 * struct cannot embed a member that is itself variable-length, so the
 * per-backend slots and their query-vector/result/distance buffers cannot
 * live inside VamanaWorkerShmem.
 * ----------------------------------------------------------------------- */

/*
 * Size of one database's flat backend-IPC region: the VamanaWorkerSlot
 * array followed by its query-vector, result-TID, and distance buffers,
 * each scaled by MaxBackends.
 */
static Size
VamanaWorkerSlotRegionSize(void)
{
	Size		perSlotVar;

	perSlotVar = add_size(
						  mul_size(VAMANA_MAX_DIM, sizeof(float)),	/* query vec */
						  add_size(
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(ItemPointerData)), /* TIDs */
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(float)))); /* dists */

	return add_size(mul_size(MaxBackends, sizeof(VamanaWorkerSlot)),
					mul_size(MaxBackends, perSlotVar));
}

/* Size of the control-block array: header plus max_vamana_databases entries. */
static Size
VamanaWorkerHeaderSize(void)
{
	return add_size(offsetof(VamanaWorkerShmemHeader, slots),
					mul_size(max_vamana_databases, sizeof(VamanaWorkerShmem)));
}

Size
VamanaWorkerShmemSize(void)
{
	return add_size(VamanaWorkerHeaderSize(),
					mul_size(max_vamana_databases, VamanaWorkerSlotRegionSize()));
}

/*
 * VamanaWorkerShmemStartup: shmem_startup_hook.
 *
 * Called from the postmaster (not the worker) when shared memory is
 * initialised.  We must call InitSharedLatch() here for every latch that
 * lives in shared memory; failing to do so causes undefined behavior on
 * first WaitLatch/SetLatch.
 */
/*
 * Per-tenant baseline, shared by VamanaWorkerInitSlot and
 * VamanaWorkerReleaseSlot so a recycled slot can't inherit the previous
 * tenant's counters, reload queue, or index-lock reservations.  Excludes
 * dbOid and the one-time atomic/latch construction, done only in InitSlot.
 */
static void
VamanaWorkerResetEntryState(VamanaWorkerShmem *entry)
{
	entry->workerPid = 0;
	entry->backoff.last_attempt_time = 0;
	entry->backoff.consecutive_failures = 0;

	pg_atomic_write_u32(&entry->accepting, 0);
	pg_atomic_write_u32(&entry->evict_all, 0);
	pg_atomic_write_u64(&entry->heartbeat_ts, 0);
	pg_atomic_write_u32(&entry->indexCount, 0);
	pg_atomic_write_u32(&entry->desiredSearchThreads, 0);
	pg_atomic_write_u32(&entry->grantedSearchThreads, 0);
	pg_atomic_write_u32(&entry->reservedSearchThreads, 0);

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
		pg_atomic_write_u32(&entry->reloadRequests[i].relid, 0);

	for (int i = 0; i < SVS_MAX_PENDING_BUILDS; i++)
		pg_atomic_write_u32(&entry->buildRequests[i].pid, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		pg_atomic_write_u32(&entry->indexLocks[i].relid, 0);

	for (int i = 0; i < entry->maxSlots; i++)
		pg_atomic_write_u32(&entry->slots[i].status, VAMANA_SLOT_EMPTY);
}

static void
VamanaWorkerInitSlot(VamanaWorkerShmem *entry, char *slotRegion)
{
	entry->dbOid = InvalidOid;
	entry->maxSlots = MaxBackends;
	entry->slots = (VamanaWorkerSlot *) slotRegion;

	InitSharedLatch(&entry->workerLatch);

	pg_atomic_init_u32(&entry->accepting, 0);
	for (int i = 0; i < MaxBackends; i++)
	{
		VamanaWorkerSlot *slot = &entry->slots[i];

		pg_atomic_init_u32(&slot->status, VAMANA_SLOT_EMPTY);
		InitSharedLatch(&slot->latch);
	}

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
		pg_atomic_init_u32(&entry->reloadRequests[i].relid, 0);

	for (int i = 0; i < SVS_MAX_PENDING_BUILDS; i++)
	{
		SvsBuildRequest *req = &entry->buildRequests[i];

		pg_atomic_init_u32(&req->pid, 0);
		pg_atomic_init_u32(&req->status, SVS_BUILD_REQUEST_PENDING);
	}

	pg_atomic_init_u32(&entry->evict_all, 0);
	pg_atomic_init_u64(&entry->heartbeat_ts, 0);
	pg_atomic_init_u32(&entry->indexCount, 0);
	pg_atomic_init_u32(&entry->desiredSearchThreads, 0);
	pg_atomic_init_u32(&entry->grantedSearchThreads, 0);
	pg_atomic_init_u32(&entry->reservedSearchThreads, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &entry->indexLocks[i];

		pg_atomic_init_u32(&ls->relid, 0);
		LWLockInitialize(&ls->lock, VamanaIndexLockTranche);
	}

	/* Atomics are now constructed; set their logical baseline values. */
	VamanaWorkerResetEntryState(entry);
}

void
VamanaWorkerShmemStartup(void)
{
	bool		found;
	bool		slotsFound;
	char	   *slotRegionBase;
	Size		slotRegionStride = VamanaWorkerSlotRegionSize();

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	/*
	 * The per-index r/w lock tranche is process-local state (a tranche id
	 * plus a registered name), so it must be (re)established in every
	 * process that attaches, whether or not it created the segment.
	 */
	VamanaIndexLockTranche = LWLockNewTrancheId();
	LWLockRegisterTranche(VamanaIndexLockTranche, VamanaIndexLockTrancheName);

	VamanaWorkerShmemHeaderPtr = ShmemInitStruct("VamanaWorkerShmemHeader",
												 VamanaWorkerHeaderSize(), &found);

	slotRegionBase = ShmemInitStruct("VamanaWorkerSlots",
									 mul_size(max_vamana_databases, slotRegionStride),
									 &slotsFound);
	Assert(found == slotsFound);

	if (!found)
	{
		memset(VamanaWorkerShmemHeaderPtr, 0, VamanaWorkerHeaderSize());
		memset(slotRegionBase, 0,
			   mul_size(max_vamana_databases, slotRegionStride));

		VamanaWorkerShmemHeaderPtr->lock =
			&(GetNamedLWLockTranche(VamanaWorkerHeaderLockName))->lock;
		VamanaWorkerShmemHeaderPtr->numSlots = max_vamana_databases;
		VamanaWorkerShmemHeaderPtr->numActive = 0;

		for (int db = 0; db < max_vamana_databases; db++)
			VamanaWorkerInitSlot(&VamanaWorkerShmemHeaderPtr->slots[db],
								 slotRegionBase + (Size) db * slotRegionStride);
	}
	else
	{
		/* Clear stale latch ownership from a previous worker instance. */
		for (int db = 0; db < VamanaWorkerShmemHeaderPtr->numSlots; db++)
			InitSharedLatch(&VamanaWorkerShmemHeaderPtr->slots[db].workerLatch);
	}

	LWLockRelease(AddinShmemInitLock);
}

/* -----------------------------------------------------------------------
 * Per-database control-block lookup and reservation
 *
 * The array is fixed-size and never reallocated, so a returned entry
 * pointer is stable for the postmaster's lifetime.  Lookups take the
 * array-wide lock in shared mode; reservation and release take it in
 * exclusive mode because they change dbOid and numActive.
 * ----------------------------------------------------------------------- */

static VamanaWorkerShmem *
VamanaWorkerFindSlot(Oid dbOid)
{
	for (int i = 0; i < VamanaWorkerShmemHeaderPtr->numSlots; i++)
	{
		VamanaWorkerShmem *entry = &VamanaWorkerShmemHeaderPtr->slots[i];

		if (entry->dbOid == dbOid)
			return entry;
	}
	return NULL;
}

/*
 * Return the control block serving dbOid, or NULL if none is reserved.
 * The "not found" result is the state the CREATE INDEX check treats as
 * "this database is not enabled for vamana."
 */
VamanaWorkerShmem *
VamanaWorkerLookupSlot(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	entry = VamanaWorkerFindSlot(dbOid);
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return entry;
}

/*
 * Invoke cb on every reserved (dbOid != InvalidOid) control block under a
 * single LW_SHARED pass, with the header lock held across all invocations.
 *
 * The callback does its own copy-out while the lock is held, so no caller has
 * to re-lock for a second read.  Holding the lock across the whole walk keeps
 * each entry's identity — and its slots/maxSlots — stable for the callback,
 * closing the reserve/release window a two-pass design would reopen.  The
 * callback must not itself take the header lock (it is non-recursive) nor do
 * unbounded work (tuplestore, palloc storms) that would hold it too long.
 */
void
VamanaWorkerForEachReserved(VamanaReservedEntryCb cb, void *ctx)
{
	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	for (int i = 0; i < VamanaWorkerShmemHeaderPtr->numSlots; i++)
	{
		VamanaWorkerShmem *entry = &VamanaWorkerShmemHeaderPtr->slots[i];

		if (OidIsValid(entry->dbOid))
			cb(entry, ctx);
	}
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/*
 * Reserve (or return the existing) control block for dbOid.  Returns NULL
 * when the array is full (more distinct databases than max_vamana_databases).
 * The reserved entry has workerPid == 0 until a worker starts for it.
 *
 * created, if non-NULL, is set within the same locked section: true only
 * when this call allocated the entry, false if it already existed or on a
 * NULL return.
 */
VamanaWorkerShmem *
VamanaWorkerReserveSlot(Oid dbOid, bool *created)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	if (created)
		*created = false;

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);

	entry = VamanaWorkerFindSlot(dbOid);
	if (entry == NULL)
	{
		entry = VamanaWorkerFindSlot(InvalidOid);
		if (entry != NULL)
		{
			entry->dbOid = dbOid;
			VamanaWorkerShmemHeaderPtr->numActive++;
			if (created)
				*created = true;

			/*
			 * Between publishing dbOid and dropping the exclusive lock the entry
			 * is half-initialised.  A concurrent reader takes the lock in shared
			 * mode, so it can only observe the entry whole or absent — this point
			 * lets a test pause here and prove that invariant deterministically.
			 */
			INJECTION_POINT("vamana-reserve-slot-midpoint", NULL);
		}
	}

	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return entry;
}

/* -----------------------------------------------------------------------
 * Cross-process wake
 *
 * A backend's own MyLatch is just &MyProc->procLatch, a struct living in the
 * shared PGPROC array; any other backend that knows its PID can set that same
 * latch directly via BackendPidGetProc, with no change to what the target is
 * already waiting on.  This is how NOTIFY and worker-death wakes already
 * reach the launcher today; it lets a build request reach it the same way
 * without going through NOTIFY's post-commit delivery, which would never fire
 * while the requesting backend's own transaction is still open waiting on it.
 * ----------------------------------------------------------------------- */

void
SvsWakeBackend(pid_t pid)
{
	PGPROC	   *proc = BackendPidGetProc(pid);

	if (proc != NULL)
		SetLatch(&proc->procLatch);
}

void
SvsSetLauncherPid(pid_t pid)
{
	VamanaWorkerRequireShmemInitialized();
	VamanaWorkerShmemHeaderPtr->launcherPid = pid;
}

void
SvsKickLauncher(void)
{
	VamanaWorkerRequireShmemInitialized();
	SvsWakeBackend(VamanaWorkerShmemHeaderPtr->launcherPid);
}

/* -----------------------------------------------------------------------
 * Live-index counter (commit-deferred)
 *
 * indexCount must equal committed catalog truth: the BEFORE DELETE guard on
 * vamana_databases promotes it from an advisory hint into a hard gate, and an
 * aborted DROP INDEX applying its decrement inline would under-count and let
 * the DELETE through while a live index remains.  So a CREATE/DROP queues a
 * delta here and the atomic is written only at COMMIT, never on abort.
 * ----------------------------------------------------------------------- */

typedef struct PendingIndexCountDelta
{
	Oid			dbOid;
	int			delta;			/* +1 on CREATE INDEX, -1 on DROP INDEX */
	SubTransactionId subxid;
}			PendingIndexCountDelta;

/* Per-backend (per-transaction) list; reset to NULL at transaction end. */
static VamanaSubxidPendingArray * CurrentIndexCountDeltas = NULL;

static bool indexCountCallbacksRegistered = false;

static void VamanaIndexCountXactCallback(XactEvent event, void *arg);
static void VamanaIndexCountSubXactCallback(SubXactEvent event,
											SubTransactionId mySubid,
											SubTransactionId parentSubid,
											void *arg);

static VamanaSubxidPendingArray *
GetOrCreateIndexCountDeltas(void)
{
	if (CurrentIndexCountDeltas == NULL)
		CurrentIndexCountDeltas =
			VamanaSubxidPendingArrayCreate(TopTransactionContext,
									 sizeof(PendingIndexCountDelta),
									 offsetof(PendingIndexCountDelta, subxid),
									 16);
	return CurrentIndexCountDeltas;
}

static void
EnsureIndexCountCallbacksRegistered(void)
{
	if (!indexCountCallbacksRegistered)
	{
		RegisterXactCallback(VamanaIndexCountXactCallback, NULL);
		RegisterSubXactCallback(VamanaIndexCountSubXactCallback, NULL);
		indexCountCallbacksRegistered = true;
	}
}

/*
 * Queue a live-index counter delta for dbOid, applied to shmem at COMMIT.
 * Tagging the delta with the current subtransaction lets a ROLLBACK TO
 * SAVEPOINT discard only its own CREATE/DROP INDEX deltas.
 */
void
VamanaWorkerQueueIndexCountDelta(Oid dbOid, int delta)
{
	PendingIndexCountDelta *entry;

	EnsureIndexCountCallbacksRegistered();
	entry = VamanaSubxidPendingArrayAppend(GetOrCreateIndexCountDeltas());
	entry->dbOid = dbOid;
	entry->delta = delta;
}

/*
 * Apply a net delta to dbOid's counter.  Looking up the slot takes the
 * array-wide lock in shared mode; the increment/decrement itself is a plain
 * atomic, deliberately outside that lock.  No-op if no
 * slot is reserved for the database.
 */
static void
ApplyIndexCountDelta(Oid dbOid, int delta)
{
	VamanaWorkerShmem *entry;

	if (delta == 0)
		return;

	entry = VamanaWorkerLookupSlot(dbOid);
	if (entry == NULL)
		return;

	if (delta > 0)
		pg_atomic_fetch_add_u32(&entry->indexCount, (uint32) delta);
	else
		pg_atomic_fetch_sub_u32(&entry->indexCount, (uint32) (-delta));
}

/*
 * Fold the pending deltas into one net value per database and apply them,
 * so a slot is looked up at most once per database regardless of how many
 * indexes the transaction created or dropped.  Deltas from an aborted
 * subtransaction carry InvalidSubTransactionId and are skipped.
 */
static void
ApplyPendingIndexCountDeltas(void)
{
	VamanaSubxidPendingArray *list = CurrentIndexCountDeltas;

	if (list == NULL)
		return;

	for (int i = 0; i < list->count; i++)
	{
		PendingIndexCountDelta *entryI = VamanaSubxidPendingArrayEntryAt(list, i);
		Oid			dbOid = entryI->dbOid;
		int			net = 0;

		/* Skip entries already folded into an earlier pass or aborted. */
		if (dbOid == InvalidOid || entryI->subxid == InvalidSubTransactionId)
			continue;

		for (int j = i; j < list->count; j++)
		{
			PendingIndexCountDelta *entryJ = VamanaSubxidPendingArrayEntryAt(list, j);

			if (entryJ->dbOid != dbOid ||
				entryJ->subxid == InvalidSubTransactionId)
				continue;

			net += entryJ->delta;
			entryJ->dbOid = InvalidOid;
		}

		ApplyIndexCountDelta(dbOid, net);
	}
}

static void
VamanaIndexCountXactCallback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_PARALLEL_COMMIT:
			ApplyPendingIndexCountDeltas();
			CurrentIndexCountDeltas = NULL;
			break;

		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			CurrentIndexCountDeltas = NULL;
			break;

		case XACT_EVENT_PREPARE:
			if (CurrentIndexCountDeltas != NULL &&
				CurrentIndexCountDeltas->count > 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("vamana index does not support two-phase commit")));
			break;

		default:
			break;
	}
}

/*
 * A ROLLBACK TO SAVEPOINT around a CREATE/DROP INDEX must discard that
 * subtransaction's deltas.  Entries carry their subxid rather than being
 * removed on rollback, so this marks them discarded without compacting the
 * array mid-transaction.
 */
static void
VamanaIndexCountSubXactCallback(SubXactEvent event, SubTransactionId mySubid,
								SubTransactionId parentSubid, void *arg)
{
	if (CurrentIndexCountDeltas == NULL)
		return;

	if (event == SUBXACT_EVENT_ABORT_SUB)
		VamanaSubxidPendingArrayPruneAbortedSubxact(CurrentIndexCountDeltas, mySubid);
	else if (event == SUBXACT_EVENT_COMMIT_SUB)
		VamanaSubxidPendingArrayReparentSubxact(CurrentIndexCountDeltas, mySubid, parentSubid);
}

/* -----------------------------------------------------------------------
 * Launcher-owned crash-backoff state
 *
 * The backoff sub-struct is written only by the launcher, always under the
 * header lock, so it stays consistent with the slot's dbOid identity.  These
 * accessors are the storage half of the crash-backoff feature; the escalation
 * policy (when a death counts as recovery, how the interval grows) lives in the
 * launcher, which passes its decision in as the `recovered` flag.
 * ----------------------------------------------------------------------- */

/*
 * Copy dbOid's backoff counters into *out.  Returns false and zeroes *out when
 * no slot is reserved yet, so a first-ever spawn reads as "no backoff owed".
 */
bool
VamanaWorkerBackoffSnapshot(Oid dbOid, VamanaLauncherBackoff *out)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
		*out = entry->backoff;
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	if (entry == NULL)
	{
		out->last_attempt_time = 0;
		out->consecutive_failures = 0;
		return false;
	}
	return true;
}

/*
 * Lock-free backoff predicate for callers already holding the header lock.
 * True iff the worker has unrecovered crashes and is therefore in the
 * launcher's respawn-backoff regime.  Reads the count the launcher maintains
 * (VamanaWorkerBackoffRecordDeath) rather than recomputing the interval curve,
 * so it stays a fact about backoff, not a copy of its policy.
 */
bool
VamanaWorkerIsBackingOff(const VamanaWorkerShmem *entry)
{
	return entry->backoff.consecutive_failures > 0;
}

/* Record the moment the launcher (re)spawned dbOid's worker. */
void
VamanaWorkerBackoffStampAttempt(Oid dbOid, TimestampTz now)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);
	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
		entry->backoff.last_attempt_time = now;
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/*
 * Account for a worker's death: clear the failure count if the launcher judged
 * the run a recovery, otherwise advance it one step up the escalation curve.
 */
void
VamanaWorkerBackoffRecordDeath(Oid dbOid, bool recovered)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);
	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
	{
		if (recovered)
			entry->backoff.consecutive_failures = 0;
		else
			entry->backoff.consecutive_failures++;
	}
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/*
 * Reset a database's backoff to its base state after a deliberate stop.  Crash
 * throttle governs automatic respawns; an operator re-enable is a fresh intent
 * that must spawn without waiting out a window it never earned.  Clearing
 * last_attempt_time makes BackoffRemainingMs return 0 on the next reconcile.
 */
void
VamanaWorkerBackoffClear(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);
	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
	{
		entry->backoff.last_attempt_time = 0;
		entry->backoff.consecutive_failures = 0;
	}
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/*
 * Publish that the launcher has finished its startup scan and reserved a slot
 * for every enabled database.  After this, absence of a slot for a database is
 * authoritative for "not configured" (see VamanaWorkerAssertDatabase).
 */
void
VamanaWorkerSetInitialScanDone(void)
{
	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);
	VamanaWorkerShmemHeaderPtr->initialScanDone = true;
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

bool
VamanaWorkerInitialScanDone(void)
{
	bool		done;

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	done = VamanaWorkerShmemHeaderPtr->initialScanDone;
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return done;
}

/*
 * True when every slot holds a valid dbOid, so no further database can be
 * reserved without raising max_vamana_databases.  Lets callers distinguish a
 * configured-but-unreservable database (capacity) from an unconfigured one.
 */
bool
VamanaWorkerSlotsExhausted(void)
{
	bool		full;

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	full = VamanaWorkerShmemHeaderPtr->numActive >= VamanaWorkerShmemHeaderPtr->numSlots;
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return full;
}

/* Number of per-database control-block slots (svs.max_databases). */
int
VamanaWorkerSlotCapacity(void)
{
	VamanaWorkerRequireShmemInitialized();

	return VamanaWorkerShmemHeaderPtr->numSlots;
}

/*
 * Release the control block for dbOid, returning it to the free pool.  The
 * caller is responsible for ensuring no worker is running against it.
 */
void
VamanaWorkerReleaseSlot(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);

	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
	{
		entry->dbOid = InvalidOid;
		VamanaWorkerResetEntryState(entry);
		VamanaWorkerShmemHeaderPtr->numActive--;
	}

	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/*
 * Clear a dead worker's liveness bookkeeping so a fast respawn does not
 * mistake it for still live. Callers must have independent proof the worker
 * is gone (e.g. GetBackgroundWorkerPid() == BGWH_STOPPED); a worker that is
 * merely stuck must be left for VamanaWorkerEntryIsLive's heartbeat check to
 * catch instead. Backoff counters, index locks, and queued reloads are left
 * untouched for the replacement to inherit.
 */
void
VamanaWorkerClearDeadEntry(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	VamanaWorkerRequireShmemInitialized();

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);

	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
	{
		entry->workerPid = 0;
		pg_atomic_write_u64(&entry->heartbeat_ts, 0);
	}

	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);
}

/* -----------------------------------------------------------------------
 * Worker registration
 * ----------------------------------------------------------------------- */

#if PG_VERSION_NUM >= 150000
static void VamanaWorkerShmemRequest(void);
#endif

/*
 * VamanaWorkerInstallHooks: install shmem sizing and startup hooks.
 *
 * Must be called from _PG_init() while process_shared_preload_libraries_in_progress
 * is true.  In PG 15+, RequestAddinShmemSpace() must be called from
 * shmem_request_hook rather than directly.
 */
void
VamanaWorkerInstallHooks(void)
{
#if PG_VERSION_NUM >= 150000
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = VamanaWorkerShmemRequest;
#else
	RequestAddinShmemSpace(VamanaWorkerShmemSize());
	RequestNamedLWLockTranche(VamanaWorkerHeaderLockName, 1);
#endif

	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = VamanaWorkerShmemStartup;
}

#if PG_VERSION_NUM >= 150000
static void
VamanaWorkerShmemRequest(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	RequestAddinShmemSpace(VamanaWorkerShmemSize());
	RequestNamedLWLockTranche(VamanaWorkerHeaderLockName, 1);
}
#endif

/* -----------------------------------------------------------------------
 * Per-index r/w lock helpers
 * ----------------------------------------------------------------------- */

/*
 * Return the LWLock for the given index OID in the database's control block,
 * allocating a slot if none exists.  Returns NULL if the table is full
 * (> VAMANA_MAX_INDEXES live indexes).
 */
LWLock *
VamanaGetIndexLock(VamanaWorkerShmem *entry, Oid relid)
{
	Assert(OidIsValid(relid));

	for (;;)
	{
		int			free_slot = -1;
		uint32		expected;

		for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		{
			VamanaIndexLockSlot *ls = &entry->indexLocks[i];
			uint32		cur = pg_atomic_read_u32(&ls->relid);

			if (cur == (uint32) relid)
				return &ls->lock;

			if (cur == 0 && free_slot < 0)
				free_slot = i;
		}

		if (free_slot < 0)
		{
			ereport(WARNING,
					(errmsg("vamana worker: index lock table full (VAMANA_MAX_INDEXES=%d); "
							"cannot allocate lock for index %u",
							VAMANA_MAX_INDEXES, relid)));
			return NULL;
		}

		/* CAS 0 → relid to claim the slot; on a lost race, rescan from the top. */
		expected = 0;
		if (pg_atomic_compare_exchange_u32(&entry->indexLocks[free_slot].relid,
											&expected, (uint32) relid))
			return &entry->indexLocks[free_slot].lock;
	}
}

void
VamanaReleaseIndexLock(VamanaWorkerShmem *entry, Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &entry->indexLocks[i];

		if (pg_atomic_read_u32(&ls->relid) == (uint32) relid)
		{
			pg_atomic_write_u32(&ls->relid, 0);
			return;
		}
	}
}

/* -----------------------------------------------------------------------
 * Slot error-category codec
 *
 * The worker encodes PG errcodes into compact VAMANA_ERR_* categories that
 * fit in one byte of the slot.  The backend decodes them back on the IPC
 * return path.  Both directions live here because the codec is a property
 * of the slot's error channel, not of any individual caller.
 * ----------------------------------------------------------------------- */

uint8
VamanaCategorizeSQLState(int sqlerrcode)
{
	if (sqlerrcode == ERRCODE_OUT_OF_MEMORY)
		return VAMANA_ERR_OOM;
	if (ERRCODE_TO_CATEGORY(sqlerrcode) == ERRCODE_TO_CATEGORY(ERRCODE_DATA_EXCEPTION))
		return VAMANA_ERR_DATA;
	if (ERRCODE_TO_CATEGORY(sqlerrcode) == ERRCODE_TO_CATEGORY(ERRCODE_IO_ERROR))
		return VAMANA_ERR_IO;
	return VAMANA_ERR_INTERNAL;
}

int
VamanaSlotErrcode(uint8 category)
{
	switch (category)
	{
		case VAMANA_ERR_OOM:	return ERRCODE_OUT_OF_MEMORY;
		case VAMANA_ERR_DATA:	return ERRCODE_DATA_EXCEPTION;
		case VAMANA_ERR_IO:		return ERRCODE_IO_ERROR;
		default:				return ERRCODE_INTERNAL_ERROR;
	}
}

/*
 * Sole writer of a slot's terminal error state: message, category, then the
 * status transition that publishes both to the waiting backend.
 */
void
VamanaWorkerFailSlot(VamanaWorkerSlot *slot, const char *message, uint8 category)
{
	snprintf(slot->errorMessage, sizeof(slot->errorMessage), "%s", message);
	slot->errorCategory = category;
	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
}
