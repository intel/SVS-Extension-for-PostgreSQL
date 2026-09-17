/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cache_load_test.c
 *
 * SQL-callable driver for VamanaCacheIndex, standalone with no launcher,
 * worker, or real SVS index involved. SvsMemoryReconcileLoad and
 * SvsMemoryAccountUnload are backed by a fake, single-process reservation
 * table shaped like svs_memory.c's real one. A load that fails partway
 * through is produced by attaching the injection_points extension to
 * "vamana-cache-index-load-failure" and calling svs_cache_load_test_fake_load
 * inside a SAVEPOINT: the resulting ERROR rolls back to the savepoint, but
 * the process-local cache hash table and this file's fake reservation table
 * are not transactional state, so both survive the rollback.
 */

#include "postgres.h"

#include "svs_index_residency.h"
#include "svs_memory.h"
#include "svs_wrapper.h"
#include "vamana.h"
#include "vamana_replication.h"
#include "vamanaworker.h"

#include "fmgr.h"
#include "miscadmin.h"

PG_MODULE_MAGIC;

static VamanaWorkerShmem FakeWorkerShmem;
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;

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

bool
VamanaWorkerWithEntry(Oid dbOid, VamanaEntryMutatorCb cb, void *ctx)
{
	return false;
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

int
VamanaResolveSearchWindowSize(const VamanaOptions *opts)
{
	return VAMANA_DEFAULT_SEARCH_WINDOW;
}

void
SvsMemoryRecheckSearchScratchOptions(Oid dbOid, Oid relid, int searchWindowSize,
									 bool useSearchHistory)
{
}

void
SvsIndexResidencyRecordLoad(Oid indexRelid, Oid dbOid, uint64 residentBytes)
{
}

void
SvsIndexResidencyRecordUnload(Oid indexRelid)
{
}

/* svs_cache_load_test_fake_load encodes its measured-bytes argument as this handle's own pointer value. */
uint64
SVSGetIndexMemoryUsage(SVSIndexHandle index)
{
	return (uint64) (intptr_t) index;
}

#define MAX_FAKE_RESERVATIONS 16

typedef struct FakeReservation
{
	Oid			relid;
	uint64		bytes;
	bool		inUse;
} FakeReservation;

static FakeReservation FakeReservations[MAX_FAKE_RESERVATIONS];

static FakeReservation *
FindFakeReservation(Oid relid)
{
	for (int i = 0; i < MAX_FAKE_RESERVATIONS; i++)
		if (FakeReservations[i].inUse && FakeReservations[i].relid == relid)
			return &FakeReservations[i];
	return NULL;
}

bool
SvsMemoryReconcileLoad(Oid dbOid, Oid relid, uint64 measuredBytes)
{
	FakeReservation *reservation = FindFakeReservation(relid);

	if (reservation == NULL)
	{
		for (int i = 0; i < MAX_FAKE_RESERVATIONS; i++)
		{
			if (!FakeReservations[i].inUse)
			{
				reservation = &FakeReservations[i];
				break;
			}
		}
		if (reservation == NULL)
			return false;
		reservation->relid = relid;
		reservation->inUse = true;
	}

	reservation->bytes = measuredBytes;
	return true;
}

void
SvsMemoryAccountUnload(Oid dbOid, Oid relid)
{
	FakeReservation *reservation = FindFakeReservation(relid);

	if (reservation != NULL)
		reservation->inUse = false;
}

PG_FUNCTION_INFO_V1(svs_cache_load_test_fake_load);

Datum
svs_cache_load_test_fake_load(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	int64		measuredBytes = PG_GETARG_INT64(1);

	EnsureFakeWorkerContext();
	VamanaCacheIndex(relid, (SVSIndexHandle) (intptr_t) measuredBytes,
					 4, 64, 1.2f, NULL, 0, 0, 1, 0);
	PG_RETURN_VOID();
}

PG_FUNCTION_INFO_V1(svs_cache_load_test_committed_bytes);

Datum
svs_cache_load_test_committed_bytes(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	FakeReservation *reservation = FindFakeReservation(relid);

	if (reservation == NULL)
		PG_RETURN_NULL();
	PG_RETURN_INT64((int64) reservation->bytes);
}

PG_FUNCTION_INFO_V1(svs_cache_load_test_reservation_exists);

Datum
svs_cache_load_test_reservation_exists(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);

	PG_RETURN_BOOL(FindFakeReservation(relid) != NULL);
}
