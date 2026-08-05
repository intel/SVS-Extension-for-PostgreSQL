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
#define VAMANA_SLOTKIND_LOAD        4	/* load index from save dir into BGW cache */

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
 * Per-index reader/writer lock entry.  LW_SHARED for searches; LW_EXCLUSIVE
 * for writes (INSERT, DELETE, CONSOLIDATE, COMPACT, ADOPT).  Keyed by a
 * stable slot index assigned when the BGW first loads each index.
 */
typedef struct VamanaIndexLockSlot
{
	pg_atomic_uint32 relid;			/* index OID occupying this slot, 0 = free */
	LWLock			lock;			/* the actual r/w lock */
} VamanaIndexLockSlot;

/*
 * Per-database control block.
 *
 * One entry per database served by a worker, held in the fixed-size
 * VamanaWorkerShmemHeader array below.  `dbOid == InvalidOid` marks a free
 * entry; `workerPid == 0` marks an entry that is reserved (or whose worker
 * crashed) but has no live worker process.  These two states are distinct:
 * "no entry for this database" versus "entry exists, worker not up".
 *
 * The per-backend request slots, and their query-vector/result-TID/distance
 * buffers, are not embedded here: each is variable-length (scaled by
 * MaxBackends), and a struct containing one cannot itself be made fixed-size.
 * They live in a separate shared-memory allocation reached through `slots`;
 * use VamanaWorkerSlotQueryVec() etc. to locate the buffers that follow
 * slots[maxSlots] in that allocation.
 */
typedef struct VamanaWorkerShmem
{
	Oid				dbOid;			/* database this worker serves; InvalidOid = free */

	pid_t			workerPid;		/* 0 = no live worker for this entry */
	Latch			workerLatch;	/* InitSharedLatch'd; worker owns this */

	VamanaWorkerReloadRequest reloadRequests[VAMANA_MAX_RELOAD_QUEUE];

	/*
	 * Set to 1 by a backend when reloadRequests[] is full.  The worker
	 * responds by evicting all cached indexes on its next cycle; each reloads
	 * on demand.
	 */
	pg_atomic_uint32 evict_all;

	/* Updated each BGW loop iteration; backends check for hung worker. */
	pg_atomic_uint64 heartbeat_ts;	/* TimestampTz stored as uint64 */

	/*
	 * Live Vamana indexes in this database.  Maintained with plain atomics
	 * (no array-wide lock) by the backend performing CREATE/DROP INDEX; read
	 * by M10's DELETE guard and M11's pg_stat_vamana_worker view.
	 */
	pg_atomic_uint32 indexCount;

	int				maxSlots;

	/*
	 * Per-index r/w locks.  Up to VAMANA_MAX_INDEXES concurrent live indexes.
	 * Searches acquire LW_SHARED; all writes acquire LW_EXCLUSIVE.
	 * The BGW allocates a slot (CAS relid 0 → relid) on first access and
	 * releases it (write 0) on DROP.
	 */
	VamanaIndexLockSlot indexLocks[VAMANA_MAX_INDEXES];

	VamanaWorkerSlot *slots;		/* array of maxSlots entries; see above */
} VamanaWorkerShmem;

/*
 * Fixed-size array of per-database control blocks.
 *
 * Sized once at postmaster start from max_vamana_databases and never
 * reallocated, so an entry's address is stable for the postmaster's
 * lifetime.  `lock` serialises entry (de)reservation: shared mode to look
 * up an entry by dbOid, exclusive mode to claim or release one (which is
 * what changes numActive).  Per-entry hot fields (indexCount, slot status)
 * are plain atomics and do not take this lock.
 */
typedef struct VamanaWorkerShmemHeader
{
	LWLock		   *lock;			/* array-wide reservation lock */
	int				numSlots;		/* capacity == max_vamana_databases */
	int				numActive;		/* entries with a valid dbOid (under lock) */
	VamanaWorkerShmem slots[FLEXIBLE_ARRAY_MEMBER];
} VamanaWorkerShmemHeader;

extern int	 max_vamana_databases;
extern int	 vamana_worker_timeout_ms;
extern int	 vamana_worker_startup_timeout_ms;
extern int	 vamana_worker_restart_time;
extern int	 vamana_worker_restart_backoff;
extern int	 vamana_max_batch_size;
extern char *vamana_worker_database;
extern char *vamana_launcher_database;

extern VamanaWorkerShmemHeader *VamanaWorkerShmemHeaderPtr;
extern VamanaWorkerShmem *VamanaWorkerShmemPtr;

Size	VamanaWorkerShmemSize(void);
void	VamanaWorkerShmemStartup(void);		/* shmem_startup_hook */
void	VamanaWorkerInstallHooks(void);		/* installs shmem hooks; called from _PG_init */
void	VamanaWorkerRegister(void);			/* called from _PG_init */

/* vamanaworkershmem.c: per-database control-block lookup and reservation */
VamanaWorkerShmem *VamanaWorkerLookupSlot(Oid dbOid);
VamanaWorkerShmem *VamanaWorkerReserveSlot(Oid dbOid);
void	VamanaWorkerReleaseSlot(Oid dbOid);
void	VamanaWorkerIndexCountAdjust(Oid dbOid, int delta);

/* vamanaworkershmem.c */
LWLock *VamanaGetIndexLock(VamanaWorkerShmem *entry, Oid relid);
uint8	VamanaCategorizeSQLState(int sqlerrcode);
int		VamanaSlotErrcode(uint8 category);

/* vamanaworker.c */
extern bool vamana_eviction_suppressed;

/* vamanaworkerindex.c */
SVSIndexHandle VamanaWorkerGetOrLoadIndex(Oid relid, bool *loadedFromDisk);
SVSIndexHandle VamanaWorkerEnsureIndexCurrent(Oid relid);
void	VamanaWorkerResetStaleSlots(void);
void	VamanaWorkerLoadStandbyIndexes(void);
void	VamanaWorkerBootstrapStandbyReplicationSlots(void);

/* vamanaworkersearch.c */
void	VamanaWorkerDispatchBatch(int *slotIdxs, int n);

/* vamanaworkerwrite.c */
void	VamanaWorkerProcessWriteSlot(int slotIdx);
void	VamanaWorkerProcessLoadSlot(int slotIdx);

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
bool	VamanaWorkerSubmitLoad(Oid indexRelid,
							   int dimensions, int graph_degree, int alpha,
							   int search_window_size, int build_window_size,
							   int compression_type, int compression_primary,
							   int compression_secondary, int leanvec_dims,
							   int distance_type,
							   int numVectors, int tidMappingCapacity,
							   uint64 nextExternalId, int numDeleted,
							   Oid heapRelid, int vectorAttNum);
void	VamanaReleaseIndexLock(VamanaWorkerShmem *entry, Oid relid);
void	VamanaWorkerSignalReload(Oid indexRelid);
VamanaWorkerShmem *VamanaWorkerFindActiveSlot(void);
bool	VamanaWorkerIsAvailable(void);
void	VamanaWorkerAssertDatabase(void);
void	VamanaWorkerWaitUntilAvailable(Oid indexRelid, const char *operation);

float		  *VamanaWorkerSlotQueryVec(VamanaWorkerShmem *entry, int slotIdx);
ItemPointer	   VamanaWorkerSlotResults(VamanaWorkerShmem *entry, int slotIdx);
float		  *VamanaWorkerSlotDistances(VamanaWorkerShmem *entry, int slotIdx);

/*
 * Parameters for VAMANA_SLOTKIND_LOAD, packed into the queryVec buffer.
 *
 * The backend fills this before setting the slot PENDING; the BGW reads it
 * inside VamanaWorkerProcessLoadSlot to load the index from its save directory
 * without opening the index relation (which the backend holds AEL on).
 *
 * Size check: sizeof(VamanaLoadParams) must fit in float[VAMANA_MAX_DIM].
 * float[2000] = 8000 bytes; this struct is ~72 bytes — well within budget.
 */
typedef struct VamanaLoadParams
{
	int			dimensions;
	int			graph_degree;
	int			alpha;				/* int-encoded; convert with VAMANA_ALPHA_TO_FLOAT */
	int			search_window_size;
	int			build_window_size;
	int			compression_type;
	int			compression_primary;
	int			compression_secondary;
	int			leanvec_dims;
	int			distance_type;		/* cast to SVSDistanceType in the BGW */
	int			numVectors;
	int			tidMappingCapacity;
	uint64		nextExternalId;
	int			numDeleted;
	Oid			heapRelid;			/* heap relation OID (for replay decoder) */
	int			vectorAttNum;		/* 0-based heap attribute number of the vector column */
} VamanaLoadParams;

#endif							/* VAMANA_WORKER_H */
