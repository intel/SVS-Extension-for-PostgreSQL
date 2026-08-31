/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_CPU_BUDGET_H
#define SVS_CPU_BUDGET_H

#include "postgres.h"

/*
 * One enabled database's projected CPU request, as read from the catalog and
 * the live-worker set.
 */
typedef struct SvsDbCpuRequest
{
	Oid			dbOid;
	bool		live;					/* false: dead or backing off; contributes nothing */
	int32		searchNumThreads;		/* catalog value; -1 = follow the GUC default */
	int32		searchThreadsReserved;	/* guaranteed floor; 0 = no floor */
} SvsDbCpuRequest;

/* One pending build, tagged by requesting backend; a database may have several. */
typedef struct SvsBuildCpuRequest
{
	Oid			dbOid;
	int			requestPid;
	int32		maintenanceNumThreads;	/* catalog value or GUC fallback; 0 = no grant needed */
} SvsBuildCpuRequest;

/* Cluster-wide GUC snapshot, taken once per reconcile after ProcessConfigFile. */
typedef struct SvsCpuGucs
{
	int32		searchNumThreadsDefault;		/* svs.search_num_threads; 0 = auto (resolves to 1) */
	int32		maxSearchThreadsPerDb;			/* svs.max_search_threads_per_db; 0 = follow maxParallelWorkers */
	int32		maxTotalSearchThreads;			/* svs.max_total_search_threads; 0 = follow maxParallelWorkers */
	int32		maxParallelWorkers;				/* core max_parallel_workers: the hard pool */
	int32		maxParallelMaintenanceWorkers;	/* core max_parallel_maintenance_workers: build fallback */
} SvsCpuGucs;

typedef struct SvsCpuBudgetInput
{
	const SvsCpuGucs		 *gucs;
	const SvsDbCpuRequest	 *dbs;
	int							 ndbs;
	const SvsBuildCpuRequest *builds;
	int							 nbuilds;
} SvsCpuBudgetInput;

typedef struct SvsDbCpuGrant
{
	Oid			dbOid;
	int32		desiredSearchThreads;	/* resolved, clamped ask; independent of contention */
	int32		grantedSearchThreads;	/* fiction workers the worker must hold */
	int32		reservedSearchThreads;	/* the floor actually honored */
} SvsDbCpuGrant;

typedef struct SvsBuildCpuGrant
{
	Oid			dbOid;
	int			requestPid;
	int32		grantedThreads;			/* cap for ParallelContext nworkers */
} SvsBuildCpuGrant;

typedef struct SvsCpuBudget
{
	SvsDbCpuGrant	*dbGrants;
	int				 ndbGrants;
	SvsBuildCpuGrant *buildGrants;
	int				 nbuildGrants;
	bool			 reservedFloorsExceedPool;	/* configured floors summed past the pool */
} SvsCpuBudget;

/*
 * Computes every enabled database's search-thread grant and every pending
 * build's thread grant from the projected catalog values, the GUC snapshot,
 * and the live-worker set.  Performs no catalog, shmem, GUC, or latch access;
 * the caller collects the inputs and applies the outputs.  Allocates the
 * result in resultCtx.
 */
extern SvsCpuBudget *SvsComputeCpuGrants(const SvsCpuBudgetInput *in,
										  MemoryContext resultCtx);

#endif							/* SVS_CPU_BUDGET_H */
