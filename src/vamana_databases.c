/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_databases.c
 *
 * Row-level AFTER INSERT OR UPDATE trigger on vamana_databases, and the
 * PRE_COMMIT/COMMIT/ABORT machinery that reserves a shmem slot for every
 * database enabled within the transaction — before the row becomes visible
 * to any other backend, so a CREATE INDEX in a just-enabled database never
 * races the launcher's async NOTIFY/poll.
 *
 * The trigger resolves datname to a database OID (rejecting the row if no
 * such database exists) and appends the entry to a backend-local,
 * TopTransactionContext-scoped queue; it takes no shmem lock itself. The
 * queue is drained by the same xact callback that reserves shmem slots.
 */

#include "postgres.h"

#include "svs_index_residency.h"
#include "svs_memory.h"
#include "vamana_databases.h"
#include "vamanaworker.h"
#include "vamana_subxid_pending_array.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "commands/dbcommands.h"
#include "commands/extension.h"
#include "commands/trigger.h"
#include "executor/spi.h"
#include "storage/lmgr.h"
#include "storage/lock.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"

/* Column positions in vamana_databases, matching the CREATE TABLE order. */
#define VAMANA_DATABASES_ATTNUM_DATNAME			1
#define VAMANA_DATABASES_ATTNUM_ENABLED			2
#define VAMANA_DATABASES_ATTNUM_RESTART_GENERATION	3
#define VAMANA_DATABASES_ATTNUM_RESIDENCY_MEMORY	6
#define VAMANA_DATABASES_ATTNUM_SEARCH_WORK_MEM	7

#define VAMANA_DATABASES_QUEUE_INITIAL_CAPACITY	16

/* Reset to NULL at transaction end, alongside TopTransactionContext. */
static VamanaSubxidPendingArray *CurrentReservationQueue = NULL;

/* dbOids reserved by this transaction; released on ABORT. TopTransactionContext-scoped. */
static List *ReservedThisXactDbOids = NIL;

/* Pre-existing databases whose budget this transaction changed at PRE_COMMIT; restored on ABORT. */
typedef struct ResidencyBudgetSnapshot
{
	Oid			dbOid;
	uint64		priorBudget;
} ResidencyBudgetSnapshot;

static List *ResidencyBudgetSnapshotsThisXact = NIL;

static bool ReservationCallbacksRegistered = false;

static void EnsureReservationCallbacksRegistered(void);
static void VamanaDatabasesXactCallback(XactEvent event, void *arg);
static void VamanaDatabasesSubXactCallback(SubXactEvent event,
											SubTransactionId mySubid,
											SubTransactionId parentSubid,
											void *arg);
static void ReserveSlotsForEnabledEntries(void);
static void ReleaseSlotsReservedThisXact(void);
static void RestoreResidencyBudgetSnapshotsThisXact(void);

static bool
ResidencyBudgetAlreadySnapshotted(Oid dbOid)
{
	ListCell   *lc;

	foreach(lc, ResidencyBudgetSnapshotsThisXact)
	{
		ResidencyBudgetSnapshot *snapshot = (ResidencyBudgetSnapshot *) lfirst(lc);

		if (snapshot->dbOid == dbOid)
			return true;
	}
	return false;
}

static VamanaSubxidPendingArray *
GetOrCreateReservationQueue(void)
{
	if (CurrentReservationQueue == NULL)
		CurrentReservationQueue =
			VamanaSubxidPendingArrayCreate(TopTransactionContext,
									 sizeof(VamanaDatabasesReservationEntry),
									 offsetof(VamanaDatabasesReservationEntry, subxid),
									 VAMANA_DATABASES_QUEUE_INITIAL_CAPACITY);
	return CurrentReservationQueue;
}

static void
QueueReservationEntry(Name datname, Oid dbOid, bool enabled, int64 restart_generation,
					  int residencyMemoryMbOverride, int searchWorkMemMbOverride,
					  uint64 durableResidencyFloorBytes)
{
	VamanaDatabasesReservationEntry *entry =
		VamanaSubxidPendingArrayAppend(GetOrCreateReservationQueue());

	namestrcpy(&entry->datname, NameStr(*datname));
	entry->dbOid = dbOid;
	entry->enabled = enabled;
	entry->restart_generation = restart_generation;
	entry->residencyMemoryMbOverride = residencyMemoryMbOverride;
	entry->searchWorkMemMbOverride = searchWorkMemMbOverride;
	entry->durableResidencyFloorBytes = durableResidencyFloorBytes;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(vamana_databases_queue_reservation);
Datum
vamana_databases_queue_reservation(PG_FUNCTION_ARGS)
{
	TriggerData *trigdata = (TriggerData *) fcinfo->context;
	HeapTuple	tuple;
	TupleDesc	tupdesc;
	bool		isnull;
	Datum		datnameDatum;
	Datum		enabledDatum;
	Datum		restartGenDatum;
	Datum		residencyMemoryDatum;
	Datum		searchWorkMemDatum;
	Name		datname;
	Oid			dbOid;
	int64		restart_generation;
	bool		residencyMemoryIsNull;
	bool		searchWorkMemIsNull;

	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "vamana_databases_queue_reservation: not called by trigger manager");

	if (!TRIGGER_FIRED_FOR_ROW(trigdata->tg_event))
		elog(ERROR, "vamana_databases_queue_reservation: must be fired for row");

	if (TRIGGER_FIRED_BY_INSERT(trigdata->tg_event))
		tuple = trigdata->tg_trigtuple;
	else if (TRIGGER_FIRED_BY_UPDATE(trigdata->tg_event))
		tuple = trigdata->tg_newtuple;
	else
		elog(ERROR, "vamana_databases_queue_reservation: must be fired by INSERT or UPDATE");

	EnsureReservationCallbacksRegistered();

	tupdesc = trigdata->tg_relation->rd_att;

	datnameDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_DATNAME, tupdesc, &isnull);
	if (isnull)
		elog(ERROR, "vamana_databases_queue_reservation: datname is null");
	datname = DatumGetName(datnameDatum);

	enabledDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_ENABLED, tupdesc, &isnull);
	if (isnull)
		elog(ERROR, "vamana_databases_queue_reservation: enabled is null");

	restartGenDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_RESTART_GENERATION, tupdesc, &isnull);
	if (isnull)
		elog(ERROR, "vamana_databases_queue_reservation: restart_generation is null");
	restart_generation = DatumGetInt64(restartGenDatum);

	residencyMemoryDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_RESIDENCY_MEMORY, tupdesc,
										 &residencyMemoryIsNull);
	searchWorkMemDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_SEARCH_WORK_MEM, tupdesc,
									   &searchWorkMemIsNull);

	dbOid = get_database_oid(NameStr(*datname), false);

	/* Resolved here, not in the PRE_COMMIT callback that drains this queue: only this trigger has an active snapshot. */
	QueueReservationEntry(datname, dbOid, DatumGetBool(enabledDatum), restart_generation,
						  residencyMemoryIsNull ? 0 : DatumGetInt32(residencyMemoryDatum),
						  searchWorkMemIsNull ? 0 : DatumGetInt32(searchWorkMemDatum),
						  DatumGetBool(enabledDatum) ?
							  SvsIndexResidencyDurableFloor(dbOid, VamanaWorkerLookupSlot(dbOid)) : 0);

	return PointerGetDatum(NULL);	/* AFTER trigger; return value is ignored */
}

/*
 * BEFORE INSERT OR UPDATE trigger: rejects a row whose resolved
 * search_work_mem would push the cluster-wide sum over
 * svs.max_search_work_mem. ShareRowExclusiveLock (self-conflicting)
 * serializes concurrent statements against this sum; the row lock the
 * INSERT/UPDATE already holds only covers the one row being changed.
 */
PGDLLEXPORT PG_FUNCTION_INFO_V1(vamana_databases_check_search_work_mem_ceiling);
Datum
vamana_databases_check_search_work_mem_ceiling(PG_FUNCTION_ARGS)
{
	TriggerData *trigdata = (TriggerData *) fcinfo->context;
	HeapTuple	tuple;
	TupleDesc	tupdesc;
	bool		isnull;
	Datum		datnameDatum;
	Datum		searchWorkMemDatum;
	Name		datname;
	int32		resolvedMb;
	char	   *qualifiedName;
	Oid			paramTypes[1] = {NAMEOID};
	Datum		paramValues[1];
	uint64		otherRowsSumMb;
	uint64		projectedTotalMb;
	bool		sumIsNull;

	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: not called by trigger manager");

	if (!TRIGGER_FIRED_BEFORE(trigdata->tg_event) || !TRIGGER_FIRED_FOR_ROW(trigdata->tg_event))
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: must be a BEFORE ... FOR EACH ROW trigger");

	if (TRIGGER_FIRED_BY_INSERT(trigdata->tg_event))
		tuple = trigdata->tg_trigtuple;
	else if (TRIGGER_FIRED_BY_UPDATE(trigdata->tg_event))
		tuple = trigdata->tg_newtuple;
	else
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: must be fired by INSERT or UPDATE");

	tupdesc = trigdata->tg_relation->rd_att;

	datnameDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_DATNAME, tupdesc, &isnull);
	if (isnull)
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: datname is null");
	datname = DatumGetName(datnameDatum);

	searchWorkMemDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_SEARCH_WORK_MEM, tupdesc, &isnull);
	resolvedMb = isnull ? vamana_default_search_work_mem_mb : DatumGetInt32(searchWorkMemDatum);

	LockRelationOid(trigdata->tg_relation->rd_id, ShareRowExclusiveLock);

	qualifiedName = SvsDatabasesQualifiedName();
	if (qualifiedName == NULL)
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: vamana_databases not found in search path");

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: SPI_connect failed");

	paramValues[0] = datnameDatum;

	if (SPI_execute_with_args(psprintf("SELECT COALESCE(SUM(COALESCE(search_work_mem, %d)), 0) FROM %s WHERE datname <> $1",
										vamana_default_search_work_mem_mb, qualifiedName),
							   1, paramTypes, paramValues, NULL, true, 0) != SPI_OK_SELECT ||
		SPI_processed != 1)
		elog(ERROR, "vamana_databases_check_search_work_mem_ceiling: sum query failed");

	otherRowsSumMb = DatumGetInt64(SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &sumIsNull));
	Assert(!sumIsNull);

	SPI_finish();

	projectedTotalMb = otherRowsSumMb + (uint64) resolvedMb;

	if (projectedTotalMb > (uint64) vamana_max_search_work_mem_mb)
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("setting \"%s\".search_work_mem would exceed svs.max_search_work_mem",
						NameStr(*datname)),
				 errdetail("Every database's resolved search_work_mem would sum to %llu MB, over the %d MB ceiling.",
						   (unsigned long long) projectedTotalMb, vamana_max_search_work_mem_mb)));

	return PointerGetDatum(tuple);
}

/*
 * BEFORE DELETE trigger: reject removing a database's row while vamana indexes
 * still exist in it, so the on-disk save directories and replication slots are
 * never orphaned by deleting the row before running svs_teardown_database().
 *
 * The index count lives in the target database's shmem slot, readable from any
 * database, so no cross-database query is needed.  Two limitations follow from
 * reading that counter rather than the target's catalog directly:
 *
 *   - A database with no reserved slot reads as zero regardless of its actual
 *     indexes.  Closed at the source by hard-failing CREATE INDEX in an
 *     unconfigured database.
 *
 *   - The read is best-effort at DELETE time, not serialized against the target
 *     database: a concurrent CREATE INDEX there can commit between this check
 *     and the DELETE.  Closing that would require cross-database locking, which
 *     this design avoids.
 */
PGDLLEXPORT PG_FUNCTION_INFO_V1(vamana_databases_reject_delete_with_live_indexes);
Datum
vamana_databases_reject_delete_with_live_indexes(PG_FUNCTION_ARGS)
{
	TriggerData *trigdata = (TriggerData *) fcinfo->context;
	TupleDesc	tupdesc;
	bool		isnull;
	Datum		datnameDatum;
	Name		datname;
	Oid			dbOid;
	uint32		indexCount;

	if (!CALLED_AS_TRIGGER(fcinfo))
		elog(ERROR, "vamana_databases_reject_delete_with_live_indexes: not called by trigger manager");

	if (!TRIGGER_FIRED_BEFORE(trigdata->tg_event) ||
		!TRIGGER_FIRED_FOR_ROW(trigdata->tg_event) ||
		!TRIGGER_FIRED_BY_DELETE(trigdata->tg_event))
		elog(ERROR, "vamana_databases_reject_delete_with_live_indexes: must be a BEFORE DELETE FOR EACH ROW trigger");

	tupdesc = trigdata->tg_relation->rd_att;
	datnameDatum = heap_getattr(trigdata->tg_trigtuple,
								VAMANA_DATABASES_ATTNUM_DATNAME,
								tupdesc, &isnull);
	if (isnull)
		elog(ERROR, "vamana_databases_reject_delete_with_live_indexes: datname is null");
	datname = DatumGetName(datnameDatum);

	/*
	 * DROP DATABASE without first removing the row is a reachable sequence: if
	 * the database is already gone it holds no indexes, so allow the DELETE.
	 */
	dbOid = get_database_oid(NameStr(*datname), true);
	if (!OidIsValid(dbOid))
		return PointerGetDatum(trigdata->tg_trigtuple);

	/*
	 * Snapshot rather than a bare lookup: this read decides whether the row may
	 * go, and a count read through an entry that has since been re-reserved would
	 * be another database's.  Its own database's count can still change after the
	 * read -- the second limitation above.
	 */
	(void) VamanaWorkerIndexCountSnapshot(dbOid, &indexCount);

	if (indexCount > 0)
		ereport(ERROR,
				(errcode(ERRCODE_DEPENDENT_OBJECTS_STILL_EXIST),
				 errmsg("cannot remove \"%s\" from vamana_databases: "
						"%u vamana index(es) still exist in that database",
						NameStr(*datname), indexCount),
				 errhint("run svs_teardown_database() in \"%s\" first",
						 NameStr(*datname))));

	return PointerGetDatum(trigdata->tg_trigtuple);
}

static void
EnsureReservationCallbacksRegistered(void)
{
	if (!ReservationCallbacksRegistered)
	{
		RegisterXactCallback(VamanaDatabasesXactCallback, NULL);
		RegisterSubXactCallback(VamanaDatabasesSubXactCallback, NULL);
		ReservationCallbacksRegistered = true;
		elog(DEBUG1, "vamana_databases: registered reservation xact callbacks");
	}
}

static void
VamanaDatabasesXactCallback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_PRE_COMMIT:
		case XACT_EVENT_PARALLEL_PRE_COMMIT:
			ReserveSlotsForEnabledEntries();
			break;

		case XACT_EVENT_COMMIT:
		case XACT_EVENT_PARALLEL_COMMIT:
			ReservedThisXactDbOids = NIL;
			ResidencyBudgetSnapshotsThisXact = NIL;
			CurrentReservationQueue = NULL;
			break;

		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			ReleaseSlotsReservedThisXact();
			RestoreResidencyBudgetSnapshotsThisXact();
			CurrentReservationQueue = NULL;
			break;

		/*
		 * No PRE_COMMIT fires for a prepared transaction, so nothing was
		 * reserved; drop the queue with the TopTransactionContext it lives in,
		 * or the next transaction in this backend appends into freed memory.
		 */
		case XACT_EVENT_PREPARE:
			CurrentReservationQueue = NULL;
			break;

		default:
			break;
	}
}

/*
 * A ROLLBACK TO SAVEPOINT must not leave that subtransaction's queued rows
 * eligible for reservation at top-level COMMIT. Entries carry their subxid
 * rather than being removed on rollback, so this can mark them discarded
 * without the bookkeeping of compacting the array mid-transaction.
 */
static void
VamanaDatabasesSubXactCallback(SubXactEvent event, SubTransactionId mySubid,
								SubTransactionId parentSubid, void *arg)
{
	if (CurrentReservationQueue == NULL)
		return;

	if (event == SUBXACT_EVENT_ABORT_SUB)
		VamanaSubxidPendingArrayPruneAbortedSubxact(CurrentReservationQueue, mySubid);
	else if (event == SUBXACT_EVENT_COMMIT_SUB)
		VamanaSubxidPendingArrayReparentSubxact(CurrentReservationQueue, mySubid, parentSubid);
}

/*
 * Reserve a shmem slot for every queued enabled=true entry, before this
 * transaction's row becomes visible to any other backend.
 */
static void
ReserveSlotsForEnabledEntries(void)
{
	VamanaSubxidPendingArray *queue = CurrentReservationQueue;
	MemoryContext oldContext;

	if (queue == NULL)
		return;

	oldContext = MemoryContextSwitchTo(TopTransactionContext);

	for (int i = 0; i < queue->count; i++)
	{
		VamanaDatabasesReservationEntry *entry = VamanaSubxidPendingArrayEntryAt(queue, i);
		VamanaWorkerShmem *slotEntry;
		bool		created;
		uint64		residencyBudget;

		if (!entry->enabled || entry->subxid == InvalidSubTransactionId)
			continue;

		slotEntry = VamanaWorkerReserveSlot(entry->dbOid, &created);
		if (slotEntry == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
					 errmsg("cannot enable database \"%s\": svs.max_databases (%d) already reached",
							NameStr(entry->datname), max_vamana_databases),
					 errhint("Increase svs.max_databases and restart, or disable another database first.")));

		/* A pre-existing live slot found by this idempotent reservation must survive this transaction's abort. */
		if (created)
			ReservedThisXactDbOids = lappend_oid(ReservedThisXactDbOids, entry->dbOid);
		else if (!list_member_oid(ReservedThisXactDbOids, entry->dbOid) &&
				 !ResidencyBudgetAlreadySnapshotted(entry->dbOid))
		{
			ResidencyBudgetSnapshot *snapshot = palloc(sizeof(ResidencyBudgetSnapshot));

			snapshot->dbOid = entry->dbOid;
			snapshot->priorBudget = slotEntry->residencyBudget;
			ResidencyBudgetSnapshotsThisXact = lappend(ResidencyBudgetSnapshotsThisXact, snapshot);
		}

		/* A too-small budget fails this INSERT/UPDATE here, in the same transaction, not a later load. */
		VamanaWorkerSetMemoryOverrides(entry->dbOid, entry->residencyMemoryMbOverride,
										entry->searchWorkMemMbOverride);

		residencyBudget = SvsMemoryResolveResidencyBudget(slotEntry);
		SvsMemoryAdmitDatabase(entry->dbOid, residencyBudget, entry->durableResidencyFloorBytes);
	}

	MemoryContextSwitchTo(oldContext);
}

/*
 * Undo this transaction's own reservations on abort.  No queued slot drop can be
 * lost here, unlike the launcher's release: a drop is only ever handed off at
 * commit, and these entries were reserved by the transaction now aborting.
 */
static void
ReleaseSlotsReservedThisXact(void)
{
	foreach_oid(dbOid, ReservedThisXactDbOids)
		VamanaWorkerReleaseSlot(dbOid);

	ReservedThisXactDbOids = NIL;
}

static void
RestoreResidencyBudgetSnapshotsThisXact(void)
{
	ListCell   *lc;

	foreach(lc, ResidencyBudgetSnapshotsThisXact)
	{
		ResidencyBudgetSnapshot *snapshot = (ResidencyBudgetSnapshot *) lfirst(lc);

		SvsMemoryRestoreResidencyBudget(snapshot->dbOid, snapshot->priorBudget);
	}

	ResidencyBudgetSnapshotsThisXact = NIL;
}

/* -----------------------------------------------------------------------
 * Table reads (SPI)
 * ----------------------------------------------------------------------- */

char *
SvsExtensionQualifiedRelationName(const char *relname)
{
	Oid			extOid = get_extension_oid("svs", true);
	Oid			nspOid;

	if (!OidIsValid(extOid))
		return NULL;

	nspOid = get_extension_schema(extOid);
	if (!OidIsValid(get_relname_relid(relname, nspOid)))
		return NULL;

	return psprintf("%s.%s", quote_identifier(get_namespace_name(nspOid)),
					quote_identifier(relname));
}

char *
SvsDatabasesQualifiedName(void)
{
	return SvsExtensionQualifiedRelationName("vamana_databases");
}

int32
SvsResolveNullableThreadCount(bool isNull, int32 value)
{
	return isNull ? -1 : value;
}

int32
SvsDatabasesGetMyMaintenanceNumThreads(void)
{
	char	   *qualifiedName = SvsDatabasesQualifiedName();
	int32		result = -1;

	if (qualifiedName == NULL)
		return -1;

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "SvsDatabasesGetMyMaintenanceNumThreads: SPI_connect failed");

	if (SPI_execute(psprintf("SELECT maintenance_num_threads FROM %s "
							 "WHERE datname = current_database()",
							 qualifiedName),
					 true, 0) == SPI_OK_SELECT && SPI_processed == 1)
	{
		bool		isNull;
		int32		value = DatumGetInt32(SPI_getbinval(SPI_tuptable->vals[0],
														SPI_tuptable->tupdesc,
														1, &isNull));

		result = SvsResolveNullableThreadCount(isNull, value);
	}

	SPI_finish();

	return result;
}
