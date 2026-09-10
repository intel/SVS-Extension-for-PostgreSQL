/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_memory_test.c
 *
 * SQL-callable driver for svs_memory's accounting API, so pg_regress can
 * assert on it. Not part of the svs extension; never installed alongside
 * it.
 */

#include "postgres.h"

#include "funcapi.h"
#include "utils/builtins.h"

#include "svs_memory.h"
#include "vamanaworker.h"

PG_MODULE_MAGIC;

static uint64
GetNonNegativeArgAsUint64(PG_FUNCTION_ARGS, int argnum)
{
	int64		value = PG_GETARG_INT64(argnum);

	if (value < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("byte argument %d must not be negative", argnum)));

	return (uint64) value;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_build_ceiling_bytes);
Datum
svs_memory_test_build_ceiling_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) vamana_max_build_memory_mb * 1024 * 1024);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_residency_ceiling_bytes);
Datum
svs_memory_test_residency_ceiling_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) vamana_max_residency_memory_mb * 1024 * 1024);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_global_build_committed_bytes);
Datum
svs_memory_test_global_build_committed_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) VamanaWorkerHeader()->totalBuildCommittedGlobal);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_global_residency_committed_bytes);
Datum
svs_memory_test_global_residency_committed_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) VamanaWorkerHeader()->totalResidencyCommittedGlobal);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_admit_database);
Datum
svs_memory_admit_database(PG_FUNCTION_ARGS)
{
	SvsMemoryAdmitDatabase(PG_GETARG_OID(0), GetNonNegativeArgAsUint64(fcinfo, 1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reserve_build);
Datum
svs_memory_reserve_build(PG_FUNCTION_ARGS)
{
	SvsMemoryReserveBuild(PG_GETARG_OID(0), PG_GETARG_OID(1),
						   GetNonNegativeArgAsUint64(fcinfo, 2),
						   GetNonNegativeArgAsUint64(fcinfo, 3));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_handoff_build);
Datum
svs_memory_handoff_build(PG_FUNCTION_ARGS)
{
	bool		confirmed = SvsMemoryHandoffBuild(PG_GETARG_OID(0), PG_GETARG_OID(1),
												   GetNonNegativeArgAsUint64(fcinfo, 2),
												   GetNonNegativeArgAsUint64(fcinfo, 3));

	PG_RETURN_BOOL(confirmed);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_abort_build);
Datum
svs_memory_abort_build(PG_FUNCTION_ARGS)
{
	SvsMemoryAbortBuild(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reconcile_load);
Datum
svs_memory_reconcile_load(PG_FUNCTION_ARGS)
{
	bool		fits = SvsMemoryReconcileLoad(PG_GETARG_OID(0), PG_GETARG_OID(1),
											  GetNonNegativeArgAsUint64(fcinfo, 2));

	PG_RETURN_BOOL(fits);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_account_unload);
Datum
svs_memory_account_unload(PG_FUNCTION_ARGS)
{
	SvsMemoryAccountUnload(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reserve_insert);
Datum
svs_memory_reserve_insert(PG_FUNCTION_ARGS)
{
	bool		fits = SvsMemoryReserveInsert(PG_GETARG_OID(0), PG_GETARG_OID(1),
											  GetNonNegativeArgAsUint64(fcinfo, 2));

	PG_RETURN_BOOL(fits);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reanchor_insert);
Datum
svs_memory_reanchor_insert(PG_FUNCTION_ARGS)
{
	SvsMemoryReanchorInsert(PG_GETARG_OID(0), PG_GETARG_OID(1),
							 GetNonNegativeArgAsUint64(fcinfo, 2));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reap_dead_reservations);
Datum
svs_memory_reap_dead_reservations(PG_FUNCTION_ARGS)
{
	SvsMemoryReapDeadReservations();
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_read_stats);
Datum
svs_memory_read_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	SvsMemoryStats stats;

	InitMaterializedSRF(fcinfo, 0);

	if (SvsMemoryReadStats(PG_GETARG_OID(0), &stats))
	{
		Datum		values[3];
		bool		nulls[3] = {false, false, false};

		values[0] = Int64GetDatum((int64) stats.residencyBudget);
		values[1] = Int64GetDatum((int64) stats.residencyBytesCommitted);
		values[2] = Int64GetDatum((int64) stats.buildBytesCommitted);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}
