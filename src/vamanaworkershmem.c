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

#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/itemptr.h"
#include "storage/lwlock.h"
#include "storage/lmgr.h"
#include "storage/shmem.h"
#include "utils/errcodes.h"

/* -----------------------------------------------------------------------
 * Module-level state
 * ----------------------------------------------------------------------- */

/* The per-database control-block array (all processes) */
VamanaWorkerShmemHeader *VamanaWorkerShmemHeaderPtr = NULL;

/*
 * Convenience pointer to this worker's control block.  Until the launcher
 * (M4) assigns entries per database, the single worker uses entry 0.
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
 * `VamanaWorkerShmemPtr->slots` points at its start.
 * ----------------------------------------------------------------------- */

/*
 * Byte offset from the start of the slot region to its variable-length
 * data area.
 */
static inline size_t
VamanaWorkerVarDataOffset(void)
{
	return (size_t) VamanaWorkerShmemPtr->maxSlots * sizeof(VamanaWorkerSlot);
}

float *
VamanaWorkerSlotQueryVec(int slotIdx)
{
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) slotIdx * VAMANA_MAX_DIM * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr->slots + offset);
}

ItemPointer
VamanaWorkerSlotResults(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData);

	return (ItemPointer) ((char *) VamanaWorkerShmemPtr->slots + offset);
}

float *
VamanaWorkerSlotDistances(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) maxSlots * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr->slots + offset);
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
static void
VamanaWorkerInitSlot(VamanaWorkerShmem *entry, char *slotRegion)
{
	entry->dbOid = InvalidOid;
	entry->workerPid = 0;
	entry->maxSlots = MaxBackends;
	entry->slots = (VamanaWorkerSlot *) slotRegion;

	InitSharedLatch(&entry->workerLatch);

	for (int i = 0; i < MaxBackends; i++)
	{
		VamanaWorkerSlot *slot = &entry->slots[i];

		pg_atomic_init_u32(&slot->status, VAMANA_SLOT_EMPTY);
		InitSharedLatch(&slot->latch);
	}

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
		pg_atomic_init_u32(&entry->reloadRequests[i].relid, 0);

	pg_atomic_init_u32(&entry->reload_all, 0);
	pg_atomic_init_u64(&entry->heartbeat_ts, 0);
	pg_atomic_init_u32(&entry->indexCount, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &entry->indexLocks[i];

		pg_atomic_init_u32(&ls->relid, 0);
		LWLockInitialize(&ls->lock, VamanaIndexLockTranche);
	}
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

	/* Single-worker model: bind the convenience pointer to entry 0. */
	VamanaWorkerShmemPtr = &VamanaWorkerShmemHeaderPtr->slots[0];

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
 * The "not found" result is the state M12's CREATE INDEX check treats as
 * "this database is not enabled for vamana."
 */
VamanaWorkerShmem *
VamanaWorkerLookupSlot(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_SHARED);
	entry = VamanaWorkerFindSlot(dbOid);
	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return entry;
}

/*
 * Reserve (or return the existing) control block for dbOid.  Returns NULL
 * when the array is full (more distinct databases than max_vamana_databases).
 * The reserved entry has workerPid == 0 until a worker starts for it.
 */
VamanaWorkerShmem *
VamanaWorkerReserveSlot(Oid dbOid)
{
	VamanaWorkerShmem *entry;

	Assert(OidIsValid(dbOid));

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);

	entry = VamanaWorkerFindSlot(dbOid);
	if (entry == NULL)
	{
		entry = VamanaWorkerFindSlot(InvalidOid);
		if (entry != NULL)
		{
			entry->dbOid = dbOid;
			VamanaWorkerShmemHeaderPtr->numActive++;
		}
	}

	LWLockRelease(VamanaWorkerShmemHeaderPtr->lock);

	return entry;
}

/*
 * Adjust the live-index counter for dbOid.  Looking up the slot takes the
 * array-wide lock in shared mode; the increment/decrement itself is a plain
 * atomic, deliberately outside that lock (see M2 "Locking").  No-op if no
 * slot is reserved for the database.
 */
void
VamanaWorkerIndexCountAdjust(Oid dbOid, int delta)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);

	if (entry == NULL)
		return;

	if (delta >= 0)
		pg_atomic_fetch_add_u32(&entry->indexCount, (uint32) delta);
	else
		pg_atomic_fetch_sub_u32(&entry->indexCount, (uint32) (-delta));
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

	LWLockAcquire(VamanaWorkerShmemHeaderPtr->lock, LW_EXCLUSIVE);

	entry = VamanaWorkerFindSlot(dbOid);
	if (entry != NULL)
	{
		entry->dbOid = InvalidOid;
		entry->workerPid = 0;
		VamanaWorkerShmemHeaderPtr->numActive--;
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

void
VamanaWorkerRegister(void)
{
	BackgroundWorker bgw;

	memset(&bgw, 0, sizeof(bgw));
	snprintf(bgw.bgw_name, BGW_MAXLEN, "vamana background worker");
	snprintf(bgw.bgw_type, BGW_MAXLEN, "vamana background worker");
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "svs");
	snprintf(bgw.bgw_function_name, BGW_MAXLEN, "VamanaWorkerMain");
	bgw.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;

	/*
	 * ConsistentState, not RecoveryFinished: the worker must run on a hot
	 * standby to drain the replication slot into the in-memory index.
	 * RecoveryFinished never fires on a node that stays in recovery.
	 */
	bgw.bgw_start_time = BgWorkerStart_ConsistentState;
	bgw.bgw_restart_time = vamana_worker_restart_time;
	bgw.bgw_main_arg = (Datum) 0;
	bgw.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&bgw);
}

/* -----------------------------------------------------------------------
 * Per-index r/w lock helpers
 * ----------------------------------------------------------------------- */

/*
 * Return the LWLock for the given index OID, allocating a slot if none exists.
 * Returns NULL if the table is full (> VAMANA_MAX_INDEXES live indexes).
 *
 * Must be called from within the worker process (or shmem startup).
 */
LWLock *
VamanaGetIndexLock(Oid relid)
{
	int			free_slot = -1;

	Assert(OidIsValid(relid));

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];
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

	/* CAS 0 → relid to claim the slot */
	{
		uint32		expected = 0;

		if (!pg_atomic_compare_exchange_u32(
											&VamanaWorkerShmemPtr->indexLocks[free_slot].relid,
											&expected, (uint32) relid))
		{
			/* Lost the race; search again (recursive retry) */
			return VamanaGetIndexLock(relid);
		}
	}

	return &VamanaWorkerShmemPtr->indexLocks[free_slot].lock;
}

void
VamanaReleaseIndexLock(Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];

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
