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

#include "vamana_databases.h"
#include "vamanaworker.h"

#include "access/htup_details.h"
#include "access/xact.h"
#include "commands/dbcommands.h"
#include "commands/trigger.h"
#include "utils/builtins.h"
#include "utils/memutils.h"
#include "utils/rel.h"

/* Column positions in vamana_databases, matching the CREATE TABLE order. */
#define VAMANA_DATABASES_ATTNUM_DATNAME		1
#define VAMANA_DATABASES_ATTNUM_ENABLED		2

#define VAMANA_DATABASES_QUEUE_INITIAL_CAPACITY	16

/* Reset to NULL at transaction end, alongside TopTransactionContext. */
static VamanaDatabasesReservationList *CurrentReservationQueue = NULL;

/* dbOids reserved by this transaction; released on ABORT. TopTransactionContext-scoped. */
static List *ReservedThisXactDbOids = NIL;

static bool ReservationCallbacksRegistered = false;

static void EnsureReservationCallbacksRegistered(void);
static void VamanaDatabasesXactCallback(XactEvent event, void *arg);
static void VamanaDatabasesSubXactCallback(SubXactEvent event,
											SubTransactionId mySubid,
											SubTransactionId parentSubid,
											void *arg);
static void ReserveSlotsForEnabledEntries(void);
static void ReleaseSlotsReservedThisXact(void);

static VamanaDatabasesReservationList *
GetOrCreateReservationQueue(void)
{
	if (CurrentReservationQueue == NULL)
	{
		MemoryContext oldContext = MemoryContextSwitchTo(TopTransactionContext);

		CurrentReservationQueue = palloc0(sizeof(VamanaDatabasesReservationList));
		CurrentReservationQueue->capacity = VAMANA_DATABASES_QUEUE_INITIAL_CAPACITY;
		CurrentReservationQueue->entries =
			palloc(CurrentReservationQueue->capacity * sizeof(VamanaDatabasesReservationEntry));
		MemoryContextSwitchTo(oldContext);
	}
	return CurrentReservationQueue;
}

static void
QueueReservationEntry(Name datname, Oid dbOid, bool enabled)
{
	VamanaDatabasesReservationList *queue = GetOrCreateReservationQueue();
	VamanaDatabasesReservationEntry *entry;

	if (queue->count >= queue->capacity)
	{
		MemoryContext oldContext = MemoryContextSwitchTo(TopTransactionContext);

		queue->capacity *= 2;
		queue->entries = repalloc(queue->entries,
								   queue->capacity * sizeof(VamanaDatabasesReservationEntry));
		MemoryContextSwitchTo(oldContext);
	}

	entry = &queue->entries[queue->count++];
	namestrcpy(&entry->datname, NameStr(*datname));
	entry->dbOid = dbOid;
	entry->enabled = enabled;
	entry->subxid = GetCurrentSubTransactionId();
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
	Name		datname;
	Oid			dbOid;

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
	Assert(!isnull);			/* datname is the primary key, NOT NULL */
	datname = DatumGetName(datnameDatum);

	enabledDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_ENABLED, tupdesc, &isnull);
	Assert(!isnull);			/* enabled is NOT NULL */

	dbOid = get_database_oid(NameStr(*datname), false);

	QueueReservationEntry(datname, dbOid, DatumGetBool(enabledDatum));

	return PointerGetDatum(NULL);	/* AFTER trigger; return value is ignored */
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
			CurrentReservationQueue = NULL;
			break;

		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			ReleaseSlotsReservedThisXact();
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
	VamanaDatabasesReservationList *queue = CurrentReservationQueue;

	if (event != SUBXACT_EVENT_ABORT_SUB || queue == NULL)
		return;

	for (int i = 0; i < queue->count; i++)
	{
		if (queue->entries[i].subxid == mySubid)
			queue->entries[i].subxid = InvalidSubTransactionId;
	}
}

/*
 * Reserve a shmem slot for every queued enabled=true entry, before this
 * transaction's row becomes visible to any other backend.
 */
static void
ReserveSlotsForEnabledEntries(void)
{
	VamanaDatabasesReservationList *queue = CurrentReservationQueue;
	MemoryContext oldContext;

	if (queue == NULL)
		return;

	oldContext = MemoryContextSwitchTo(TopTransactionContext);

	for (int i = 0; i < queue->count; i++)
	{
		VamanaDatabasesReservationEntry *entry = &queue->entries[i];

		if (!entry->enabled || entry->subxid == InvalidSubTransactionId)
			continue;

		if (VamanaWorkerReserveSlot(entry->dbOid) == NULL)
			ereport(ERROR,
					(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
					 errmsg("cannot enable database \"%s\": max_vamana_databases (%d) already reached",
							NameStr(entry->datname), max_vamana_databases),
					 errhint("increase max_vamana_databases and restart, or disable another database first")));

		ReservedThisXactDbOids = lappend_oid(ReservedThisXactDbOids, entry->dbOid);
	}

	MemoryContextSwitchTo(oldContext);
}

static void
ReleaseSlotsReservedThisXact(void)
{
	foreach_oid(dbOid, ReservedThisXactDbOids)
		VamanaWorkerReleaseSlot(dbOid);

	ReservedThisXactDbOids = NIL;
}
