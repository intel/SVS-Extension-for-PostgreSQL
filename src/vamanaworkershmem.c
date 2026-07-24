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

/* Pointer to the shared memory region (all processes) */
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;

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
 * Variable-length data is stored immediately after the slot-header array:
 *   [slots[maxSlots]] [queryVecs[maxSlots][MAX_DIM]] [results[...]] [dists[...]]
 * ----------------------------------------------------------------------- */

/*
 * Byte offset from the start of shmem to the beginning of the
 * variable-length data area.
 */
static inline size_t
VamanaWorkerVarDataOffset(void)
{
	return offsetof(VamanaWorkerShmem, slots) +
		(size_t) VamanaWorkerShmemPtr->maxSlots * sizeof(VamanaWorkerSlot);
}

float *
VamanaWorkerSlotQueryVec(int slotIdx)
{
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) slotIdx * VAMANA_MAX_DIM * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr + offset);
}

ItemPointer
VamanaWorkerSlotResults(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData);

	return (ItemPointer) ((char *) VamanaWorkerShmemPtr + offset);
}

float *
VamanaWorkerSlotDistances(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) maxSlots * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr + offset);
}

/* -----------------------------------------------------------------------
 * Shared memory sizing and initialisation
 * ----------------------------------------------------------------------- */

Size
VamanaWorkerShmemSize(void)
{
	Size		header;
	Size		perSlotVar;

	/*
	 * Header = fixed VamanaWorkerShmem fields + MaxBackends slot entries (via
	 * FLEXIBLE_ARRAY_MEMBER).
	 */
	header = add_size(offsetof(VamanaWorkerShmem, slots),
					  mul_size(MaxBackends, sizeof(VamanaWorkerSlot)));

	/*
	 * Variable-length data per slot: query vector + result TIDs + distances.
	 */
	perSlotVar = add_size(
						  mul_size(VAMANA_MAX_DIM, sizeof(float)),	/* query vec */
						  add_size(
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(ItemPointerData)), /* TIDs */
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(float)))); /* dists */

	return add_size(header, mul_size(MaxBackends, perSlotVar));
}

/*
 * VamanaWorkerShmemStartup: shmem_startup_hook.
 *
 * Called from the postmaster (not the worker) when shared memory is
 * initialised.  We must call InitSharedLatch() here for every latch that
 * lives in shared memory; failing to do so causes undefined behavior on
 * first WaitLatch/SetLatch.
 */
void
VamanaWorkerShmemStartup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	VamanaWorkerShmemPtr = ShmemInitStruct("VamanaWorkerShmem",
										   VamanaWorkerShmemSize(), &found);
	if (!found)
	{
		memset(VamanaWorkerShmemPtr, 0, VamanaWorkerShmemSize());
		VamanaWorkerShmemPtr->dbOid = InvalidOid;
		VamanaWorkerShmemPtr->workerPid = 0;
		VamanaWorkerShmemPtr->maxSlots = MaxBackends;

		InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);

		for (int i = 0; i < MaxBackends; i++)
		{
			VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];

			pg_atomic_init_u32(&slot->status, VAMANA_SLOT_EMPTY);
			InitSharedLatch(&slot->latch);
		}

		for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
			pg_atomic_init_u32(&VamanaWorkerShmemPtr->reloadRequests[i].relid, 0);

		pg_atomic_init_u32(&VamanaWorkerShmemPtr->reload_all, 0);
		pg_atomic_init_u64(&VamanaWorkerShmemPtr->heartbeat_ts, 0);

		/*
		 * Initialise per-index r/w lock slots.  The tranche is registered
		 * once here; the LWLockInitialize calls below bind each lock to it.
		 */
		VamanaIndexLockTranche = LWLockNewTrancheId();
		LWLockRegisterTranche(VamanaIndexLockTranche,
							  VamanaIndexLockTrancheName);
		for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		{
			VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];

			pg_atomic_init_u32(&ls->relid, 0);
			LWLockInitialize(&ls->lock, VamanaIndexLockTranche);
		}
	}
	else
	{
		VamanaIndexLockTranche = LWLockNewTrancheId();
		LWLockRegisterTranche(VamanaIndexLockTranche,
							  VamanaIndexLockTrancheName);
		/* Clear stale latch ownership from a previous worker instance. */
		InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);
	}

	LWLockRelease(AddinShmemInitLock);
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
