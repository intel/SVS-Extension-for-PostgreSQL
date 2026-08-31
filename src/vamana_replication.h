/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_REPLICATION_H
#define VAMANA_REPLICATION_H

#include "postgres.h"

#include "access/xlogdefs.h"
#include "replication/logical.h"
#include "replication/output_plugin.h"
#include "replication/slot.h"

/* Forward declaration — full definition is in vamana.h. */
struct VamanaIndexCache;

/*
 * BGW-side handle for one logical replication slot.
 * Allocated in TopMemoryContext by VamanaReplicationOpen.
 */
typedef struct VamanaReplicationSlot
{
	char	slotName[NAMEDATALEN];
} VamanaReplicationSlot;

/*
 * Replay role.  A primary and a standby differ on the replay path in exactly
 * three ways; everything else (decode loop, per-record guard, error recovery,
 * lag valve) is identical.  The role captures those three differences so the
 * rest of the code depends on policy instead of scattering recovery checks.
 */
typedef struct VamanaReplayRole
{
	XLogRecPtr	(*current_wal_end) (TimeLineID *tli);	/* flush vs replay pointer */
	bool		creates_slot_on_load;	/* standby bootstraps its own slot */
	bool		processes_write_ipc;	/* primary services write requests */
	bool		persists_index;			/* standby cannot write WAL, so never saves */
} VamanaReplayRole;

/* Resolve the current role. The sole reader of RecoveryInProgress() on this path. */
const VamanaReplayRole *VamanaGetReplayRole(void);

/* True when this node is the primary (not in recovery). */
bool	VamanaNodeIsPrimary(void);

/* BGW: create and persist a slot anchored at the current WAL position. */
void	VamanaReplicationCreate(Oid dboid, Oid indexRelid);

/*
 * BGW: bootstrap a slot on a standby (create + build initial snapshot).
 * Must be called outside any transaction.
 */
void	VamanaReplicationCreateOnStandby(Oid dboid, Oid indexRelid);

/*
 * BGW: scan WAL to CONSISTENT and serialize the initial snapshot.
 * Must be called outside any open transaction, after all transactions active
 * at slot creation time have committed.
 */
void	VamanaReplicationBuildSnapshot(Oid dboid, Oid indexRelid);

/*
 * BGW: scan WAL to CONSISTENT or role->current_wal_end, whichever comes
 * first; never blocks waiting on the primary.  Safe to call repeatedly.
 */
void	VamanaReplicationActivateSlotBounded(Oid dboid, Oid indexRelid);

/* BGW: open a handle to the slot. Returns NULL if the slot does not exist. */
VamanaReplicationSlot *VamanaReplicationOpen(Oid dboid, Oid indexRelid);

/*
 * BGW: create the index's slot on a standby if none exists yet.  Idempotent;
 * no-op on a primary.  Must be called outside any transaction.
 */
void	VamanaReplicationEnsureSlot(Oid dboid, Oid indexRelid);

/*
 * BGW: drain one index's replication slot into its cache within a
 * self-contained transaction.  Owns the full transaction, snapshot, and
 * eviction-suppression lifecycle; no-op if the index is not cached or has no
 * slot.
 */
void	VamanaReplicationDrainSlot(Oid indexRelid);

/*
 * BGW: true when the index's slot pins more than maxLagMb of WAL.
 * Safe when the slot does not exist or has no restart_lsn yet.
 */
bool	VamanaReplicationSlotWalLagExceeds(Oid indexRelid, int maxLagMb);

/* BGW: true once the index's slot has reached snapshot consistency. */
bool	VamanaReplicationSlotIsConsistent(Oid dboid, Oid indexRelid);

/* BGW: advance confirmed_flush_lsn. Safe to call with slot == NULL. */
bool	VamanaSlotAdvance(VamanaReplicationSlot *slot, XLogRecPtr newLsn);

/* BGW: free the handle (does not drop the underlying slot). Safe with NULL. */
void	VamanaReplicationClose(VamanaReplicationSlot *slot);

/*
 * Outcome of a drop attempt.  The drop neither blocks nor throws, so BUSY is an
 * ordinary answer the caller has to act on rather than an error it can ignore:
 * the slot still exists, still pins WAL, and still holds back catalog_xmin.
 */
typedef enum VamanaSlotDropResult
{
	VAMANA_SLOT_DROP_DONE,		/* dropped, or already absent */
	VAMANA_SLOT_DROP_BUSY,		/* another process holds it; nothing dropped */
	VAMANA_SLOT_DROP_FAILED		/* unexpected failure, already logged */
} VamanaSlotDropResult;

/*
 * Drop the index's slot now if it exists and nobody holds it.  Never waits and
 * never throws; see the comment on TryDropSlot for why waiting is unsafe here.
 * In-worker callers use this directly, having released their own handle first.
 */
VamanaSlotDropResult VamanaReplicationDropIfExists(Oid dboid, Oid indexRelid);

/*
 * Backend: ask for the index's slot to be dropped when this transaction
 * commits.  DROP INDEX must go through here rather than dropping inline —
 * dropping a slot cannot be undone, and the object-access hook that notices the
 * drop runs before commit.
 */
void	VamanaReplicationQueueDropAtCommit(Oid dboid, Oid indexRelid);

/* Output plugin entry point — required by logical decoding infrastructure. */
extern void _PG_output_plugin_init(OutputPluginCallbacks *cb);

#endif							/* VAMANA_REPLICATION_H */
