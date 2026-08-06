/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_teardown.c
 *
 * svs_teardown_database(): drop every vamana index in the current database,
 * one per subtransaction so an unowned or otherwise undroppable index yields
 * a per-index reason instead of aborting the whole call.  This automates the
 * index-by-index DROP INDEX a DBA would otherwise run by hand before removing
 * the database's row from vamana_databases; the on-disk save-directory and
 * replication-slot cleanup happens through the existing OAT_DROP hook that a
 * manual DROP INDEX already fires.
 *
 * Deliberately not SECURITY DEFINER: routing each drop through SPI subjects it
 * to the caller's own ownership check, exactly as a manual DROP INDEX loop is.
 */

#include "postgres.h"

#include "vamanaworker.h"

#include "access/xact.h"
#include "executor/spi.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"

/* Result-set columns of svs_teardown_database(), in declaration order. */
#define TEARDOWN_COL_INDEX_RELID	0
#define TEARDOWN_COL_INDEX_NAME		1
#define TEARDOWN_COL_DROPPED		2
#define TEARDOWN_COL_REASON			3
#define TEARDOWN_NCOLS				4

/*
 * One enumerated index awaiting drop.  qualifiedName is the schema-qualified,
 * quoted identifier handed straight to DROP INDEX, and is allocated in the
 * SRF's per-query context so it survives the drop loop's subtransaction
 * context swaps.
 */
typedef struct TeardownTarget
{
	Oid			indexRelid;
	char	   *qualifiedName;
} TeardownTarget;

/*
 * Drain the enumeration fully before any DROP: the per-index DROP's SPI call
 * clobbers SPI_tuptable, so OIDs and names must be copied out first.  The
 * returned array and its strings are allocated in resultCtx.
 */
static TeardownTarget *
EnumerateVamanaIndexes(MemoryContext resultCtx, int *nout)
{
	TeardownTarget *targets;
	uint64		nrows;
	MemoryContext oldCtx;

	if (SPI_connect() != SPI_OK_CONNECT)
		elog(ERROR, "svs_teardown_database: SPI_connect failed");

	if (SPI_execute(VAMANA_ENUM_INDEXES_IN_DB_SQL, true, 0) != SPI_OK_SELECT)
		elog(ERROR, "svs_teardown_database: failed to enumerate vamana indexes");

	nrows = SPI_processed;

	oldCtx = MemoryContextSwitchTo(resultCtx);
	targets = (nrows > 0) ? palloc(nrows * sizeof(TeardownTarget)) : NULL;

	for (uint64 i = 0; i < nrows; i++)
	{
		bool		isnull;
		Oid			relid = DatumGetObjectId(SPI_getbinval(SPI_tuptable->vals[i],
														   SPI_tuptable->tupdesc,
														   1, &isnull));

		Assert(!isnull);
		targets[i].indexRelid = relid;
		targets[i].qualifiedName =
			quote_qualified_identifier(get_namespace_name(get_rel_namespace(relid)),
									   get_rel_name(relid));
	}
	MemoryContextSwitchTo(oldCtx);

	SPI_finish();				/* releases the enumeration's tuptable */

	*nout = (int) nrows;
	return targets;
}

/*
 * Drop one index inside its own subtransaction.  Returns true on success
 * (*reason = NULL); on a caught error returns false with *reason copied into
 * resultCtx (ownership failure, concurrent drop, etc.), leaving the outer
 * transaction alive so the caller can continue with the next index.
 *
 * The subtransaction scaffolding mirrors ReplayChangeGuarded() in
 * vamana_replication.c; the difference is disposition: this captures the error
 * text for the result set rather than logging and discarding it.
 */
static bool
TryDropIndex(const TeardownTarget *target, MemoryContext resultCtx, char **reason)
{
	MemoryContext oldCtx = CurrentMemoryContext;
	ResourceOwner oldOwner = CurrentResourceOwner;
	StringInfoData cmd;

	initStringInfo(&cmd);
	appendStringInfo(&cmd, "DROP INDEX %s", target->qualifiedName);

	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(oldCtx);

	PG_TRY();
	{
		if (SPI_connect() != SPI_OK_CONNECT)
			elog(ERROR, "svs_teardown_database: SPI_connect failed");
		if (SPI_execute(cmd.data, false, 0) != SPI_OK_UTILITY)
			elog(ERROR, "svs_teardown_database: DROP INDEX %s failed",
				 target->qualifiedName);
		SPI_finish();

		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldCtx);
		CurrentResourceOwner = oldOwner;

		*reason = NULL;
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		MemoryContextSwitchTo(oldCtx);
		edata = CopyErrorData();

		MemoryContextSwitchTo(resultCtx);
		*reason = pstrdup(edata->message);

		FreeErrorData(edata);
		FlushErrorState();

		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldCtx);
		CurrentResourceOwner = oldOwner;
	}
	PG_END_TRY();

	pfree(cmd.data);
	return (*reason == NULL);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_teardown_database);
Datum
svs_teardown_database(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	MemoryContext resultCtx;
	TeardownTarget *targets;
	int			ntargets;

	InitMaterializedSRF(fcinfo, 0);
	resultCtx = rsinfo->econtext->ecxt_per_query_memory;

	targets = EnumerateVamanaIndexes(resultCtx, &ntargets);

	for (int i = 0; i < ntargets; i++)
	{
		Datum		values[TEARDOWN_NCOLS];
		bool		nulls[TEARDOWN_NCOLS];
		char	   *reason;
		bool		dropped = TryDropIndex(&targets[i], resultCtx, &reason);

		if (!dropped)
			ereport(WARNING,
					(errmsg("svs_teardown_database: could not drop index %s: %s",
							targets[i].qualifiedName, reason)));

		memset(nulls, 0, sizeof(nulls));
		values[TEARDOWN_COL_INDEX_RELID] = ObjectIdGetDatum(targets[i].indexRelid);
		values[TEARDOWN_COL_INDEX_NAME] = CStringGetTextDatum(targets[i].qualifiedName);
		values[TEARDOWN_COL_DROPPED] = BoolGetDatum(dropped);
		if (dropped)
			nulls[TEARDOWN_COL_REASON] = true;
		else
			values[TEARDOWN_COL_REASON] = CStringGetTextDatum(reason);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}
