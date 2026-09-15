/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cache_kick_test.c
 *
 * SQL-callable driver for vamanacache.c's cache-eviction arithmetic,
 * exercised standalone with no launcher, worker, or replication machinery
 * involved: does evicting one of several cached entries leave the others in
 * place and not kick, and does the kick fire only once the count reaches
 * zero. vamanacache.c's cache array is per-process and worker-agnostic, so
 * this arithmetic does not depend on which process runs it; a plain backend
 * exercises the same code paths a real worker would.
 *
 * Not tested end to end through DROP INDEX / TRUNCATE against a live
 * worker; see the PR description for why.
 *
 * VamanaWorkerShmemPtr here points at a fake, static VamanaWorkerShmem this
 * module owns (not real shared memory), with workerPid set to this
 * backend's own pid so VamanaCacheMaybeKickLauncher's worker-context guard
 * passes. SvsKickLauncher is stubbed to record that it was called rather
 * than touch real shared memory, so this file can observe the kick decision
 * directly instead of inferring it from cache state alone.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_replication.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "fmgr.h"
#include "miscadmin.h"

PG_MODULE_MAGIC;

/* ---------------------------------------------------------------------
 * Stand-ins for the rest of the extension. vamanacache.c references these
 * across file boundaries; only the eviction/cache path exercised here needs
 * to actually do anything.
 * --------------------------------------------------------------------- */

static VamanaWorkerShmem FakeWorkerShmem;
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;

static bool KickCalled = false;
static int32 KickCount = 0;

static void
EnsureFakeWorkerContext(void)
{
	if (VamanaWorkerShmemPtr == NULL)
	{
		memset(&FakeWorkerShmem, 0, sizeof(FakeWorkerShmem));
		FakeWorkerShmem.workerPid = MyProcPid;
		VamanaWorkerShmemPtr = &FakeWorkerShmem;
	}
}

void
SvsKickLauncher(void)
{
	KickCalled = true;
	KickCount++;
}

void
VamanaDeleteSaveDir(Oid dboid, Oid relid)
{
}

void
VamanaReleaseIndexLock(VamanaWorkerShmem *entry, Oid relid)
{
}

void
VamanaReplicationClose(VamanaReplicationSlot *slot)
{
}

VamanaSlotDropResult
VamanaReplicationDropIfExists(Oid dboid, Oid indexRelid)
{
	return VAMANA_SLOT_DROP_DONE;
}

void
VamanaReplicationQueueDropAtCommit(Oid dboid, Oid indexRelid)
{
}

bool
VamanaWorkerIsAvailable(void)
{
	return false;
}

VamanaWorkerShmem *
VamanaWorkerLookupSlot(Oid dbOid)
{
	return NULL;
}

void
VamanaWorkerQueueIndexCountDelta(Oid dbOid, int delta)
{
}

void
VamanaWorkerSignalReload(Oid indexRelid)
{
}

void
SVSFreeIndex(SVSIndexHandle index)
{
}

/* ---------------------------------------------------------------------
 * SQL-callable functions
 * --------------------------------------------------------------------- */

PG_FUNCTION_INFO_V1(svs_cache_fake_load);

Datum
svs_cache_fake_load(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);

	EnsureFakeWorkerContext();
	VamanaCacheIndex(relid, NULL, 4, 64, 1.2f, NULL, 0, 0, 1, 0);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(svs_cache_evict);

Datum
svs_cache_evict(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);

	EnsureFakeWorkerContext();
	VamanaEvictCacheEntry(relid);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(svs_cache_evict_all);

Datum
svs_cache_evict_all(PG_FUNCTION_ARGS)
{
	EnsureFakeWorkerContext();
	VamanaEvictAllCacheEntries();
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(svs_cache_invalidate);

Datum
svs_cache_invalidate(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);

	EnsureFakeWorkerContext();
	VamanaInvalidateCache(relid);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(svs_cache_count);

Datum
svs_cache_count(PG_FUNCTION_ARGS)
{
	Oid			relids[VAMANA_MAX_CACHED_INDEXES];
	int			n;

	EnsureFakeWorkerContext();
	n = VamanaGetAllCachedRelids(relids, VAMANA_MAX_CACHED_INDEXES);
	PG_RETURN_INT32(n);
}

PG_FUNCTION_INFO_V1(svs_cache_kicked);

Datum
svs_cache_kicked(PG_FUNCTION_ARGS)
{
	PG_RETURN_BOOL(KickCalled);
}

PG_FUNCTION_INFO_V1(svs_cache_kick_count);

Datum
svs_cache_kick_count(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(KickCount);
}

PG_FUNCTION_INFO_V1(svs_cache_reset_kick_tracking);

Datum
svs_cache_reset_kick_tracking(PG_FUNCTION_ARGS)
{
	KickCalled = false;
	KickCount = 0;
	PG_RETURN_VOID();
}
