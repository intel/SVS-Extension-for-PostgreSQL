/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cpu_budget_test.c
 *
 * SQL-callable driver for svs_cpu_budget's SvsComputeCpuGrants, so pg_regress
 * can assert on its output.  Not part of the svs extension; never installed
 * alongside it.
 */

#include "postgres.h"

#include "funcapi.h"
#include "utils/array.h"
#include "utils/builtins.h"

#include "svs_cpu_budget.h"

PG_MODULE_MAGIC;

#define SVS_CPU_BUDGET_TEST_COLS 7

static int32 *
DeconstructInt4Array(ArrayType *arr, int *nelems)
{
	Datum	   *elems;
	bool	   *nulls;
	int			n;
	int32	   *out;
	int			i;

	deconstruct_array(arr, INT4OID, sizeof(int32), true, TYPALIGN_INT,
					   &elems, &nulls, &n);
	out = palloc(sizeof(int32) * n);
	for (i = 0; i < n; i++)
	{
		if (nulls[i])
			ereport(ERROR, (errmsg("array elements must not be NULL")));
		out[i] = DatumGetInt32(elems[i]);
	}
	*nelems = n;
	return out;
}

static Oid *
DeconstructOidArray(ArrayType *arr, int *nelems)
{
	Datum	   *elems;
	bool	   *nulls;
	int			n;
	Oid		   *out;
	int			i;

	deconstruct_array(arr, OIDOID, sizeof(Oid), true, TYPALIGN_INT,
					   &elems, &nulls, &n);
	out = palloc(sizeof(Oid) * n);
	for (i = 0; i < n; i++)
	{
		if (nulls[i])
			ereport(ERROR, (errmsg("array elements must not be NULL")));
		out[i] = DatumGetObjectId(elems[i]);
	}
	*nelems = n;
	return out;
}

static bool *
DeconstructBoolArray(ArrayType *arr, int *nelems)
{
	Datum	   *elems;
	bool	   *nulls;
	int			n;
	bool	   *out;
	int			i;

	deconstruct_array(arr, BOOLOID, sizeof(bool), true, TYPALIGN_CHAR,
					   &elems, &nulls, &n);
	out = palloc(sizeof(bool) * n);
	for (i = 0; i < n; i++)
	{
		if (nulls[i])
			ereport(ERROR, (errmsg("array elements must not be NULL")));
		out[i] = DatumGetBool(elems[i]);
	}
	*nelems = n;
	return out;
}

static void
CheckSameLength(int expected, int actual, const char *argName)
{
	if (expected != actual)
		ereport(ERROR,
				(errmsg("%s has length %d, expected %d to match the other db/build arrays",
						argName, actual, expected)));
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_cpu_budget_test);
Datum
svs_cpu_budget_test(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	SvsCpuGucs	gucs;
	SvsCpuBudgetInput input;
	SvsCpuBudget *budget;
	SvsDbCpuRequest *dbs;
	SvsBuildCpuRequest *builds;
	Oid		   *dbOids,
			   *buildDbOids;
	bool	   *dbLive;
	int32	   *dbSearchNumThreads,
			   *dbSearchThreadsReserved,
			   *buildRequestPids,
			   *buildMaintenanceNumThreads;
	int			ndbs,
				nbuilds,
				n;
	int			i;

	InitMaterializedSRF(fcinfo, 0);
	Assert(rsinfo->setDesc->natts == SVS_CPU_BUDGET_TEST_COLS);

	gucs.maxParallelWorkers = PG_GETARG_INT32(0);
	gucs.maxSearchThreadsPerDb = PG_GETARG_INT32(1);
	gucs.maxTotalSearchThreads = PG_GETARG_INT32(2);
	gucs.maxParallelMaintenanceWorkers = PG_GETARG_INT32(3);
	gucs.searchNumThreadsDefault = PG_GETARG_INT32(4);

	dbOids = DeconstructOidArray(PG_GETARG_ARRAYTYPE_P(5), &ndbs);

	dbLive = DeconstructBoolArray(PG_GETARG_ARRAYTYPE_P(6), &n);
	CheckSameLength(ndbs, n, "db_live");

	dbSearchNumThreads = DeconstructInt4Array(PG_GETARG_ARRAYTYPE_P(7), &n);
	CheckSameLength(ndbs, n, "db_search_num_threads");

	dbSearchThreadsReserved = DeconstructInt4Array(PG_GETARG_ARRAYTYPE_P(8), &n);
	CheckSameLength(ndbs, n, "db_search_threads_reserved");

	buildDbOids = DeconstructOidArray(PG_GETARG_ARRAYTYPE_P(9), &nbuilds);

	buildRequestPids = DeconstructInt4Array(PG_GETARG_ARRAYTYPE_P(10), &n);
	CheckSameLength(nbuilds, n, "build_request_pid");

	buildMaintenanceNumThreads = DeconstructInt4Array(PG_GETARG_ARRAYTYPE_P(11), &n);
	CheckSameLength(nbuilds, n, "build_maintenance_num_threads");

	dbs = palloc(sizeof(SvsDbCpuRequest) * ndbs);
	for (i = 0; i < ndbs; i++)
	{
		dbs[i].dbOid = dbOids[i];
		dbs[i].live = dbLive[i];
		dbs[i].searchNumThreads = dbSearchNumThreads[i];
		dbs[i].searchThreadsReserved = dbSearchThreadsReserved[i];
	}

	builds = palloc(sizeof(SvsBuildCpuRequest) * nbuilds);
	for (i = 0; i < nbuilds; i++)
	{
		builds[i].dbOid = buildDbOids[i];
		builds[i].requestPid = buildRequestPids[i];
		builds[i].maintenanceNumThreads = buildMaintenanceNumThreads[i];
	}

	input.gucs = &gucs;
	input.dbs = dbs;
	input.ndbs = ndbs;
	input.builds = builds;
	input.nbuilds = nbuilds;

	budget = SvsComputeCpuGrants(&input, CurrentMemoryContext);

	for (i = 0; i < budget->ndbGrants; i++)
	{
		Datum		values[SVS_CPU_BUDGET_TEST_COLS];
		bool		nulls[SVS_CPU_BUDGET_TEST_COLS];

		memset(nulls, 0, sizeof(nulls));
		values[0] = CStringGetTextDatum("search");
		values[1] = ObjectIdGetDatum(budget->dbGrants[i].dbOid);
		nulls[2] = true;
		values[3] = Int32GetDatum(budget->dbGrants[i].desiredSearchThreads);
		values[4] = Int32GetDatum(budget->dbGrants[i].grantedSearchThreads);
		values[5] = Int32GetDatum(budget->dbGrants[i].reservedSearchThreads);
		values[6] = BoolGetDatum(budget->reservedFloorsExceedPool);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	for (i = 0; i < budget->nbuildGrants; i++)
	{
		Datum		values[SVS_CPU_BUDGET_TEST_COLS];
		bool		nulls[SVS_CPU_BUDGET_TEST_COLS];

		memset(nulls, 0, sizeof(nulls));
		values[0] = CStringGetTextDatum("build");
		values[1] = ObjectIdGetDatum(budget->buildGrants[i].dbOid);
		values[2] = Int32GetDatum(budget->buildGrants[i].requestPid);
		nulls[3] = true;
		values[4] = Int32GetDatum(budget->buildGrants[i].grantedThreads);
		nulls[5] = true;
		values[6] = BoolGetDatum(budget->reservedFloorsExceedPool);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}
