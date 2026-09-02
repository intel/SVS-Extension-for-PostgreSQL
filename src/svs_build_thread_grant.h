/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_BUILD_THREAD_GRANT_H
#define SVS_BUILD_THREAD_GRANT_H

#include "postgres.h"

typedef void (*SvsGovernedBuildFn) (int grantedThreads, void *context);

/*
 * Run buildFn under the launcher's CPU governance: resolve this database's
 * requested build-thread count, ask the launcher for a grant, reserve that
 * many parked ParallelContext workers so PostgreSQL's own pool accounting
 * sees them, then call buildFn(grantedThreads, context) to do the actual
 * build. Releases the grant and the reservation when buildFn returns or
 * raises, so both are held for exactly the build's duration.
 *
 * Raises ERROR, naming the launcher, if no grant arrives before
 * svs.worker_timeout_ms or every pending-build slot for this database is
 * already in use -- there is no silent fallback.
 */
extern void SvsRunGovernedBuild(SvsGovernedBuildFn buildFn, void *context);

#endif							/* SVS_BUILD_THREAD_GRANT_H */
