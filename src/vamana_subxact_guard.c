/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_subxact_guard.c
 *
 * The catch-log-continue subtransaction scaffold shared by
 * vamana_replication.c (per-record decode replay), vamana_teardown.c
 * (per-index drop), and vamana_warmup.c (per-index warm-up). Owns the
 * ctx/owner save-restore and subxact begin/release/rollback only; callers
 * supply the body and choose how to dispose of a caught error.
 */

#include "postgres.h"

#include "vamana_subxact_guard.h"

#include "access/xact.h"
#include "utils/memutils.h"
#include "utils/resowner.h"

VamanaSubXactResult
VamanaRunInSubXact(VamanaSubXactBody body, void *arg,
					VamanaSubXactShouldPropagate shouldPropagate)
{
	MemoryContext oldCtx = CurrentMemoryContext;
	ResourceOwner oldOwner = CurrentResourceOwner;
	VamanaSubXactResult result = {0};

	BeginInternalSubTransaction(NULL);
	MemoryContextSwitchTo(oldCtx);

	PG_TRY();
	{
		body(arg);

		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldCtx);
		CurrentResourceOwner = oldOwner;

		result.succeeded = true;
	}
	PG_CATCH();
	{
		bool	propagate = shouldPropagate != NULL && shouldPropagate();

		MemoryContextSwitchTo(oldCtx);

		if (propagate)
		{
			RollbackAndReleaseCurrentSubTransaction();
			MemoryContextSwitchTo(oldCtx);
			CurrentResourceOwner = oldOwner;
			PG_RE_THROW();
		}

		result.edata = CopyErrorData();
		FlushErrorState();

		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldCtx);
		CurrentResourceOwner = oldOwner;

		result.succeeded = false;
	}
	PG_END_TRY();

	return result;
}
