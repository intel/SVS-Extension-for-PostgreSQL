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
 * decodingCtx is NULL until WAL replay is initialized.
 */
typedef struct VamanaReplicationSlot
{
	char					slotName[NAMEDATALEN];
	LogicalDecodingContext *decodingCtx;
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

/* BGW: open a handle to the slot. Returns NULL if the slot does not exist. */
VamanaReplicationSlot *VamanaReplicationOpen(Oid dboid, Oid indexRelid);

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

/* BGW: advance confirmed_flush_lsn. Safe to call with slot == NULL. */
void	VamanaSlotAdvance(VamanaReplicationSlot *slot, XLogRecPtr newLsn);

/* BGW: free the handle (does not drop the underlying slot). Safe with NULL. */
void	VamanaReplicationClose(VamanaReplicationSlot *slot);

/* Drop the slot if it exists and is not active. */
void	VamanaReplicationDropIfExists(Oid dboid, Oid indexRelid);

/* Output plugin entry point — required by logical decoding infrastructure. */
extern void _PG_output_plugin_init(OutputPluginCallbacks *cb);

#endif							/* VAMANA_REPLICATION_H */
