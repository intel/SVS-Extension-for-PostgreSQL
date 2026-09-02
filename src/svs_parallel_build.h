/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_PARALLEL_BUILD_H
#define SVS_PARALLEL_BUILD_H

#include "postgres.h"
#include "access/parallel.h"

/*
 * A pool of parked parallel build workers: launched, idle, doing no work
 * until the caller decides what to run.  This is the reusable base that a
 * future index-build grant path clamps and puts to work; today it only
 * proves the launch/park/stop lifecycle in isolation and lets each worker
 * self-describe in pg_stat_activity -- datname/requested carry that
 * self-description only, never build work or payload.
 *
 * SvsLaunchParkedBuildWorkers() requests up to nworkers; the framework
 * may launch fewer (background worker slots are cluster-wide and finite,
 * or no DSM segment could be allocated), never more.  It blocks until every
 * launched worker has attached before returning, so nworkers_launched on
 * the result means "running now", not "asked to start".  It returns NULL
 * if no workers launched, in which case the caller falls back to serial
 * execution and never calls SvsStopParkedBuildWorkers().
 *
 * Parked workers never exit on their own; SvsStopParkedBuildWorkers()
 * must be called to terminate them and release the parallel context.
 */
extern ParallelContext *SvsLaunchParkedBuildWorkers(const char *libraryName,
													 int nworkers,
													 const char *datname,
													 int32 requested);
extern void SvsStopParkedBuildWorkers(ParallelContext *pcxt);

/*
 * Looked up by name in the shared library at runtime (CreateParallelContext
 * records only the library and function name); default visibility is
 * required for that lookup to succeed under -fvisibility=hidden.
 */
extern PGDLLEXPORT void SvsParkedBuildWorkerMain(dsm_segment *seg, shm_toc *toc);

#endif							/* SVS_PARALLEL_BUILD_H */
