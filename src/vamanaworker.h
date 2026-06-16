/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_WORKER_H
#define VAMANA_WORKER_H

#include "postgres.h"

#include "port/atomics.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "storage/itemptr.h"

/* Forward declaration so we can use SVSIndexHandle without pulling all of svs_wrapper.h */
#ifndef SVS_WRAPPER_H
typedef void *SVSIndexHandle;
#endif

/* -----------------------------------------------------------------------
 * Slot status constants
 * ----------------------------------------------------------------------- */
#define VAMANA_SLOT_EMPTY      0
#define VAMANA_SLOT_PENDING    1
#define VAMANA_SLOT_PROCESSING 2
#define VAMANA_SLOT_DONE       3
#define VAMANA_SLOT_ERROR      4

/* -----------------------------------------------------------------------
 * Slot error category codes
 *
 * Set by the BGW in slot->errorCategory on VAMANA_SLOT_ERROR.
 * Mapped back to a PG errcode by the backend in VamanaWorkerSubmitSearch.
 * ----------------------------------------------------------------------- */
#define VAMANA_ERR_NONE         0
#define VAMANA_ERR_OOM          1	/* ERRCODE_OUT_OF_MEMORY */
#define VAMANA_ERR_DATA         2	/* ERRCODE_DATA_EXCEPTION (dim mismatch etc.) */
#define VAMANA_ERR_IO           3	/* ERRCODE_IO_ERROR */
#define VAMANA_ERR_INTERNAL     4	/* ERRCODE_INTERNAL_ERROR */

/* -----------------------------------------------------------------------
 * Slot kind: what operation this slot carries
 * ----------------------------------------------------------------------- */
#define VAMANA_SLOTKIND_SEARCH      0
#define VAMANA_SLOTKIND_INSERT      1
#define VAMANA_SLOTKIND_DELETE      2
#define VAMANA_SLOTKIND_MAINTENANCE 3	/* consolidate / compact */

/* Maintenance sub-operations (valid when slotKind == VAMANA_SLOTKIND_MAINTENANCE) */
#define VAMANA_MAINTENANCE_CONSOLIDATE 0
#define VAMANA_MAINTENANCE_COMPACT     1

/*
 * Maximum number of external IDs that fit in one delete slot submission.
 * The query-vector buffer (float[2000]) is reused to carry size_t IDs:
 * (2000 * 4) / 8 = 1000.
 */
#define VAMANA_MAX_DELETE_IDS  1000

/*
 * Maximum number of concurrent reload-OID entries that can be queued by
 * backends before the worker drains them.  If the queue is full the worker
 * latch is still kicked so no reload is silently lost.
 */
#define VAMANA_MAX_RELOAD_QUEUE  16

/*
 * Maximum number of Vamana indexes that can be live in one database.
 * Determines the size of the per-index LWLock array in shared memory.
 */
#define VAMANA_MAX_INDEXES 64

/* Heartbeat is written every ~1 s. Three missed beats means the worker is hung. */
#define VAMANA_HEARTBEAT_STALE_MS  3000

/*
 * Sentinel placed in VamanaScanOpaqueData.svsIndex when the backend is in
 * worker mode.  Non-NULL so the existing `if (so->svsIndex)` guard in
 * vamanarescan() passes, but it is never dereferenced inside the backend.
 */
#define VAMANA_WORKER_HANDLE_SENTINEL  ((SVSIndexHandle)(intptr_t)1)

/* -----------------------------------------------------------------------
 * Shared-memory structures
 * ----------------------------------------------------------------------- */

/*
 * Per-backend slot, indexed by MyBackendId - 1.
 *
 * Variable-length data (query vector, result TIDs, distances) lives in
 * three separate arrays that immediately follow the slot-header array in
 * the shared-memory region; use VamanaWorkerSlotQueryVec() etc. to access
 * them.
 */
typedef struct VamanaWorkerSlot
{
	pg_atomic_uint32 status;		/* EMPTY / PENDING / PROCESSING / DONE / ERROR */
	Oid				indexRelid;		/* index OID for this request */
	int				dimensions;		/* query vector length (SEARCH) or insert dims */
	int				k;				/* neighbors requested (SEARCH) */
	int				searchWindowSize;
	int				numResults;		/* results written by worker (SEARCH / DELETE count) */
	char			errorMessage[512]; /* set on VAMANA_SLOT_ERROR */
	uint8			errorCategory;	/* VAMANA_ERR_* set by BGW on VAMANA_SLOT_ERROR */
	Latch			latch;			/* InitSharedLatch'd; backend owns while waiting */

	/* Write-path fields (slotKind != VAMANA_SLOTKIND_SEARCH) */
	uint8			slotKind;		/* VAMANA_SLOTKIND_* */
	uint8			maintenanceOp;	/* VAMANA_MAINTENANCE_* (MAINTENANCE only) */

	/*
	 * INSERT: backend writes heap_tid here; worker writes the allocated
	 * externalId back into writeExternalId on success.
	 * DELETE: backend writes count of IDs into numResults before PENDING,
	 *         then IDs into the results buffer (reused for input).
	 */
	ItemPointerData writeHeapTid;	/* heap TID for INSERT */
	uint64			writeExternalId; /* allocated external ID returned to backend */
} VamanaWorkerSlot;

/*
 * Per-index reload request.  Backend writes the OID; worker reads and
 * clears it via compare-exchange.  relid == 0 means empty.
 */
typedef struct VamanaWorkerReloadRequest
{
	pg_atomic_uint32 relid;
} VamanaWorkerReloadRequest;

/*
 * Fixed header of the shared-memory region.
 *
 * The variable-length slot array is a FLEXIBLE_ARRAY_MEMBER; query vectors,
 * result TIDs, and distances are in three separate arrays immediately after
 * the slot array.  Use VamanaWorkerSlotQueryVec() etc. to locate them.
 */
/*
 * Per-index reader/writer lock entry.  LW_SHARED for searches; LW_EXCLUSIVE
 * for writes (INSERT, DELETE, CONSOLIDATE, COMPACT, ADOPT).  Keyed by a
 * stable slot index assigned when the BGW first loads each index.
 */
typedef struct VamanaIndexLockSlot
{
	pg_atomic_uint32 relid;			/* index OID occupying this slot, 0 = free */
	LWLock			lock;			/* the actual r/w lock */
} VamanaIndexLockSlot;

typedef struct VamanaWorkerShmem
{
	Oid				dbOid;			/* database this worker serves */

	pid_t			workerPid;
	Latch			workerLatch;	/* InitSharedLatch'd; worker owns this */

	VamanaWorkerReloadRequest reloadRequests[VAMANA_MAX_RELOAD_QUEUE];

	/*
	 * Set to 1 by a backend when reloadRequests[] is full.  The worker
	 * responds by reloading all cached indexes on its next cycle.
	 */
	pg_atomic_uint32 reload_all;

	/* Updated each BGW loop iteration; backends check for hung worker. */
	pg_atomic_uint64 heartbeat_ts;	/* TimestampTz stored as uint64 */

	int				maxSlots;

	/*
	 * Per-index r/w locks.  Up to VAMANA_MAX_INDEXES concurrent live indexes.
	 * Searches acquire LW_SHARED; all writes acquire LW_EXCLUSIVE.
	 * The BGW allocates a slot (CAS relid 0 → relid) on first access and
	 * releases it (write 0) on DROP.
	 */
	VamanaIndexLockSlot indexLocks[VAMANA_MAX_INDEXES];

	VamanaWorkerSlot slots[FLEXIBLE_ARRAY_MEMBER];
	/*
	 * After slots[maxSlots]:
	 *   float        queryVecs[maxSlots][VAMANA_MAX_DIM]
	 *   ItemPointerData results[maxSlots][VAMANA_MAX_SEARCH_WINDOW]
	 *   float        distances[maxSlots][VAMANA_MAX_SEARCH_WINDOW]
	 *
	 * Access via VamanaWorkerSlotQueryVec() / SlotResults() / SlotDistances().
	 */
} VamanaWorkerShmem;

extern int	 vamana_worker_timeout_ms;
extern int	 vamana_worker_startup_timeout_ms;
extern int	 vamana_worker_restart_time;
extern int	 vamana_max_batch_size;
extern char *vamana_worker_database;

extern VamanaWorkerShmem *VamanaWorkerShmemPtr;

Size	VamanaWorkerShmemSize(void);
void	VamanaWorkerShmemStartup(void);		/* shmem_startup_hook */
void	VamanaWorkerInstallHooks(void);		/* installs shmem hooks; called from _PG_init */
void	VamanaWorkerRegister(void);			/* called from _PG_init */

/* vamanaworkershmem.c */
LWLock *VamanaGetIndexLock(Oid relid);
uint8	VamanaCategorizeSQLState(int sqlerrcode);
int		VamanaSlotErrcode(uint8 category);

/* vamanaworkerindex.c */
SVSIndexHandle VamanaWorkerGetOrLoadIndex(Oid relid);
void	VamanaWorkerLoadAllIndexes(void);
void	VamanaWorkerResetStaleSlots(void);

/* vamanaworkersearch.c */
void	VamanaWorkerDispatchBatch(int *slotIdxs, int n);

/* vamanaworkerwrite.c */
void	VamanaWorkerProcessWriteSlot(int slotIdx);

/* Worker entry point.
 * PG 18 replaced pg_attribute_noreturn() with pg_noreturn (placed before
 * the return type, no parentheses).  PG 13–17 use pg_attribute_noreturn(). */
#if PG_VERSION_NUM >= 180000
PGDLLEXPORT pg_noreturn void VamanaWorkerMain(Datum main_arg);
#else
PGDLLEXPORT void	VamanaWorkerMain(Datum main_arg) pg_attribute_noreturn();
#endif

int		VamanaWorkerSubmitSearch(Oid indexRelid,
								 const float *queryVector,
								 int dimensions, int k, int searchWindowSize,
								 ItemPointer results, float *distances);
bool	VamanaWorkerSubmitInsert(Oid indexRelid, const float *vector,
								 int dimensions, ItemPointer heap_tid,
								 uint64 *externalId_out);
bool	VamanaWorkerSubmitDelete(Oid indexRelid,
								 const size_t *externalIds, int nIds);
bool	VamanaWorkerSubmitMaintenance(Oid indexRelid, uint8 op);
void	VamanaReleaseIndexLock(Oid relid);
void	VamanaWorkerSignalReload(Oid indexRelid);
bool	VamanaWorkerIsAvailable(void);
void	VamanaWorkerAssertDatabase(void);
void	VamanaWorkerWaitUntilAvailable(Oid indexRelid, const char *operation);

float		  *VamanaWorkerSlotQueryVec(int slotIdx);
ItemPointer	   VamanaWorkerSlotResults(int slotIdx);
float		  *VamanaWorkerSlotDistances(int slotIdx);

#endif							/* VAMANA_WORKER_H */
