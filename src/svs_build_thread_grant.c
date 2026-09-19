/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_build_thread_grant.c
 *
 * Ties three independent pieces together for one index build: the
 * request/grant protocol against the current database's worker entry
 * (svs_build_request_protocol.c), the parked-worker pool that makes the
 * grant visible to PostgreSQL's own accounting (svs_parallel_build.c), and
 * the catalog value that decides how many threads to ask for
 * (vamana_databases.c).  None of those three files depends on this one or
 * on each other for this purpose; this is the only place that composes
 * them.
 */

#include "postgres.h"

#include "svs_build_thread_grant.h"

#include "svs_build_request_protocol.h"
#include "svs_parallel_build.h"
#include "svs_thread_count.h"
#include "svs_wrapper.h"
#include "vamana_databases.h"
#include "vamanaworker.h"

#include "access/parallel.h"
#include "commands/dbcommands.h"
#include "miscadmin.h"
#include "utils/injection_point.h"

static int32
ResolveRequestedBuildThreads(void)
{
	int32		catalogValue = SvsDatabasesGetMyMaintenanceNumThreads();

	if (catalogValue == -1)
		return SVSDefaultBuildThreads();

	return SvsAtLeastOneThread(catalogValue);
}

void
SvsRunGovernedBuild(SvsGovernedBuildFn buildFn, void *context)
{
	SvsBuildRequest *req;
	SvsBuildGrantOutcome outcome;
	int32		requested = ResolveRequestedBuildThreads();
	int32		granted;
	ParallelContext * volatile pcxt = NULL;

	req = SvsClaimBuildRequestSlot(requested);
	if (req == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
				 errmsg("vamana index build: no free build-thread request slot for this database"),
				 errdetail("All %d pending-build slots are already in use.",
						   SVS_MAX_PENDING_BUILDS),
				 errhint("Wait for another build in this database to finish, then retry.")));

	SvsKickLauncher();
	outcome = SvsWaitForBuildGrant(req, vamana_worker_timeout_ms, &granted);
	if (outcome != SVS_BUILD_GRANT_OK)
		ereport(ERROR,
				(errcode(ERRCODE_INSUFFICIENT_RESOURCES),
				 errmsg("vamana index build: no build-thread grant from the launcher within %d ms",
						vamana_worker_timeout_ms),
				 errhint("Check that the vamana launcher is running for this database.")));

	PG_TRY();
	{
		pcxt = SvsLaunchParkedBuildWorkers("svs", granted,
											get_database_name(MyDatabaseId),
											requested);

		INJECTION_POINT("svs-build-thread-grant-acquired", NULL);

		buildFn(pcxt == NULL ? 1 : Min(granted, pcxt->nworkers_launched), context);
	}
	PG_FINALLY();
	{
		if (pcxt != NULL)
			SvsStopParkedBuildWorkers(pcxt);
		SvsReleaseBuildRequestSlot(req);
		SvsKickLauncher();
	}
	PG_END_TRY();
}
