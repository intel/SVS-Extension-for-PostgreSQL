/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_index_residency.c
 *
 * See svs_index_residency.h for the module's contract.
 */

#include "postgres.h"

#include "svs_index_residency.h"
#include "vamana_databases.h"
#include "vamana_subxact_guard.h"
#include "vamanaworker.h"

#include "access/xact.h"
#include "catalog/pg_type.h"
#include "commands/dbcommands.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/builtins.h"

typedef struct RecordLoadArgs
{
	Oid			indexRelid;
	Oid			dbOid;
	uint64		residentBytes;
} RecordLoadArgs;

typedef struct ReconcileOrphansArgs
{
	Oid			dbOid;
	Oid		   *liveRelids;
	int			numLive;
} ReconcileOrphansArgs;

static void
ConnectOrError(const char *callerName)
{
	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "%s: SPI_connect failed", callerName);
}

/*
 * Row-lock dbOid's vamana_databases entry, serializing against a concurrent
 * writer of its durable residency total. Skipped on a standby: there is no
 * local writer to serialize against there. Caller must already hold an SPI
 * connection.
 */
static void
LockDatabaseRow(const char *datname)
{
	char	   *qualifiedName;
	Oid			argTypes[1] = {NAMEOID};
	Datum		argValues[1];
	NameData	nameArg;

	if (RecoveryInProgress())
		return;

	qualifiedName = SvsExtensionQualifiedRelationName("vamana_databases");
	if (qualifiedName == NULL)
		return;

	namestrcpy(&nameArg, datname);
	argValues[0] = NameGetDatum(&nameArg);

	SPI_execute_with_args(psprintf("SELECT 1 FROM %s WHERE datname = $1 FOR UPDATE", qualifiedName),
						   1, argTypes, argValues, NULL, false, 0);
}

static void
RecordLoadBody(void *arg)
{
	RecordLoadArgs *args = (RecordLoadArgs *) arg;
	char	   *qualifiedName = SvsExtensionQualifiedRelationName("svs_index_residency");
	char	   *datname = get_database_name(args->dbOid);
	Oid			argTypes[3] = {OIDOID, OIDOID, INT8OID};
	Datum		argValues[3];

	if (qualifiedName == NULL || datname == NULL)
		return;

	argValues[0] = ObjectIdGetDatum(args->indexRelid);
	argValues[1] = ObjectIdGetDatum(args->dbOid);
	argValues[2] = Int64GetDatum((int64) args->residentBytes);

	ConnectOrError("SvsIndexResidencyRecordLoad");
	LockDatabaseRow(datname);
	SPI_execute_with_args(psprintf("INSERT INTO %s (index_relid, db_oid, resident_bytes) "
									"VALUES ($1, $2, $3) "
									"ON CONFLICT (index_relid) DO UPDATE SET "
									"db_oid = EXCLUDED.db_oid, resident_bytes = EXCLUDED.resident_bytes",
									qualifiedName),
						   3, argTypes, argValues, NULL, false, 0);
	SPI_finish();
}

void
SvsIndexResidencyRecordLoad(Oid indexRelid, Oid dbOid, uint64 residentBytes)
{
	RecordLoadArgs args = {indexRelid, dbOid, residentBytes};
	VamanaSubXactResult result;

	if (!IsTransactionState() || RecoveryInProgress())
		return;

	result = VamanaRunInSubXact(RecordLoadBody, &args, NULL);

	if (result.succeeded)
		return;

	FreeErrorData(result.edata);
	ereport(LOG,
			(errmsg("vamana index %u: could not record residency durably; "
					"will retry at the next load or unload", indexRelid)));
}

static void
RecordUnloadBody(void *arg)
{
	Oid			indexRelid = *(Oid *) arg;
	char	   *qualifiedName = SvsExtensionQualifiedRelationName("svs_index_residency");
	char	   *datname = get_database_name(MyDatabaseId);
	Oid			argTypes[1] = {OIDOID};
	Datum		argValues[1];

	if (qualifiedName == NULL || datname == NULL)
		return;

	argValues[0] = ObjectIdGetDatum(indexRelid);

	ConnectOrError("SvsIndexResidencyRecordUnload");
	LockDatabaseRow(datname);
	SPI_execute_with_args(psprintf("DELETE FROM %s WHERE index_relid = $1", qualifiedName),
						   1, argTypes, argValues, NULL, false, 0);
	SPI_finish();
}

void
SvsIndexResidencyRecordUnload(Oid indexRelid)
{
	VamanaSubXactResult result;

	if (!IsTransactionState() || RecoveryInProgress())
		return;

	result = VamanaRunInSubXact(RecordUnloadBody, &indexRelid, NULL);

	if (result.succeeded)
		return;

	FreeErrorData(result.edata);
	ereport(LOG,
			(errmsg("vamana index %u: could not remove durable residency record; "
					"will be corrected at the next load or unload", indexRelid)));
}

static void
ReconcileOrphansBody(void *arg)
{
	ReconcileOrphansArgs *args = (ReconcileOrphansArgs *) arg;
	char	   *qualifiedName = SvsExtensionQualifiedRelationName("svs_index_residency");
	char	   *datname = get_database_name(args->dbOid);
	Datum	   *elems;
	ArrayType  *liveArray;
	Oid			argTypes[2] = {OIDOID, OIDARRAYOID};
	Datum		argValues[2];

	if (qualifiedName == NULL || datname == NULL)
		return;

	elems = (Datum *) palloc(sizeof(Datum) * args->numLive);
	for (int i = 0; i < args->numLive; i++)
		elems[i] = ObjectIdGetDatum(args->liveRelids[i]);
	liveArray = construct_array(elems, args->numLive, OIDOID,
								 sizeof(Oid), true, TYPALIGN_INT);

	argValues[0] = ObjectIdGetDatum(args->dbOid);
	argValues[1] = PointerGetDatum(liveArray);

	ConnectOrError("SvsIndexResidencyReconcileOrphans");
	LockDatabaseRow(datname);
	SPI_execute_with_args(psprintf("DELETE FROM %s WHERE db_oid = $1 AND index_relid <> ALL($2)",
									qualifiedName),
						   2, argTypes, argValues, NULL, false, 0);
	SPI_finish();
}

/*
 * Sweep every durable row for dbOid whose index_relid is not in liveRelids,
 * the complete set of vamana indexes the catalog currently reports for this
 * database. A row survives here only as long as some catalog access, load,
 * or unload eventually revisits it -- this pass exists so a row orphaned by
 * a path that skips that revisit (a dropped index whose paired durable
 * delete never ran) does not survive forever.
 *
 * numLive == 0 is refused rather than treated as "nothing is live": the
 * enumeration this relies on returns the same empty result on a genuine
 * empty database and on its own SPI failure, and this sweep can only ever
 * narrow the durable floor, never raise it. Proceeding on an empty set it
 * cannot trust would risk deleting every row for a database that still has
 * resident indexes, understating the floor in the one direction that lets
 * through a residency_memory decrease a resident graph cannot survive. A
 * database with no orphans and no live indexes leaves nothing to clean
 * either way.
 *
 * Best-effort like the two functions above: a failure here must not prevent
 * the worker from starting, so it is caught, logged, and left for the next
 * startup rather than propagated.
 */
void
SvsIndexResidencyReconcileOrphans(Oid dbOid, Oid *liveRelids, int numLive)
{
	ReconcileOrphansArgs args = {dbOid, liveRelids, numLive};
	VamanaSubXactResult result;

	if (numLive == 0)
		return;

	if (!IsTransactionState() || RecoveryInProgress())
		return;

	result = VamanaRunInSubXact(ReconcileOrphansBody, &args, NULL);

	if (result.succeeded)
		return;

	FreeErrorData(result.edata);
	ereport(LOG,
			(errmsg("vamana database %u: could not reconcile orphaned residency records; "
					"will retry at the next worker startup", dbOid)));
}

static uint64
SumCommittedBytes(Oid dbOid)
{
	char	   *qualifiedName = SvsExtensionQualifiedRelationName("svs_index_residency");
	Oid			argTypes[1] = {OIDOID};
	Datum		argValues[1] = {ObjectIdGetDatum(dbOid)};
	int			ret;
	uint64		sum = 0;

	if (qualifiedName == NULL)
		return 0;

	/* SUM(bigint) is numeric, not int8; cast explicitly so SPI_getbinval's result matches the INT8OID read below. */
	ret = SPI_execute_with_args(psprintf("SELECT COALESCE(SUM(resident_bytes), 0)::int8 FROM %s WHERE db_oid = $1",
										  qualifiedName),
								 1, argTypes, argValues, NULL, true, 0);

	if (ret == SPI_OK_SELECT && SPI_processed == 1)
	{
		bool		isNull;
		Datum		sumDatum = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc,
											  1, &isNull);

		if (!isNull)
			sum = (uint64) DatumGetInt64(sumDatum);
	}

	return sum;
}

uint64
SvsIndexResidencyDurableFloor(Oid dbOid, struct VamanaWorkerShmem *entry)
{
	char	   *datname;
	uint64		floor;

	/* No reserved slot at all is not live either -- nothing can have loaded anything. */
	if (entry != NULL && VamanaWorkerEntryIsLive(entry))
		return 0;

	datname = get_database_name(dbOid);
	if (datname == NULL)
		return 0;

	ConnectOrError("SvsIndexResidencyDurableFloor");
	LockDatabaseRow(datname);
	floor = SumCommittedBytes(dbOid);
	SPI_finish();

	return floor;
}
