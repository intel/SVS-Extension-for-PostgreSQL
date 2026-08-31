/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_WORKER_H
#define VAMANA_WORKER_H

#include "postgres.h"

#include "datatype/timestamp.h"
#include "nodes/pg_list.h"
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
#define VAMANA_SLOTKIND_WARMUP      5	/* force an index resident in the BGW cache on demand */

/* Maintenance sub-operations (valid when slotKind == VAMANA_SLOTKIND_MAINTENANCE) */
#define VAMANA_MAINTENANCE_CONSOLIDATE 0
#define VAMANA_MAINTENANCE_COMPACT     1

/* -----------------------------------------------------------------------
 * Build-request status constants
 * ----------------------------------------------------------------------- */
#define SVS_BUILD_REQUEST_PENDING 0
#define SVS_BUILD_REQUEST_GRANTED 1

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

/*
 * Maximum number of concurrent build-thread requests (one per CREATE INDEX
 * in flight) a single database can have pending against the launcher at
 * once.  A request that finds no free slot fails the same way a request
 * that times out waiting for a grant does: the DDL errors out rather than
 * proceeding uncoordinated.
 */
#define SVS_MAX_PENDING_BUILDS 8

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
 * One pending build-thread request against this database, keyed by the
 * requesting backend's PID.  pid == 0 marks a free entry, claimed by a
 * backend via compare-exchange; the crash backstop reaps an entry whose pid
 * is no longer a live backend.
 *
 * requested/granted are plain fields, not atomics: the writer sets them
 * before publishing readiness through status (pg_write_barrier then
 * pg_atomic_write_u32), and a reader pairs a pg_read_barrier with its read
 * of status before trusting them -- the same protocol VamanaWorkerSlot uses.
 */
typedef struct SvsBuildRequest
{
	pg_atomic_uint32 pid;
	pg_atomic_uint32 status;	/* SVS_BUILD_REQUEST_* */
	int32			requested;	/* threads asked for */
	int32			granted;	/* threads granted; valid once status == GRANTED */
} SvsBuildRequest;

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
 * Launcher-owned crash-backoff state for one database, written only by the
 * launcher under the shmem header LWLock.  Kept in shmem, not launcher-local
 * memory, so the failure count survives a launcher restart; otherwise a
 * crash-looping database would be respawned immediately on every launcher
 * bounce.
 */
typedef struct VamanaLauncherBackoff
{
	TimestampTz	last_attempt_time;		/* when the launcher last (re)spawned */
	uint32		consecutive_failures;	/* crashes since the last recovery */
} VamanaLauncherBackoff;

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

	/* Intake gate: 1 while accepting requests, cleared with a full barrier at drain. */
	pg_atomic_uint32 accepting;

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
	 * by the DELETE guard and the pg_stat_vamana_worker view.
	 */
	pg_atomic_uint32 indexCount;

	/*
	 * CPU governance, published by the launcher's reconcile pass
	 * (SvsComputeCpuGrants).  desired is this database's unconstrained
	 * request; granted/reserved are the pool-arbitrated grant this database's
	 * worker must hold.  The worker never computes a grant, only applies one.
	 */
	pg_atomic_uint32 desiredSearchThreads;
	pg_atomic_uint32 grantedSearchThreads;
	pg_atomic_uint32 reservedSearchThreads;

	SvsBuildRequest buildRequests[SVS_MAX_PENDING_BUILDS];

	int				maxSlots;

	/* Launcher-owned; see VamanaLauncherBackoff. */
	VamanaLauncherBackoff backoff;

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

	/*
	 * Set true, once, by the launcher after it has reserved a slot for every
	 * enabled database in its startup scan.  Until then a database's absence
	 * from slots[] is indistinguishable from "scan not yet run", so callers
	 * must not treat "no slot" as authoritative for "not configured".  Reset
	 * to false only by a postmaster restart (shmem re-init), never by a
	 * launcher restart.  Guarded by lock.
	 */
	bool			initialScanDone;

	/*
	 * The launcher's current PID, published so any backend can wake it
	 * directly (SvsKickLauncher) without going through NOTIFY -- which only
	 * delivers post-commit, too late for a backend that is mid-transaction
	 * waiting on a build grant.  0 = no launcher running right now; a stale
	 * PID from a dead launcher is indistinguishable from that to a reader,
	 * since SvsWakeBackend no-ops on a PID that is no longer a live backend.
	 */
	pid_t			launcherPid;

	VamanaWorkerShmem slots[FLEXIBLE_ARRAY_MEMBER];
} VamanaWorkerShmemHeader;

extern int	 max_vamana_databases;
extern int	 vamana_worker_timeout_ms;
extern int	 vamana_worker_startup_timeout_ms;
extern int	 vamana_worker_restart_time;
extern int	 vamana_worker_restart_backoff;
extern int	 vamana_max_batch_size;
extern char *vamana_launcher_database;

extern VamanaWorkerShmem *VamanaWorkerShmemPtr;

Size	VamanaWorkerShmemSize(void);
void	VamanaWorkerShmemStartup(void);		/* shmem_startup_hook */
void	VamanaWorkerInstallHooks(void);		/* installs shmem hooks; called from _PG_init */

/* vamanaworkershmem.c: per-database control-block lookup and reservation */
VamanaWorkerShmem *VamanaWorkerLookupSlot(Oid dbOid);
VamanaWorkerShmem *VamanaWorkerReserveSlot(Oid dbOid, bool *created);
void	VamanaWorkerReleaseSlot(Oid dbOid);
void	VamanaWorkerClearDeadEntry(Oid dbOid);
void	VamanaWorkerQueueIndexCountDelta(Oid dbOid, int delta);

/*
 * vamanaworkershmem.c: cross-process wake, generalized over any target
 * backend by PID.  SvsKickLauncher is the specialization every non-launcher
 * caller wants; SvsWakeBackend also serves the launcher's own reply to a
 * build request (Svs prefix: extension-wide mechanism, not vamana-specific).
 */
void	SvsWakeBackend(pid_t pid);
void	SvsSetLauncherPid(pid_t pid);
void	SvsKickLauncher(void);

/*
 * Iterate every reserved control block under one LW_SHARED pass, invoking cb
 * per entry while the header lock is held.  The callback is shmem-generic — it
 * receives a locked reserved entry and its own ctx, and does its copy-out
 * before the lock drops; the shmem layer never learns any consumer's DTO.
 *
 * entry is not const: reading its presentation atomics (heartbeat_ts,
 * indexCount, per-slot status) goes through pg_atomic_read_*, which take a
 * non-const volatile pointer.  The callback must still treat it as read-only.
 */
typedef void (*VamanaReservedEntryCb) (VamanaWorkerShmem *entry, void *ctx);
void	VamanaWorkerForEachReserved(VamanaReservedEntryCb cb, void *ctx);

/* vamanaworkershmem.c: launcher-owned crash-backoff state (header lock) */
bool	VamanaWorkerBackoffSnapshot(Oid dbOid, VamanaLauncherBackoff *out);
void	VamanaWorkerBackoffStampAttempt(Oid dbOid, TimestampTz now);
void	VamanaWorkerBackoffRecordDeath(Oid dbOid, bool recovered);
void	VamanaWorkerBackoffClear(Oid dbOid);

/*
 * Lock-free backoff predicate for callers that already hold the header lock
 * (the stats hydration pass): true iff the worker has unrecovered crashes and
 * is in the launcher's respawn-backoff regime.  Reads entry->backoff directly;
 * distinct from the lock-acquiring VamanaWorkerBackoffSnapshot, which would
 * re-enter the non-recursive header LWLock if called under it.
 */
bool	VamanaWorkerIsBackingOff(const VamanaWorkerShmem *entry);

/* vamanaworkershmem.c: launcher initial-scan publication (header lock) */
void	VamanaWorkerSetInitialScanDone(void);
bool	VamanaWorkerInitialScanDone(void);

/* vamanaworkershmem.c: true iff every slot is occupied (capacity exhausted). */
bool	VamanaWorkerSlotsExhausted(void);

/* vamanaworkershmem.c: number of per-database control-block slots. */
int		VamanaWorkerSlotCapacity(void);

/* vamanaworkershmem.c */
LWLock *VamanaGetIndexLock(VamanaWorkerShmem *entry, Oid relid);
uint8	VamanaCategorizeSQLState(int sqlerrcode);
int		VamanaSlotErrcode(uint8 category);
void	VamanaWorkerFailSlot(VamanaWorkerSlot *slot, const char *message, uint8 category);

/* vamanaworker.c */
extern bool vamana_eviction_suppressed;

/*
 * True when the error currently being handled is the query-cancel raised by the
 * SIGTERM handler.  Recovery handlers that self-heal decode failures call this
 * from their PG_CATCH to decline a shutdown cancel, which is not a decode
 * failure and must reach the drain owner in VamanaWorkerMain.  Only meaningful
 * inside an error handler; keys on the errcode, not just the flag, so a genuine
 * decode error raised during the drain still self-heals.
 */
bool	VamanaShutdownCancelPending(void);

/*
 * Pure staleness kernel over a raw heartbeat and a reference clock; shared by
 * the live entry-path check and the snapshot-path worker-state classifier.
 */
bool	VamanaHeartbeatIsStale(uint64 rawHb, TimestampTz now);

/*
 * Counter-maintenance policy: is indexCount kept current on this node?  Derived
 * from the node fact (VamanaNodeIsPrimary) but named separately, so a future
 * primary-side pause of maintenance cannot silently mislabel worker_state.
 * Gates the startup seed, the zero-index log-once, and the SRF's standby NULL.
 */
bool	VamanaIndexCountIsMaintained(void);

/* Primary-only: seed indexCount to the live count in the worker startup txn. */
void	VamanaWorkerSeedIndexCount(void);

/* vamanaworkerindex.c */

/*
 * Enumerates every vamana index in the current database, one c.oid per row.
 * Shared by the standby loader and svs_teardown_database() so the definition
 * of "a vamana index" stays in one place.  Joins pg_am so the AM oid is not
 * hardcoded.
 */
#define VAMANA_ENUM_INDEXES_IN_DB_SQL \
	"SELECT c.oid " \
	"FROM pg_catalog.pg_class c " \
	"JOIN pg_catalog.pg_am a ON a.oid = c.relam " \
	"WHERE a.amname = 'vamana' AND c.relkind = 'i'"

/*
 * SPI kernel over VAMANA_ENUM_INDEXES_IN_DB_SQL: connect, execute, collect,
 * finish.  Returns a palloc'd List of index relid Oids (NIL if none).
 * Precondition: caller holds an open transaction with a pushed snapshot
 * (asserted); the wrapper owns the SPI session, not the transaction.  Callers
 * reduce as their grain needs: the standby loader loads each relid, the startup
 * seed counts them.
 */
List   *VamanaWorkerEnumerateIndexes(void);

/* VamanaWorkerEnumerateIndexes wrapped in its own transaction. */
List   *VamanaWorkerEnumerateAllIndexes(void);

SVSIndexHandle VamanaWorkerGetOrLoadIndex(Oid relid, bool *loadedFromDisk);
SVSIndexHandle VamanaWorkerEnsureIndexCurrent(Oid relid);
void	VamanaWorkerResetStaleSlots(void);

/* Converges a standby's cache onto targetRelids; returns true once every relid has a live slot. */
bool	VamanaReconcileStandbyCache(List *targetRelids,
									void (*activateSlot) (Oid relid));

/* vamanaworkersearch.c */
void	VamanaWorkerDispatchBatch(int *slotIdxs, int n);

/* vamanaworkerwrite.c */
void	VamanaWorkerProcessWriteSlot(int slotIdx);
void	VamanaWorkerProcessLoadSlot(int slotIdx);
void	VamanaWorkerProcessWarmupSlot(int slotIdx);

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
bool	VamanaWorkerSubmitWarmup(Oid indexRelid);
void	VamanaReleaseIndexLock(VamanaWorkerShmem *entry, Oid relid);
void	VamanaWorkerSignalReload(Oid indexRelid);
VamanaWorkerShmem *VamanaWorkerFindActiveSlot(void);
bool	VamanaWorkerEntryIsLive(VamanaWorkerShmem *entry);
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
