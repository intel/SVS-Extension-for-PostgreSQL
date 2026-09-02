/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_parallel_build.c
 *
 * ParallelContext lifecycle for index-build worker pools.  A build uses
 * ParallelContext rather than the launcher's RegisterDynamicBackgroundWorker
 * mechanism because a build's workers are scoped to one backend's
 * operation: ParallelContext ties their teardown to that backend's resource
 * owner, so an error or a normal exit reclaims them with no bookkeeping of
 * our own.
 *
 * This module only establishes the pool and lets each worker self-describe
 * in pg_stat_activity; it grants no capacity and does no build work itself.
 * SvsParkedBuildWorkerMain blocks on its latch until told to stop, which is
 * what makes the pool safe to launch and test before any real build work is
 * wired to it.
 */

#include "postgres.h"

#include "svs_parallel_build.h"

#include "access/xact.h"
#include "miscadmin.h"
#include "storage/latch.h"
#include "utils/backend_status.h"
#include "utils/builtins.h"
#include "utils/wait_classes.h"

#include "svs_slot_naming.h"

/*
 * The only custom key this parallel context ever registers; a named
 * constant self-documents that intent for anyone extending this file later,
 * the same way core's own ParallelContext users (e.g. nbtree) name every
 * key they register rather than using a bare literal.
 */
#define SVS_PARALLEL_KEY_SLOT_DESC	UINT64CONST(1)

/* Private to this file: how a parked worker learns what to call itself. */
typedef struct SvsBuildSlotDesc
{
	int32		requested;
	int32		granted;
	NameData	datname;
} SvsBuildSlotDesc;

ParallelContext *
SvsLaunchParkedBuildWorkers(const char *libraryName, int nworkers,
							const char *datname, int32 requested)
{
	ParallelContext *pcxt;
	SvsBuildSlotDesc *slotDesc;

	if (nworkers <= 0)
		return NULL;

	EnterParallelMode();
	pcxt = CreateParallelContext(libraryName, "SvsParkedBuildWorkerMain",
								  nworkers);

	shm_toc_estimate_chunk(&pcxt->estimator, sizeof(SvsBuildSlotDesc));
	shm_toc_estimate_keys(&pcxt->estimator, 1);

	InitializeParallelDSM(pcxt);
	if (pcxt->seg == NULL)
	{
		/* No DSM segment available; caller runs serially instead. */
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	slotDesc = shm_toc_allocate(pcxt->toc, sizeof(SvsBuildSlotDesc));
	slotDesc->requested = requested;
	slotDesc->granted = nworkers;
	namestrcpy(&slotDesc->datname, datname);
	shm_toc_insert(pcxt->toc, SVS_PARALLEL_KEY_SLOT_DESC, slotDesc);

	LaunchParallelWorkers(pcxt);
	if (pcxt->nworkers_launched == 0)
	{
		DestroyParallelContext(pcxt);
		ExitParallelMode();
		return NULL;
	}

	/*
	 * Block until every launched worker has attached, so the caller can
	 * trust nworkers_launched as "running now" rather than "requested to
	 * start".  This also surfaces any worker startup error immediately
	 * instead of leaving it to be discovered later.
	 */
	WaitForParallelWorkersToAttach(pcxt);

	return pcxt;
}

void
SvsStopParkedBuildWorkers(ParallelContext *pcxt)
{
	if (pcxt == NULL)
		return;

	/*
	 * Parked workers never finish on their own, so unlike the usual
	 * WaitForParallelWorkersToFinish()-then-destroy sequence, destroying
	 * the context directly is what stops them: it forcibly terminates any
	 * worker still running before releasing the DSM segment.
	 */
	DestroyParallelContext(pcxt);
	ExitParallelMode();
}

void
SvsParkedBuildWorkerMain(dsm_segment *seg, shm_toc *toc)
{
	SvsBuildSlotDesc *slotDesc = shm_toc_lookup(toc, SVS_PARALLEL_KEY_SLOT_DESC, false);
	char		appName[NAMEDATALEN + 64];

	SvsFormatBuildSlotAppName(appName, sizeof(appName), NameStr(slotDesc->datname),
							 ParallelWorkerNumber + 1, slotDesc->granted,
							 slotDesc->requested, slotDesc->granted);
	pgstat_report_appname(appName);

	for (;;)
	{
		CHECK_FOR_INTERRUPTS();
		(void) WaitLatch(MyLatch, WL_LATCH_SET | WL_EXIT_ON_PM_DEATH, -1,
						  PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
	}
}
