/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_index_residency.h
 *
 * The durable fallback for a database's committed residency bytes: the
 * svs_index_residency catalog table, and the one number derived from it
 * that matters to a caller outside this file -- the floor a residency
 * budget must never be lowered under while the owning worker cannot be
 * trusted to answer from shared memory.
 *
 * svs_memory.c never touches SQL or the catalog; this module is the one
 * place that bridges live shared-memory accounting to a fact that survives
 * a worker that is not running.
 */

#ifndef SVS_INDEX_RESIDENCY_H
#define SVS_INDEX_RESIDENCY_H

#include "postgres.h"

/* Forward declaration; the full definition lives in vamanaworker.h. */
struct VamanaWorkerShmem;

/*
 * Record indexRelid's exact resident bytes for dbOid, or drop that record
 * once it unloads. Best-effort: skipped with no active transaction to run
 * in, and a failure once inside one is logged rather than propagated.
 * Every later load or unload of the same index re-derives its row from
 * scratch, so a missed write here is never a permanent loss, only a
 * transient staleness corrected at the next one.
 */
extern void SvsIndexResidencyRecordLoad(Oid indexRelid, Oid dbOid, uint64 residentBytes);
extern void SvsIndexResidencyRecordUnload(Oid indexRelid);

/*
 * Delete every durable row for dbOid whose index_relid is not in liveRelids
 * (numLive entries), the caller's own authoritative enumeration of that
 * database's current vamana indexes. A no-op, deliberately, when numLive is
 * 0: an empty live set is indistinguishable from a failed enumeration, and
 * this sweep must never risk lowering the durable floor for indexes that
 * are, in fact, still resident. Best-effort like the two functions above.
 */
extern void SvsIndexResidencyReconcileOrphans(Oid dbOid, Oid *liveRelids, int numLive);

/*
 * The durable floor a residency budget must respect on top of whatever the
 * caller's own live counter says: 0 if entry's worker is confirmed live
 * (the live counter is already the truth), otherwise the sum of every
 * index's last known committed bytes for dbOid. entry may be NULL -- no
 * reserved slot at all is not live either. Read under a lock on dbOid's
 * vamana_databases row, so this can never race a concurrent write to the
 * same durable total -- any future writer of that total must take the
 * same lock before writing.
 *
 * Unlike the two functions above, a failure here propagates rather than
 * being swallowed: a caller deciding whether a budget change is safe must
 * never silently treat a failed read as "nothing committed".
 *
 * Caller must already be inside a transaction with an active snapshot
 * (an ordinary trigger or query has one; a PRE_COMMIT xact callback does
 * not -- call this earlier, while the row trigger that queues a change
 * still has one, not from that callback).
 */
extern uint64 SvsIndexResidencyDurableFloor(Oid dbOid, struct VamanaWorkerShmem *entry);

/*
 * Durable resident_bytes for each of liveRelids, written into outBytes at
 * the same index; 0 where a relid has no durable row. Always zeroes
 * outBytes first. Best-effort: a failure is logged, not propagated.
 * Caller must already be inside a transaction with an active snapshot.
 */
extern void SvsIndexResidencyReadBytesForRelids(Oid dbOid, const Oid *liveRelids,
												 int numLive, uint64 *outBytes);

#endif							/* SVS_INDEX_RESIDENCY_H */
