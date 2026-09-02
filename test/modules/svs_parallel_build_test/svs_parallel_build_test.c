/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_parallel_build_test.c
 *
 * SQL-callable driver for SvsLaunchParkedBuildWorkers() and
 * SvsStopParkedBuildWorkers(), exercised standalone in
 * test/sql/svs_parallel_build_test.sql with no launcher or svs
 * extension involved.
 *
 * A ParallelContext's dynamic shared memory segment belongs to the resource
 * owner active when it was created, which for a SQL-callable function is
 * the calling statement's portal, not the enclosing transaction: it does
 * not survive past the end of that statement.  So the whole launch/verify/
 * stop cycle runs inside a single call here, matching how a real build
 * (one CREATE INDEX statement) will use it.
 *
 * This module proves the pool mechanics only (launch/attach/stop), not the
 * self-description naming SvsLaunchParkedBuildWorkers also sets up -- that
 * needs a query from a genuinely separate session to observe reliably (see
 * test/t/19_build_thread_grant.pl), not a self-check from the same backend
 * that is still IsInParallelMode() for the pool it just created.
 */

#include "postgres.h"

#include "svs_parallel_build.h"

#include "commands/dbcommands.h"
#include "executor/spi.h"
#include "fmgr.h"
#include "miscadmin.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(svs_parallel_build_test_run);

/*
 * Returns the number of workers actually parked, after confirming that many
 * are independently visible as this backend's parallel workers in
 * pg_stat_activity.
 */
static int64
CountVisibleParallelWorkers(void)
{
	int			ret;
	bool		isnull;
	Datum		count;

	SPI_connect();
	ret = SPI_execute("SELECT count(*) FROM pg_stat_activity "
					   "WHERE leader_pid = pg_backend_pid() "
					   "AND backend_type = 'parallel worker'",
					   true, 0);
	if (ret != SPI_OK_SELECT || SPI_processed != 1)
		elog(ERROR, "unexpected result counting parallel workers");

	count = SPI_getbinval(SPI_tuptable->vals[0], SPI_tuptable->tupdesc, 1, &isnull);
	SPI_finish();

	return isnull ? 0 : DatumGetInt64(count);
}

Datum
svs_parallel_build_test_run(PG_FUNCTION_ARGS)
{
	int32		requested = PG_GETARG_INT32(0);
	ParallelContext *pcxt;
	int32		launched;
	int64		visible;

	/*
	 * No real request/grant distinction in this standalone harness, so the
	 * same requested count doubles as both the pool size and the
	 * self-description's "requested" field.
	 */
	pcxt = SvsLaunchParkedBuildWorkers("svs_parallel_build_test", requested,
										get_database_name(MyDatabaseId), requested);
	launched = (pcxt == NULL) ? 0 : pcxt->nworkers_launched;

	visible = (launched == 0) ? 0 : CountVisibleParallelWorkers();

	SvsStopParkedBuildWorkers(pcxt);

	if (visible != launched)
		elog(ERROR, "launched %d parked workers but %lld were visible in pg_stat_activity",
			 launched, (long long) visible);

	PG_RETURN_INT32(launched);
}
