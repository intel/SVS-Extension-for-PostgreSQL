/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_memory_test_fakeshmem.c
 *
 * svs_memory.c reads and writes its counters and reservations through
 * VamanaWorkerLookupSlot/VamanaWorkerHeader/VamanaWorkerSlotCapacity -- real
 * shared memory in the svs extension, owned by vamanaworkershmem.c, which
 * this standalone module never links (no postmaster-time shmem_startup_hook
 * runs here). These are backend-local stand-ins: one lookup call creates an
 * entry the first time a test uses a dbOid, matching how every existing
 * caller in this module's SQL already behaves (none of them reserve a slot
 * before using one). Plain backend memory, not shared: this module is
 * always exercised by one session, one process.
 */

#include "postgres.h"

#include "storage/lwlock.h"
#include "utils/memutils.h"

#include "vamanaworker.h"

#define SVS_MEMORY_TEST_MAX_DATABASES 8

static VamanaWorkerShmemHeader *fakeHeader = NULL;
static LWLock fakeHeaderLock;

static void
InitFakeEntry(VamanaWorkerShmem *entry)
{
	entry->dbOid = InvalidOid;
	LWLockInitialize(&entry->memLock, LWLockNewTrancheId());
	pg_atomic_init_u64(&entry->searchScratchBytesInFlight, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		entry->reservations[i].relid = InvalidOid;
	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
		entry->insertReservations[i].relid = InvalidOid;
}

static void
EnsureFakeHeaderInitialized(void)
{
	if (fakeHeader != NULL)
		return;

	fakeHeader = MemoryContextAllocZero(TopMemoryContext,
										 offsetof(VamanaWorkerShmemHeader, slots) +
										 sizeof(VamanaWorkerShmem) * SVS_MEMORY_TEST_MAX_DATABASES);

	LWLockInitialize(&fakeHeaderLock, LWLockNewTrancheId());
	fakeHeader->lock = &fakeHeaderLock;
	fakeHeader->numSlots = SVS_MEMORY_TEST_MAX_DATABASES;
	fakeHeader->numActive = 0;

	for (int i = 0; i < fakeHeader->numSlots; i++)
		InitFakeEntry(&fakeHeader->slots[i]);
}

VamanaWorkerShmemHeader *
VamanaWorkerHeader(void)
{
	EnsureFakeHeaderInitialized();
	return fakeHeader;
}

int
VamanaWorkerSlotCapacity(void)
{
	EnsureFakeHeaderInitialized();
	return fakeHeader->numSlots;
}

VamanaWorkerShmem *
VamanaWorkerLookupSlot(Oid dbOid)
{
	VamanaWorkerShmem *freeSlot = NULL;

	EnsureFakeHeaderInitialized();

	for (int i = 0; i < fakeHeader->numSlots; i++)
	{
		if (fakeHeader->slots[i].dbOid == dbOid)
			return &fakeHeader->slots[i];
		if (freeSlot == NULL && fakeHeader->slots[i].dbOid == InvalidOid)
			freeSlot = &fakeHeader->slots[i];
	}

	if (freeSlot == NULL)
		ereport(ERROR,
				(errmsg("svs_memory_test: fake shmem has no free slot for database %u",
						dbOid),
				 errhint("SVS_MEMORY_TEST_MAX_DATABASES (%d) distinct dbOids are already in use this session.",
						  SVS_MEMORY_TEST_MAX_DATABASES)));

	freeSlot->dbOid = dbOid;
	fakeHeader->numActive++;
	return freeSlot;
}
