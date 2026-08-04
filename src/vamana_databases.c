/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_databases.c
 *
 * Row-level AFTER INSERT OR UPDATE trigger on vamana_databases. Queues
 * (datname, enabled) for each affected row into a backend-local list;
 * does not reserve shmem or register any xact callback itself.
 */

#include "postgres.h"

#include "vamana_databases.h"

#include "access/htup_details.h"
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
QueueReservationEntry(Name datname, bool enabled)
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
	entry->enabled = enabled;
}

VamanaDatabasesReservationList *
VamanaDatabasesReservationQueue(void)
{
	return CurrentReservationQueue;
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

	tupdesc = trigdata->tg_relation->rd_att;

	datnameDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_DATNAME, tupdesc, &isnull);
	Assert(!isnull);			/* datname is the primary key, NOT NULL */

	enabledDatum = heap_getattr(tuple, VAMANA_DATABASES_ATTNUM_ENABLED, tupdesc, &isnull);
	Assert(!isnull);			/* enabled is NOT NULL */

	QueueReservationEntry(DatumGetName(datnameDatum), DatumGetBool(enabledDatum));

	return PointerGetDatum(NULL);	/* AFTER trigger; return value is ignored */
}
