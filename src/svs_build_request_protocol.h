/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_BUILD_REQUEST_PROTOCOL_H
#define SVS_BUILD_REQUEST_PROTOCOL_H

#include "postgres.h"

#include "vamanaworker.h"

typedef enum SvsBuildGrantOutcome
{
	SVS_BUILD_GRANT_OK,
	SVS_BUILD_GRANT_TIMEOUT,
} SvsBuildGrantOutcome;

/*
 * Backend-side build-thread request protocol, the build-side analogue of
 * VamanaWorkerClaimSlot/VamanaWorkerFinishSubmit: claim a request against
 * the current database's worker entry, wait for the launcher to grant it,
 * and release it once done.  Unlike a search/insert slot, a granted request
 * must stay claimed for the life of the build it authorizes --
 * SvsReleaseBuildRequestSlot is the caller's job once the build itself (not
 * just the wait) has finished.  And unlike VamanaWorkerClaimSlot, the claim
 * does not require worker liveness: the worker's own startup path requests
 * build threads for itself before publishing that liveness.
 */
SvsBuildRequest *SvsClaimBuildRequestSlot(int32 requested);
SvsBuildGrantOutcome SvsWaitForBuildGrant(SvsBuildRequest *req, int timeout_ms,
										   int32 *grantedOut);
void	SvsReleaseBuildRequestSlot(SvsBuildRequest *req);

#endif							/* SVS_BUILD_REQUEST_PROTOCOL_H */
