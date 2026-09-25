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
 * backend) -> HANDOFF(measured, backend) -> RESIDENT(measured, worker). The
 * reservation is visible under this module's accounting continuously across
 * that lifecycle, so a concurrent admission check never reads a gap.
 *
 * A rebuild of an already-resident index (REINDEX, or a worker-restart
 * rebuild of an index whose RESIDENT reservation survived the restart)
 * instead starts from RESIDENT(measured, database) -> REBUILDING(new
 * estimate, backend), then rejoins the same CONFIRMED -> HANDOFF -> RESIDENT
 * path a fresh build takes. The old graph's bytes stay committed under
 * priorResidentBytes for the whole rebuild, since it is still genuinely
 * resident on disk and in the worker; every path off of REBUILDING other
 * than a successful confirm restores the reservation to RESIDENT at exactly
 * that prior size rather than dropping it.
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
	SVS_MEM_HANDOFF,
	SVS_MEM_RESIDENT,
	SVS_MEM_REBUILDING,
} SvsMemReservationState;

/*
 * One index's build-to-residency lifecycle, keyed by relid within its
 * database's control block. ownerPid is the reserving backend while
 * RESERVED/CONFIRMED/HANDOFF, and 0 once RESIDENT: residency then belongs to
 * the database, not to whichever process last touched it. relid == InvalidOid
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
	 * SvsMemoryConfirmBuild once released; SvsMemoryAbortBuild releases it
	 * too but drops the whole reservation via FreeReservation rather than
	 * zeroing this field in place. Read by the reaper, which has no other
	 * way to learn a dead backend's build peak.
	 */
	uint64		buildPeakBytes;

	/*
	 * The measured bytes this reservation held as RESIDENT just before a
	 * rebuild began. Set only on the RESIDENT -> REBUILDING transition;
	 * zero otherwise. residencyBytesCommitted keeps counting these bytes as
	 * resident for the whole rebuild, so this field never itself
	 * contributes to that counter; it exists only so RestorePriorResidency
	 * can put the reservation back exactly as it was if the rebuild does
	 * not reach a successful confirm. Cleared back to zero by
	 * RestorePriorResidency, and consumed (dropped, not added) by
	 * SvsMemoryConfirmBuild once a rebuild confirms. SvsMemoryReconcileLoad
	 * and SvsMemoryAccountUnload also read it in place of measuredBytes for
	 * as long as the state is REBUILDING, since measuredBytes itself stays
	 * zero until that confirm.
	 */
	uint64		priorResidentBytes;

	/*
	 * Rows that fit above numVectors before the next SVS block growth,
	 * as of the last measuredBytes refresh. Consumed by SvsMemoryReserveInsert
	 * one row at a time; restored by SvsMemoryAbortInsert if that row's
	 * insert never applies.
	 */
	uint64		capacityHeadroomVectors;
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
	bool		consumedHeadroom;
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
 * Backend, on transaction abort. Restores dbOid's budget to priorBudget,
 * floored at what's currently committed so the restore strands nothing.
 * Never errors; no-op if dbOid has no slot.
 */
extern void SvsMemoryRestoreResidencyBudget(Oid dbOid, uint64 priorBudget);

/*
 * Backend build gate, at CREATE INDEX. Reserves buildPeak against the
 * global build ceiling and residencyEstimate against dbOid's residency
 * budget, keyed by relid, owned by the calling backend. Errors on either
 * axis's rejection; neither counter changes on a rejected reservation.
 *
 * If relid already holds a RESIDENT reservation, this is a rebuild (REINDEX,
 * or a worker-restart rebuild of an index whose reservation survived the
 * restart), not a fresh build: it reuses the existing slot, moves it to
 * REBUILDING, and holds its prior measured bytes in priorResidentBytes
 * without adding residencyEstimate to residencyBytesCommitted, since the old
 * graph is still genuinely resident for as long as the rebuild is in
 * progress. An existing reservation in any other state still errors, the
 * same as today: two concurrent builds of one relid is not a case this
 * module accommodates.
 */
extern void SvsMemoryReserveBuild(Oid dbOid, Oid relid,
								   uint64 buildPeak, uint64 residencyEstimate);

/*
 * A no-op when reltuples <= 0 (never analyzed); SvsMemoryReserveBuild is
 * still the authoritative gate either way.
 */
extern void SvsMemoryCheckEstimatedBuildSize(double reltuples, int dimensions);

/*
 * Backend, after a successful build and before serializing to disk.
 * Releases buildPeak unconditionally and reconciles the residency
 * reservation from estimate to measuredResidencyBytes (RESERVED ->
 * CONFIRMED, or REBUILDING -> CONFIRMED for a rebuild). Returns false if the
 * measured bytes do not fit dbOid's residency budget -- the caller must fail
 * CREATE INDEX without serializing or contacting the worker. On that
 * rejection a fresh build's reservation is dropped entirely; a rebuild's
 * instead returns to RESIDENT at its pre-rebuild measured size, since that
 * graph is still genuinely resident. Returns true once the reservation is
 * confirmed at the exact measured size.
 *
 * Errors if relid's reservation is in any state other than RESERVED or
 * REBUILDING -- in particular, a REBUILDING record that ReconcileLoad's own
 * independent load already claimed straight to RESIDENT ahead of this call.
 * Confirming against that record would fold out its stale estimateBytes
 * instead of its real committed measuredBytes and land on CONFIRMED with no
 * owner, so this refuses rather than guessing.
 */
extern bool SvsMemoryConfirmBuild(Oid dbOid, Oid relid,
								   uint64 buildPeak, uint64 measuredResidencyBytes);

/*
 * Backend, after serializing a confirmed build to disk and before asking
 * the worker to load it (CONFIRMED -> HANDOFF). Pure state transition, no
 * byte accounting: the measured bytes ConfirmBuild already committed are
 * unaffected, and ownership stays with the calling backend until the
 * worker's own SvsMemoryReconcileLoad claims it.
 */
extern void SvsMemoryHandoffBuild(Oid dbOid, Oid relid);

/*
 * Backend, on any build error, whether before or after a successful
 * confirm. Releases whatever relid's reservation still holds -- its build
 * peak if ConfirmBuild hasn't already released it, and its estimate or its
 * measured bytes, whichever the reservation's own state says is currently
 * committed -- then drops the reservation. Safe to call more than once or
 * after ConfirmBuild already ran; there is nothing left to release once
 * relid has no reservation.
 *
 * A RESIDENT reservation is one exception: ReconcileLoad already handed it
 * to the database, so this leaves it untouched and only
 * SvsMemoryAccountUnload can release it. Reachable when a build's
 * synchronous warm-up load succeeds and a later statement in the same
 * transaction still fails.
 *
 * A REBUILDING reservation is the other: its committed bytes are the old
 * graph's, still genuinely resident, never the failed rebuild's own
 * estimate, so this releases only the build peak and returns the
 * reservation to RESIDENT at its pre-rebuild measured size rather than
 * dropping it.
 */
extern void SvsMemoryAbortBuild(Oid dbOid, Oid relid);

/*
 * Worker, at load. Reconciles a pending HANDOFF reservation to
 * measuredBytes in place (HANDOFF -> RESIDENT), or -- for a reload or
 * restart adopt with no pending reservation -- accounts measuredBytes
 * directly. Returns false, committing nothing, if measuredBytes does not
 * fit dbOid's residency budget.
 *
 * A REBUILDING reservation reaching here ahead of its own ConfirmBuild is
 * folded out by priorResidentBytes rather than measuredBytes, since a
 * rebuild's committed contribution is the old graph's prior size for as
 * long as it has not yet confirmed; any outstanding build peak is released
 * the same way ConfirmBuild would, and the resulting RESIDENT record leaves
 * no leftover priorResidentBytes or buildPeakBytes behind.
 */
extern bool SvsMemoryReconcileLoad(Oid dbOid, Oid relid, uint64 measuredBytes,
									uint64 capacityHeadroomVectors);

/*
 * Worker, at unload. Subtracts relid's committed resident bytes and drops
 * its reservation.
 *
 * A REBUILDING reservation's committed bytes are priorResidentBytes, not
 * measuredBytes, which stays 0 until a rebuild confirms; its outstanding
 * build peak, if any, is released here too, since dropping the index takes
 * an in-flight rebuild down with it.
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
 * Like SvsMemoryReanchorInsert, but never touches pending insert
 * reservations for relid -- those belong to unrelated, unapplied inserts.
 */
extern void SvsMemoryReconcileResident(Oid dbOid, Oid relid, uint64 measuredBytes,
										uint64 capacityHeadroomVectors);

/*
 * Worker, on the empty-table first-insert build path: relid's reservation
 * comes from SvsMemoryReconcileLoad rather than pre-existing, so this closes
 * the oldest pending insert reservation for relid without reanchoring one.
 */
extern void SvsMemoryCloseInsertReservation(Oid dbOid, Oid relid);

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

/*
 * Worker, at startup. Drops every RESIDENT reservation for dbOid not in
 * liveRelids -- an index dropped while the worker was down. RESERVED/
 * CONFIRMED reservations belong to a live backend; SvsMemoryReapDeadReservations
 * covers those. droppedRelids needs VAMANA_MAX_INDEXES entries of room;
 * caller clears each dropped relid's durable record.
 */
extern void SvsMemoryReconcileResidentReservations(Oid dbOid,
													const Oid *liveRelids, int numLiveRelids,
													Oid *droppedRelids, int *numDropped);

/*
 * Worker, at startup, for a relid with no reservation of its own yet (fresh
 * shmem, nothing preserved to reconcile). Reconciles durableBytes into
 * relid's committed total via SvsMemoryReconcileLoad, exactly as if it were
 * a real measurement. A no-op if relid already has a reservation -- that
 * one is never staler than the durable record and must not be overwritten.
 */
extern void SvsMemorySeedDurableResidency(Oid dbOid, Oid relid, uint64 durableBytes);

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

/* Stores relid's just-computed per-query search-scratch cost. No-op if relid has no reservation. */
extern void SvsMemorySetSearchScratchBytesPerQuery(Oid dbOid, Oid relid,
													uint64 bytesPerQuery);

/*
 * Dispatch-time gate: atomically admits batchBytes against dbOid's
 * search-scratch budget, adding to the in-flight total only if it fits.
 * Lock-free against other databases and other indexes in the same database.
 */
extern bool SvsMemoryReserveSearchScratch(Oid dbOid, uint64 batchBytes);

/* Releases batchBytes admitted by SvsMemoryReserveSearchScratch, floored at 0. */
extern void SvsMemoryReleaseSearchScratch(Oid dbOid, uint64 batchBytes);

/*
 * Tear down every accounting counter and reservation owned by entry, and
 * unwind its contribution to the header's global roll-ups. Called only when
 * entry's slot is being released or recycled to a new database; the caller
 * already holds the header lock, so this must not attempt to acquire it.
 */
extern void SvsMemoryResetDatabaseAccounting(struct VamanaWorkerShmem *entry);

#endif							/* SVS_MEMORY_H */
