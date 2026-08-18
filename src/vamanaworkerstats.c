/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkerstats.c
 *
 * Observability SRFs for the Vamana background worker.  Two grains,
 * mirroring core PG's pg_stat_replication/pg_replication_slots pairing:
 * pg_stat_vamana_worker() is one row per reserved database (worker grain);
 * pg_stat_vamana_worker_slot() is one row per work-request slot across all
 * reserved databases (slot grain).
 *
 * Both walk VamanaWorkerShmemHeader in a single LW_SHARED pass via
 * VamanaWorkerForEachReserved, copying out under the lock (the callback ctx
 * is a stats-layer accumulator).  Cross-database rows leak tenant existence
 * and liveness, so an unprivileged caller sees only its own MyDatabaseId
 * row; a pg_read_all_stats member sees all.  The predicate is computed once
 * per call and applied inside the callback — never a SQL GRANT/REVOKE,
 * which would also hide the self-row from ordinary users.
 */

#include "postgres.h"

#include "vamana_replication.h"
#include "vamanaworker.h"

#include "catalog/pg_authid.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "utils/acl.h"
#include "utils/builtins.h"
#include "utils/injection_point.h"

/*
 * Worker liveness state.  Total: every value has a VamanaWorkerStateName()
 * label and the switch has no default arm, so a new state is a compile error
 * until it is named.
 */
typedef enum VamanaWorkerState
{
	VAMANA_WORKER_REPLICA,		/* node in recovery; counters not maintained */
	VAMANA_WORKER_RUNNING,		/* live pid, fresh heartbeat */
	VAMANA_WORKER_UNRESPONSIVE, /* live pid, stale heartbeat, not yet reaped */
	VAMANA_WORKER_BACKOFF,		/* crashed; launcher is in respawn backoff */
	VAMANA_WORKER_STARTING,		/* reserved, no live pid yet, no prior failures */
} VamanaWorkerState;

static const char *
VamanaWorkerStateName(VamanaWorkerState state)
{
	switch (state)
	{
		case VAMANA_WORKER_REPLICA:		return "replica";
		case VAMANA_WORKER_RUNNING:		return "running";
		case VAMANA_WORKER_UNRESPONSIVE: return "unresponsive";
		case VAMANA_WORKER_BACKOFF:		return "backoff";
		case VAMANA_WORKER_STARTING:	return "starting";
	}
	pg_unreachable();
}

/*
 * Per-reserved-database snapshot, copied out under the header lock by the
 * worker hydration callback.  A plain-values DTO: it never carries the
 * launcher's VamanaLauncherBackoff struct, only the derived bool, so the stats
 * path has no compile-time dependency on that layout.
 */
typedef struct VamanaWorkerSnapshot
{
	Oid			dbOid;
	pid_t		workerPid;
	bool		backingOff;
	bool		evictAll;
	uint64		heartbeatRaw;
	uint32		indexCount;
} VamanaWorkerSnapshot;

/*
 * Classify worker liveness from a snapshot.  Pure over its arguments: node role
 * and clock are node/call facts sampled once per SRF call and passed in, never
 * re-read here, so every row is classified against one clock and one role.
 */
static VamanaWorkerState
VamanaClassifyWorkerState(const VamanaWorkerSnapshot *s, TimestampTz now,
						  bool isPrimary)
{
	bool		stale;

	if (!isPrimary)
		return VAMANA_WORKER_REPLICA;

	stale = VamanaHeartbeatIsStale(s->heartbeatRaw, now);

	if (s->workerPid != 0 && !stale)
		return VAMANA_WORKER_RUNNING;

	/*
	 * A crashed worker does not zero its own pid (the launcher reaps it via the
	 * bgworker handle), so a stale-but-nonzero pid means hung, not gone.  Once
	 * the launcher has charged the death, backoff outranks that transient
	 * unresponsive window.
	 */
	if (s->backingOff)
		return VAMANA_WORKER_BACKOFF;

	if (s->workerPid != 0)
		return VAMANA_WORKER_UNRESPONSIVE;

	return VAMANA_WORKER_STARTING;
}

/*
 * Shared visibility gate for both SRFs.  The privilege bool is computed once
 * per call and stashed here; each callback skips entries the caller may not
 * see.  base holds the grain-specific accumulator each SRF supplies.
 */
typedef struct VamanaStatVisibility
{
	bool		seeAll;			/* has_privs_of_role(pg_read_all_stats) */
	Oid			selfDbOid;		/* the only db an unprivileged caller may see */
} VamanaStatVisibility;

static bool
VamanaStatEntryVisible(const VamanaStatVisibility *vis, Oid dbOid)
{
	return vis->seeAll || dbOid == vis->selfDbOid;
}

static VamanaStatVisibility
VamanaStatVisibilityForCaller(void)
{
	VamanaStatVisibility vis;

	vis.seeAll = has_privs_of_role(GetUserId(), ROLE_PG_READ_ALL_STATS);
	vis.selfDbOid = MyDatabaseId;
	return vis;
}

/* -----------------------------------------------------------------------
 * pg_stat_vamana_worker(): one row per reserved database (worker grain).
 *
 * Column layout (6 columns):
 *   0  db_oid        oid
 *   1  worker_pid    int4         (0 -> NULL)
 *   2  worker_state  text         (see VamanaWorkerStateName)
 *   3  index_count   int4         (NULL on a standby — counter not maintained)
 *   4  evict_all     bool
 *   5  heartbeat_ts  timestamptz  (0 -> NULL)
 * ----------------------------------------------------------------------- */

#define PG_STAT_VAMANA_WORKER_COLS 6

typedef struct VamanaWorkerHydrateCtx
{
	VamanaStatVisibility vis;
	VamanaWorkerSnapshot *snapshots;
	int			count;
	int			capacity;
} VamanaWorkerHydrateCtx;

static void
VamanaWorkerHydrateCb(VamanaWorkerShmem *entry, void *ctxArg)
{
	VamanaWorkerHydrateCtx *ctx = (VamanaWorkerHydrateCtx *) ctxArg;
	VamanaWorkerSnapshot *snap;

	if (!VamanaStatEntryVisible(&ctx->vis, entry->dbOid))
		return;

	Assert(ctx->count < ctx->capacity);
	snap = &ctx->snapshots[ctx->count];

	snap->dbOid = entry->dbOid;
	snap->workerPid = entry->workerPid;
	snap->backingOff = VamanaWorkerIsBackingOff(entry);
	snap->evictAll = (pg_atomic_read_u32(&entry->evict_all) != 0);
	snap->heartbeatRaw = pg_atomic_read_u64(&entry->heartbeat_ts);
	snap->indexCount = pg_atomic_read_u32(&entry->indexCount);
	ctx->count++;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(pg_stat_vamana_worker);
Datum
pg_stat_vamana_worker(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	VamanaWorkerHydrateCtx ctx;
	TimestampTz now;
	bool		isPrimary;

	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == PG_STAT_VAMANA_WORKER_COLS);

	/*
	 * At most one row per reserved slot; size the accumulator to capacity so the
	 * callback never reallocates under the lock.
	 */
	ctx.vis = VamanaStatVisibilityForCaller();
	ctx.capacity = VamanaWorkerSlotCapacity();
	ctx.count = 0;
	ctx.snapshots = palloc(sizeof(VamanaWorkerSnapshot) * ctx.capacity);

	VamanaWorkerForEachReserved(VamanaWorkerHydrateCb, &ctx);

	/* Node role and clock are call-wide facts; sample each once, classify pure. */
	isPrimary = VamanaNodeIsPrimary();
	now = GetCurrentTimestamp();

	for (int i = 0; i < ctx.count; i++)
	{
		const VamanaWorkerSnapshot *snap = &ctx.snapshots[i];
		VamanaWorkerState state = VamanaClassifyWorkerState(snap, now, isPrimary);
		Datum		values[PG_STAT_VAMANA_WORKER_COLS];
		bool		nulls[PG_STAT_VAMANA_WORKER_COLS];

		memset(nulls, 0, sizeof(nulls));

		values[0] = ObjectIdGetDatum(snap->dbOid);

		if (snap->workerPid != 0)
			values[1] = Int32GetDatum((int32) snap->workerPid);
		else
			nulls[1] = true;

		values[2] = CStringGetTextDatum(VamanaWorkerStateName(state));

		if (VamanaIndexCountIsMaintained())
			values[3] = Int32GetDatum((int32) snap->indexCount);
		else
			nulls[3] = true;

		values[4] = BoolGetDatum(snap->evictAll);

		if (snap->heartbeatRaw != 0)
			values[5] = TimestampTzGetDatum((TimestampTz) snap->heartbeatRaw);
		else
			nulls[5] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

/* -----------------------------------------------------------------------
 * pg_stat_vamana_worker_slot(): one row per work-slot across all reserved
 * databases (slot grain).
 *
 * Column layout (6 columns):
 *   0  db_oid         oid
 *   1  slot_index     int4
 *   2  slot_status    text   ("empty"/"pending"/"processing"/"done"/"error")
 *   3  slot_kind      text   ("search"/"insert"/"delete"/"maintenance"/"load"/"warmup"/NULL)
 *   4  index_relid    oid    (InvalidOid -> NULL)
 *   5  error_message  text   (NULL unless status == error)
 * ----------------------------------------------------------------------- */

#define PG_STAT_VAMANA_WORKER_SLOT_COLS 6

/*
 * One work-slot's presentation snapshot, read with the acquire barrier that
 * pairs the writers' payload -> pg_write_barrier() -> status protocol.  Status
 * determines which payload fields are valid, encoded once here so the SRF is a
 * pure formatter.
 */
typedef struct VamanaWorkerSlotSnapshot
{
	uint32		status;
	uint8		slotKind;
	Oid			indexRelid;
	bool		hasError;
	char		errorMessage[sizeof(((VamanaWorkerSlot *) 0)->errorMessage)];
} VamanaWorkerSlotSnapshot;

static void
VamanaWorkerReadSlotSnapshot(VamanaWorkerSlot *slot,
							 VamanaWorkerSlotSnapshot *out)
{
	out->status = pg_atomic_read_u32(&slot->status);
	pg_read_barrier();

	out->slotKind = slot->slotKind;
	out->indexRelid = slot->indexRelid;
	out->hasError = (out->status == VAMANA_SLOT_ERROR &&
					 slot->errorMessage[0] != '\0');
	if (out->hasError)
		strlcpy(out->errorMessage, slot->errorMessage, sizeof(out->errorMessage));
	else
		out->errorMessage[0] = '\0';
}

static const char *
VamanaSlotStatusName(uint32 status)
{
	switch (status)
	{
		case VAMANA_SLOT_EMPTY:		 return "empty";
		case VAMANA_SLOT_PENDING:	 return "pending";
		case VAMANA_SLOT_PROCESSING: return "processing";
		case VAMANA_SLOT_DONE:		 return "done";
		case VAMANA_SLOT_ERROR:		 return "error";
	}
	pg_unreachable();
}

/* NULL for an empty slot (no operation carried) or an unrecognised kind. */
static const char *
VamanaSlotKindName(uint32 status, uint8 slotKind)
{
	if (status == VAMANA_SLOT_EMPTY)
		return NULL;

	switch (slotKind)
	{
		case VAMANA_SLOTKIND_SEARCH:	  return "search";
		case VAMANA_SLOTKIND_INSERT:	  return "insert";
		case VAMANA_SLOTKIND_DELETE:	  return "delete";
		case VAMANA_SLOTKIND_MAINTENANCE: return "maintenance";
		case VAMANA_SLOTKIND_LOAD:		  return "load";
		case VAMANA_SLOTKIND_WARMUP:	  return "warmup";
	}
	return NULL;
}

typedef struct VamanaWorkerSlotRow
{
	Oid			dbOid;
	int			slotIndex;
	VamanaWorkerSlotSnapshot slot;
} VamanaWorkerSlotRow;

typedef struct VamanaSlotCollectCtx
{
	VamanaStatVisibility vis;
	VamanaWorkerSlotRow *rows;
	int			count;
	int			capacity;
} VamanaSlotCollectCtx;

/*
 * Copy every work-slot of one visible entry, walking entry->slots INSIDE the
 * iterator's header lock: holding LW_SHARED keeps slots/maxSlots and the
 * entry's identity stable, so a released-and-re-reserved entry cannot mis-
 * attribute slots to the wrong tenant.  Per-slot payload freshness is handled
 * independently by the acquire barrier in VamanaWorkerReadSlotSnapshot.  Must
 * stay a bounded struct copy per slot — no text/tuplestore work — to respect
 * VamanaWorkerForEachReserved's no-unbounded-work-under-the-lock contract.
 */
static void
VamanaSlotCollectCb(VamanaWorkerShmem *entry, void *ctxArg)
{
	VamanaSlotCollectCtx *ctx = (VamanaSlotCollectCtx *) ctxArg;

	if (!VamanaStatEntryVisible(&ctx->vis, entry->dbOid))
		return;

	for (int i = 0; i < entry->maxSlots; i++)
	{
		VamanaWorkerSlotRow *row;

		Assert(ctx->count < ctx->capacity);
		row = &ctx->rows[ctx->count++];

		row->dbOid = entry->dbOid;
		row->slotIndex = i;
		VamanaWorkerReadSlotSnapshot(&entry->slots[i], &row->slot);
	}
}

/* Upper bound on total slots across every header entry, reserved or not. */
static int
VamanaWorkerTotalSlotCapacity(void)
{
	return VamanaWorkerSlotCapacity() * MaxBackends;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(pg_stat_vamana_worker_slot);
Datum
pg_stat_vamana_worker_slot(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	VamanaSlotCollectCtx ctx;

	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == PG_STAT_VAMANA_WORKER_SLOT_COLS);

	ctx.vis = VamanaStatVisibilityForCaller();
	ctx.capacity = VamanaWorkerTotalSlotCapacity();
	ctx.count = 0;
	ctx.rows = palloc(sizeof(VamanaWorkerSlotRow) * ctx.capacity);

	VamanaWorkerForEachReserved(VamanaSlotCollectCb, &ctx);

	for (int i = 0; i < ctx.count; i++)
	{
		const VamanaWorkerSlotRow *row = &ctx.rows[i];
		const VamanaWorkerSlotSnapshot *snap = &row->slot;
		const char *kindStr;
		Datum		values[PG_STAT_VAMANA_WORKER_SLOT_COLS];
		bool		nulls[PG_STAT_VAMANA_WORKER_SLOT_COLS];

		memset(nulls, 0, sizeof(nulls));

		values[0] = ObjectIdGetDatum(row->dbOid);
		values[1] = Int32GetDatum(row->slotIndex);
		values[2] = CStringGetTextDatum(VamanaSlotStatusName(snap->status));

		kindStr = VamanaSlotKindName(snap->status, snap->slotKind);
		if (kindStr != NULL)
			values[3] = CStringGetTextDatum(kindStr);
		else
			nulls[3] = true;

		if (OidIsValid(snap->indexRelid))
			values[4] = ObjectIdGetDatum(snap->indexRelid);
		else
			nulls[4] = true;

		if (snap->hasError)
			values[5] = CStringGetTextDatum(snap->errorMessage);
		else
			nulls[5] = true;

		/* Test hook: TAP proves this runs outside the header LW_SHARED hold. */
		INJECTION_POINT("vamana-slot-stat-emit-row", NULL);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}
