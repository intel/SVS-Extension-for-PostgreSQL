/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_memory.h
 *
 * The single accounting authority for SVS memory: build peak, index
 * residency, and insert growth, each checked against a per-database budget
 * and a cluster-wide ceiling. Backends and the worker call this API; nobody
 * else tracks a byte count or re-implements a limit check.
 *
 * A successful build's reservation transfers ownership rather than
 * releasing outright: RESERVED(estimate, backend) -> CONFIRMED(measured,
 * backend) -> RESIDENT(measured, worker). The reservation is visible under
 * this module's accounting continuously across that lifecycle, so a
 * concurrent admission check never reads a gap.
 *
 * SvsMemReservation and SvsMemInsertReservation are declared here, not in
 * vamanaworkershmem.c, because this module owns their shape and every
 * transition between their states; vamanaworker.h only embeds them as
 * fields of VamanaWorkerShmem, the way it embeds any other foreign type.
 */

#ifndef SVS_MEMORY_H
#define SVS_MEMORY_H

#include "postgres.h"

#include "datatype/timestamp.h"

/* Forward declaration; the full definition lives in vamanaworker.h. */
struct VamanaWorkerShmem;

/*
 * Cluster-wide ceilings and per-database fallbacks. svs.max_build_memory,
 * svs.max_residency_memory, svs.default_residency_memory,
 * svs.max_search_work_mem, and svs.default_search_work_mem back these
 * directly once registered in VamanaInit; until then they hold their
 * compiled-in default, which is exactly what a database with no GUC
 * configuration yet observes.
 */
extern PGDLLIMPORT int vamana_max_build_memory_mb;
extern PGDLLIMPORT int vamana_max_residency_memory_mb;
extern PGDLLIMPORT int vamana_default_residency_memory_mb;
extern PGDLLIMPORT int vamana_max_search_work_mem_mb;
extern PGDLLIMPORT int vamana_default_search_work_mem_mb;

typedef enum SvsMemReservationState
{
	SVS_MEM_RESERVED,
	SVS_MEM_CONFIRMED,
	SVS_MEM_RESIDENT,
} SvsMemReservationState;

/*
 * One index's build-to-residency lifecycle, keyed by relid within its
 * database's control block. ownerPid is the reserving backend while
 * RESERVED/CONFIRMED, and 0 once RESIDENT: residency then belongs to the
 * database, not to whichever process last touched it. relid == InvalidOid
 * marks a free slot, the same "0 is free" convention VamanaIndexLockSlot
 * and VamanaWorkerReloadRequest already use.
 *
 * searchScratchBytesPerQuery is a memoized cost, not a reservation: it has
 * no state, no owner, and no timestamp. It shares this record only because
 * both it and the residency reservation key off the same relid lookup.
 *
 * cachedSearchWindowSize/cachedUseSearchHistory are the reloption values
 * searchScratchBytesPerQuery was last computed against, so a later recheck
 * can tell a real change from an unrelated relcache invalidation.
 */
typedef struct SvsMemReservation
{
	Oid			relid;
	SvsMemReservationState state;
	int			ownerPid;
	TimestampTz reservedAt;
	uint64		estimateBytes;
	uint64		measuredBytes;
	uint64		searchScratchBytesPerQuery;
	int			cachedSearchWindowSize;
	bool		cachedUseSearchHistory;

	/*
	 * The build peak reserved for this index, still outstanding. Zeroed by
	 * SvsMemoryHandoffBuild once released; SvsMemoryAbortBuild releases it
	 * too but drops the whole reservation via FreeReservation rather than
	 * zeroing this field in place. Read by the reaper, which has no other
	 * way to learn a dead backend's build peak.
	 */
	uint64		buildPeakBytes;
} SvsMemReservation;

/*
 * One backend's not-yet-applied insert batch against a resident index.
 * Several can be pending for the same relid at once, from different
 * backends; SvsMemoryReanchorInsert folds them in arrival order. relid ==
 * InvalidOid marks a free slot.
 */
typedef struct SvsMemInsertReservation
{
	Oid			relid;
	int			ownerPid;
	TimestampTz reservedAt;
	uint64		deltaBytes;
} SvsMemInsertReservation;

/*
 * Resolve the effective residency budget in bytes for a database already
 * admitted via SvsMemoryAdmitDatabase. Errors if dbOid was never admitted.
 */
extern uint64 SvsMemoryResidencyBudget(Oid dbOid);

/*
 * Config-time admission. Admits dbOid at residencyBudget bytes, or updates
 * an already-admitted database to a new budget, only if that budget is not
 * below what dbOid already has committed, and the cluster-wide sum of every
 * admitted database's budget still fits svs.max_residency_memory. Errors on
 * rejection; on success, dbOid's admitted budget governs every later build,
 * load, and insert check for that database.
 *
 * durableCommittedFloor is the caller's answer to "what does dbOid hold
 * that this module's own live counter might not currently reflect" -- 0
 * when the live counter (entry->residencyBytesCommitted) is already known
 * to be the truth, or a durable figure (see svs_index_residency.h) when it
 * might not be, e.g. a worker mid-restart briefly reporting zero. This
 * module never resolves that question itself: it has no notion of a
 * worker's liveness or a durable catalog record, only bytes given to it.
 * The guard compares residencyBudget against whichever of the two
 * (live counter or durableCommittedFloor) is larger.
 */
extern void SvsMemoryAdmitDatabase(Oid dbOid, uint64 residencyBudget,
									uint64 durableCommittedFloor);

/*
 * Backend build gate, at CREATE INDEX. Reserves buildPeak against the
 * global build ceiling and residencyEstimate against dbOid's residency
 * budget, keyed by relid, owned by the calling backend. Errors on either
 * axis's rejection; neither counter changes on a rejected reservation.
 */
extern void SvsMemoryReserveBuild(Oid dbOid, Oid relid,
								   uint64 buildPeak, uint64 residencyEstimate);

/*
 * Backend, after a successful build and before serializing to disk.
 * Releases buildPeak unconditionally and reconciles the residency
 * reservation from estimate to measuredResidencyBytes. Returns false, and
 * drops the reservation entirely, if the measured bytes do not fit dbOid's
 * residency budget -- the caller must fail CREATE INDEX without serializing
 * or contacting the worker. Returns true once the reservation is confirmed
 * at the exact measured size.
 */
extern bool SvsMemoryHandoffBuild(Oid dbOid, Oid relid,
								   uint64 buildPeak, uint64 measuredResidencyBytes);

/*
 * Backend, on any build error, whether before or after a successful
 * handoff. Releases whatever relid's reservation still holds -- its build
 * peak if HandoffBuild hasn't already released it, and its estimate or its
 * measured bytes, whichever the reservation's own state says is currently
 * committed -- then drops the reservation. Safe to call more than once or
 * after HandoffBuild already ran; there is nothing left to release once
 * relid has no reservation.
 */
extern void SvsMemoryAbortBuild(Oid dbOid, Oid relid);

/*
 * Worker, at load. Reconciles a pending handoff to measuredBytes in place,
 * or -- for a reload or restart adopt with no pending reservation --
 * accounts measuredBytes directly. Returns false, committing nothing, if
 * measuredBytes does not fit dbOid's residency budget.
 */
extern bool SvsMemoryReconcileLoad(Oid dbOid, Oid relid, uint64 measuredBytes);

/*
 * Worker, at unload. Subtracts relid's committed resident bytes and drops
 * its reservation.
 */
extern void SvsMemoryAccountUnload(Oid dbOid, Oid relid);

/*
 * Backend insert gate, per batch, before the write lock is taken. Reserves
 * deltaBytes as pending growth against dbOid's residency budget. Returns
 * false, reserving nothing, if it would not fit.
 */
extern bool SvsMemoryReserveInsert(Oid dbOid, Oid relid, uint64 deltaBytes);

/*
 * Worker, after applying an insert batch under the index's write lock.
 * Folds the oldest pending insert reservation for relid, plus relid's prior
 * committed size, into the single fresh exact measurement measuredBytes.
 */
extern void SvsMemoryReanchorInsert(Oid dbOid, Oid relid, uint64 measuredBytes);

/*
 * Backend cleanup when a reserved insert never reaches the worker's
 * reanchor. Releases the caller's own pending reservation for relid; a
 * no-op if there is none.
 */
extern void SvsMemoryAbortInsert(Oid dbOid, Oid relid);

/*
 * Reaps every reservation -- build or pending insert -- whose owning
 * backend is no longer alive. Called from the launcher's latch cycle and
 * its startup scan.
 */
extern void SvsMemoryReapDeadReservations(void);

typedef struct SvsMemoryStats
{
	uint64		residencyBudget;
	uint64		residencyBytesCommitted;
	uint64		buildBytesCommitted;
} SvsMemoryStats;

/*
 * Reads dbOid's committed totals for the statistics view. Returns false,
 * leaving *out unset, if dbOid was never admitted.
 */
extern bool SvsMemoryReadStats(Oid dbOid, SvsMemoryStats *out);

/*
 * Resolve the per-database residency budget (override, else
 * svs.default_residency_memory) and search-scratch budget (override, else
 * svs.default_search_work_mem) in bytes. Always finite. Callers must hold
 * whatever lock guards entry's override fields (the header lock, at the
 * time of writing).
 */
extern uint64 SvsMemoryResolveResidencyBudget(const struct VamanaWorkerShmem *entry);
extern uint64 SvsMemoryResolveSearchWorkMem(const struct VamanaWorkerShmem *entry);

/*
 * Reads relid's memoized per-query search-scratch cost for the statistics
 * view. Returns 0 if dbOid was never admitted or relid has no reservation
 * -- the same "not yet computed" sentinel the field uses everywhere else.
 */
extern uint64 SvsMemorySearchScratchBytesPerQuery(Oid dbOid, Oid relid);

/*
 * Recheck relid's search-scratch cost against the reloption values it was
 * last computed under, resetting searchScratchBytesPerQuery to 0 (not yet
 * computed) if either differs. A no-op if relid has no reservation yet.
 */
extern void SvsMemoryRecheckSearchScratchOptions(Oid dbOid, Oid relid,
												  int searchWindowSize,
												  bool useSearchHistory);

/*
 * Tear down every accounting counter and reservation owned by entry, and
 * unwind its contribution to the header's global roll-ups. Called only when
 * entry's slot is being released or recycled to a new database; the caller
 * already holds the header lock, so this must not attempt to acquire it.
 */
extern void SvsMemoryResetDatabaseAccounting(struct VamanaWorkerShmem *entry);

#endif							/* SVS_MEMORY_H */
