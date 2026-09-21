/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#include "postgres.h"

#include "svs_build_request_protocol.h"

#include "miscadmin.h"
#include "storage/latch.h"
#include "utils/wait_classes.h"

/*
 * Claim a free build-thread request slot against the current database's
 * worker entry, keyed by this backend's PID.  Returns NULL if this database
 * has no reserved entry at all, or every slot is already claimed.
 *
 * Deliberately does not require VamanaWorkerEntryIsLive: the worker's own
 * startup path (VamanaWorkerServe's pre-workerPid standby cache population)
 * requests build threads for itself before it has published its own
 * liveness, and a request for CPU budget from the launcher is meaningful
 * independent of whether a worker is currently, healthily serving backends.
 */
SvsBuildRequest *
SvsClaimBuildRequestSlot(int32 requested)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(MyDatabaseId);

	if (entry == NULL)
		return NULL;

	for (int i = 0; i < SVS_MAX_PENDING_BUILDS; i++)
	{
		SvsBuildRequest *req = &entry->buildRequests[i];
		uint32		expected = 0;

		if (!pg_atomic_compare_exchange_u32(&req->pid, &expected, (uint32) MyProcPid))
			continue;

		req->requested = requested;
		req->granted = 0;
		pg_write_barrier();
		pg_atomic_write_u32(&req->status, SVS_BUILD_REQUEST_PENDING);

		return req;
	}

	return NULL;
}

/*
 * Wait on this backend's own latch for the launcher to grant req, chunked
 * against postmaster death exactly like VamanaWorkerWaitForSlot's wait loop.
 * On interrupt/error, releases the still-pending request before re-throwing.
 * On timeout, does the same before returning -- without checking whether
 * the release raced a concurrent grant from the launcher, matching
 * VamanaWorkerWaitForSlot's own tolerance for that harmless race.
 *
 * On a grant, leaves the request claimed: it authorizes a build about to
 * start, not one already finished, so releasing it is the caller's job once
 * the build itself completes.
 */
SvsBuildGrantOutcome
SvsWaitForBuildGrant(SvsBuildRequest *req, int timeout_ms, int32 *grantedOut)
{
	int			total_waited_ms = 0;

	PG_TRY();
	{
		while (true)
		{
			int			rc;
			long		wait_ms = Min(1000, timeout_ms - total_waited_ms);

			if (wait_ms <= 0)
				break;

			rc = WaitLatch(MyLatch, WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						   wait_ms, PG_WAIT_EXTENSION);
			ResetLatch(MyLatch);

			if (rc & WL_POSTMASTER_DEATH)
				ereport(ERROR, (errmsg("postmaster died")));

			CHECK_FOR_INTERRUPTS();

			if (pg_atomic_read_u32(&req->status) == SVS_BUILD_REQUEST_GRANTED)
				break;

			if (rc & WL_TIMEOUT)
			{
				total_waited_ms += (int) wait_ms;
				if (total_waited_ms >= timeout_ms)
					break;
			}
		}
	}
	PG_CATCH();
	{
		SvsReleaseBuildRequestSlot(req);
		PG_RE_THROW();
	}
	PG_END_TRY();

	if (pg_atomic_read_u32(&req->status) == SVS_BUILD_REQUEST_GRANTED)
	{
		pg_read_barrier();
		*grantedOut = req->granted;
		return SVS_BUILD_GRANT_OK;
	}

	SvsReleaseBuildRequestSlot(req);
	return SVS_BUILD_GRANT_TIMEOUT;
}

void
SvsReleaseBuildRequestSlot(SvsBuildRequest *req)
{
	req->requested = 0;
	req->granted = 0;
	pg_write_barrier();
	pg_atomic_write_u32(&req->status, SVS_BUILD_REQUEST_PENDING);
	pg_atomic_write_u32(&req->pid, 0);
}
