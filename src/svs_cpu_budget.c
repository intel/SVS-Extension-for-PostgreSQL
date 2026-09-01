/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cpu_budget.c
 *
 * The single accounting authority for SVS thread governance: given the
 * projected per-database catalog values, the GUC snapshot, and the pending
 * build requests, SvsComputeCpuGrants decides how many threads each
 * database's search workload gets and how many threads each pending build
 * gets, all bounded by the shared max_parallel_workers pool.
 *
 * Pure: no catalog, shmem, GUC, or latch access.  The caller collects 
 * the inputs and applies the outputs.
 *
 * Every database's reserved floor is honored in full before anything else is
 * distributed.  What remains -- the elastic remainder -- is split across
 * unmet search demand and build requests in proportion to each claim's
 * honored floor (0 for a build, which carries no floor), capped so nobody
 * receives more than they asked for.  A claim that cannot get more without
 * exceeding its ask is settled at its ask and its surplus flows back to the
 * claims still competing, which is what keeps a lower-weight claim from ever
 * being driven to zero just because a higher-weight claim's demand is large.
 */

#include "postgres.h"

#include "svs_cpu_budget.h"

typedef struct SvsDbCpuWorking
{
	Oid			dbOid;
	int32		desired;
	int32		floor;
	int32		elasticGrant;
} SvsDbCpuWorking;

typedef struct SvsBuildCpuWorking
{
	Oid			dbOid;
	int			requestPid;
	int32		grant;
} SvsBuildCpuWorking;

/*
 * One claim on the elastic remainder: a database's unmet search demand, or a
 * pending build.  floorShare and fracNumerator are scratch, valid only while
 * ApportionRemainder is settling this claim.
 */
typedef struct SvsCpuClaim
{
	Oid			dbOid;
	int			requestPid;
	int32		weight;
	int32		ask;
	int32	   *grantOut;
	int32		floorShare;
	int64		fracNumerator;
} SvsCpuClaim;

static int32
ResolveOrFallback(int32 configured, int32 fallback)
{
	return (configured == 0) ? fallback : configured;
}

static int32
ComputeSearchPool(const SvsCpuGucs *gucs)
{
	return Min(gucs->maxParallelWorkers,
			   ResolveOrFallback(gucs->maxTotalSearchThreads, gucs->maxParallelWorkers));
}

static int32
ComputePerDatabaseCeiling(const SvsCpuGucs *gucs)
{
	return ResolveOrFallback(gucs->maxSearchThreadsPerDb, gucs->maxParallelWorkers);
}

static int32
ComputeEffectiveDesired(const SvsDbCpuRequest *req, const SvsCpuGucs *gucs,
						 int32 perDbCeiling)
{
	int32		clusterDefault;
	int32		requested;

	if (!req->live)
		return 0;

	clusterDefault = ResolveOrFallback(gucs->searchNumThreadsDefault, 1);
	requested = (req->searchNumThreads == -1) ? clusterDefault : req->searchNumThreads;

	return Min(Max(requested, 1), perDbCeiling);
}

static SvsDbCpuWorking *
BuildDbWorkingSet(const SvsCpuBudgetInput *in, int32 perDbCeiling)
{
	SvsDbCpuWorking *working = palloc(sizeof(SvsDbCpuWorking) * in->ndbs);
	int			i;

	for (i = 0; i < in->ndbs; i++)
	{
		const SvsDbCpuRequest *req = &in->dbs[i];

		working[i].dbOid = req->dbOid;
		working[i].desired = ComputeEffectiveDesired(req, in->gucs, perDbCeiling);
		working[i].floor = req->live ? Min(req->searchThreadsReserved, working[i].desired) : 0;
		working[i].elasticGrant = 0;
	}

	return working;
}

static SvsBuildCpuWorking *
BuildBuildWorkingSet(const SvsCpuBudgetInput *in)
{
	SvsBuildCpuWorking *working = palloc(sizeof(SvsBuildCpuWorking) * in->nbuilds);
	int			i;

	for (i = 0; i < in->nbuilds; i++)
	{
		working[i].dbOid = in->builds[i].dbOid;
		working[i].requestPid = in->builds[i].requestPid;
		working[i].grant = 0;
	}

	return working;
}

static int
CompareWorkingByDbOidAsc(const void *a, const void *b)
{
	Oid			oa = (*(SvsDbCpuWorking * const *) a)->dbOid;
	Oid			ob = (*(SvsDbCpuWorking * const *) b)->dbOid;

	return (oa < ob) ? -1 : (oa > ob ? 1 : 0);
}

/*
 * If configured floors sum past the pool, cut them down to fit.  Cuts land on
 * the lowest dbOid first -- an explicit, deterministic tiebreak for a
 * misconfiguration (more floor promised than the pool can ever hold), not a
 * priority judgment.
 */
static bool
ClampFloorsToPool(SvsDbCpuWorking *working, int ndbs, int32 pool)
{
	SvsDbCpuWorking **order;
	int64		totalFloor = 0;
	int64		excess;
	int			i;

	for (i = 0; i < ndbs; i++)
		totalFloor += working[i].floor;

	if (totalFloor <= pool)
		return false;

	order = palloc(sizeof(SvsDbCpuWorking *) * ndbs);
	for (i = 0; i < ndbs; i++)
		order[i] = &working[i];
	qsort(order, ndbs, sizeof(SvsDbCpuWorking *), CompareWorkingByDbOidAsc);

	excess = totalFloor - pool;
	for (i = 0; i < ndbs && excess > 0; i++)
	{
		int32		cut = (int32) Min((int64) order[i]->floor, excess);

		order[i]->floor -= cut;
		excess -= cut;
	}

	pfree(order);
	return true;
}

static SvsCpuClaim *
BuildClaims(SvsDbCpuWorking *dbWorking, int ndbs,
			const SvsBuildCpuRequest *builds, SvsBuildCpuWorking *buildWorking,
			int nbuilds, int *nclaimsOut)
{
	SvsCpuClaim *claims = palloc(sizeof(SvsCpuClaim) * (ndbs + nbuilds));
	int			n = 0;
	int			i;

	for (i = 0; i < ndbs; i++)
	{
		int32		ask = dbWorking[i].desired - dbWorking[i].floor;

		if (ask <= 0)
			continue;

		claims[n].dbOid = dbWorking[i].dbOid;
		claims[n].requestPid = 0;
		claims[n].weight = dbWorking[i].floor;
		claims[n].ask = ask;
		claims[n].grantOut = &dbWorking[i].elasticGrant;
		n++;
	}

	for (i = 0; i < nbuilds; i++)
	{
		int32		ask = builds[i].maintenanceNumThreads;

		if (ask <= 0)
			continue;

		claims[n].dbOid = buildWorking[i].dbOid;
		claims[n].requestPid = buildWorking[i].requestPid;
		claims[n].weight = 0;
		claims[n].ask = ask;
		claims[n].grantOut = &buildWorking[i].grant;
		n++;
	}

	*nclaimsOut = n;
	return claims;
}

/*
 * Tiebreak for the largest-remainder rounding step: biggest fractional loss
 * first, then higher weight, then lowest dbOid, then lowest requestPid.
 */
static int
CompareClaimsForLeftover(const void *a, const void *b)
{
	const SvsCpuClaim *ca = (const SvsCpuClaim *) a;
	const SvsCpuClaim *cb = (const SvsCpuClaim *) b;

	if (ca->fracNumerator != cb->fracNumerator)
		return (ca->fracNumerator > cb->fracNumerator) ? -1 : 1;
	if (ca->weight != cb->weight)
		return (ca->weight > cb->weight) ? -1 : 1;
	if (ca->dbOid != cb->dbOid)
		return (ca->dbOid < cb->dbOid) ? -1 : 1;
	return (ca->requestPid < cb->requestPid) ? -1 :
		(ca->requestPid > cb->requestPid ? 1 : 0);
}

/*
 * Splits remainder across claims in proportion to weight (equal shares when
 * every active claim has weight 0), water-filling around each claim's ask:
 * a claim whose fair share would exceed its ask is settled at its ask
 * instead, and its surplus is redistributed among the claims still
 * competing.  Terminates in at most nclaims passes, since each pass either
 * finishes outright or settles at least one more claim.
 */
static void
ApportionRemainder(SvsCpuClaim *claims, int nclaims, int32 remainder)
{
	int			active = nclaims;

	while (active > 0 && remainder > 0)
	{
		int64		totalAsk = 0;
		int64		totalWeight = 0;
		int64		denom;
		int			newActive;
		int32		settledAsk;
		int			i;

		for (i = 0; i < active; i++)
		{
			totalAsk += claims[i].ask;
			totalWeight += claims[i].weight;
		}

		if (remainder >= totalAsk)
		{
			for (i = 0; i < active; i++)
				*claims[i].grantOut += claims[i].ask;
			return;
		}

		denom = (totalWeight > 0) ? totalWeight : active;

		newActive = 0;
		settledAsk = 0;
		for (i = 0; i < active; i++)
		{
			int64		weightForShare = (totalWeight > 0) ? claims[i].weight : 1;

			claims[i].floorShare = (int32) ((int64) remainder * weightForShare / denom);

			if (claims[i].floorShare >= claims[i].ask)
			{
				*claims[i].grantOut += claims[i].ask;
				settledAsk += claims[i].ask;
			}
			else
				claims[newActive++] = claims[i];
		}

		if (newActive < active)
		{
			active = newActive;
			remainder -= settledAsk;
			continue;
		}

		{
			int32		distributed = 0;
			int32		leftover;

			for (i = 0; i < active; i++)
			{
				int64		weightForShare = (totalWeight > 0) ? claims[i].weight : 1;

				claims[i].fracNumerator = ((int64) remainder * weightForShare) % denom;
				distributed += claims[i].floorShare;
			}

			leftover = remainder - distributed;

			qsort(claims, active, sizeof(SvsCpuClaim), CompareClaimsForLeftover);

			for (i = 0; i < active; i++)
			{
				int32		share = claims[i].floorShare + (i < leftover ? 1 : 0);

				*claims[i].grantOut += share;
			}
		}

		return;
	}
}

SvsCpuBudget *
SvsComputeCpuGrants(const SvsCpuBudgetInput *in, MemoryContext resultCtx)
{
	int32		pool = ComputeSearchPool(in->gucs);
	int32		perDbCeiling = ComputePerDatabaseCeiling(in->gucs);
	SvsDbCpuWorking *dbWorking = BuildDbWorkingSet(in, perDbCeiling);
	SvsBuildCpuWorking *buildWorking = BuildBuildWorkingSet(in);
	bool		reservedFloorsExceedPool = ClampFloorsToPool(dbWorking, in->ndbs, pool);
	int64		grantedFloor = 0;
	SvsCpuClaim *claims;
	int			nclaims;
	SvsCpuBudget *budget;
	int			i;

	for (i = 0; i < in->ndbs; i++)
		grantedFloor += dbWorking[i].floor;

	claims = BuildClaims(dbWorking, in->ndbs, in->builds, buildWorking, in->nbuilds,
						 &nclaims);
	ApportionRemainder(claims, nclaims, (int32) (pool - grantedFloor));

	budget = MemoryContextAlloc(resultCtx, sizeof(SvsCpuBudget));
	budget->ndbGrants = in->ndbs;
	budget->dbGrants = MemoryContextAlloc(resultCtx, sizeof(SvsDbCpuGrant) * in->ndbs);
	for (i = 0; i < in->ndbs; i++)
	{
		budget->dbGrants[i].dbOid = dbWorking[i].dbOid;
		budget->dbGrants[i].desiredSearchThreads = dbWorking[i].desired;
		budget->dbGrants[i].reservedSearchThreads = dbWorking[i].floor;
		budget->dbGrants[i].grantedSearchThreads = dbWorking[i].floor + dbWorking[i].elasticGrant;
	}

	budget->nbuildGrants = in->nbuilds;
	budget->buildGrants = MemoryContextAlloc(resultCtx, sizeof(SvsBuildCpuGrant) * in->nbuilds);
	for (i = 0; i < in->nbuilds; i++)
	{
		budget->buildGrants[i].dbOid = buildWorking[i].dbOid;
		budget->buildGrants[i].requestPid = buildWorking[i].requestPid;
		budget->buildGrants[i].grantedThreads = buildWorking[i].grant;
	}

	budget->reservedFloorsExceedPool = reservedFloorsExceedPool;

	pfree(dbWorking);
	pfree(buildWorking);
	pfree(claims);

	return budget;
}
