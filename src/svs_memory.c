/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_memory.c
 *
 * See svs_memory.h for the module's contract. This module owns every SVS
 * memory counter and every reservation; nothing outside this file mutates
 * a committed-bytes counter, a reservation record, or re-implements a
 * limit check.
 *
 * Every counter and reservation lives in the per-database VamanaWorkerShmem
 * control block (vamanaworker.h), reached via VamanaWorkerLookupSlot, and in
 * the header's global roll-ups, reached via VamanaWorkerHeader. A
 * check-then-add is atomic under that database's memLock; the header lock
 * additionally guards the global roll-ups it feeds, always acquired after
 * memLock (Section 5.5 of the memory-management design doc).
 */

#include "postgres.h"

#include "miscadmin.h"
#include "storage/proc.h"
#include "storage/procarray.h"
#include "utils/backend_status.h"
#include "utils/errcodes.h"
#include "utils/timestamp.h"

#include "svs_memory.h"
#include "vamanaworker.h"

int			vamana_max_build_memory_mb = 100;
int			vamana_max_residency_memory_mb = 100;
int			vamana_default_residency_memory_mb = 100;
int			vamana_max_search_work_mem_mb = 100;
int			vamana_default_search_work_mem_mb = 100;

static inline uint64
BuildMemoryCeilingBytes(void)
{
	return (uint64) vamana_max_build_memory_mb * 1024 * 1024;
}

static inline uint64
ResidencyMemoryCeilingBytes(void)
{
	return (uint64) vamana_max_residency_memory_mb * 1024 * 1024;
}

static VamanaWorkerShmem *
LookupEntryOrError(Oid dbOid)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);

	if (entry == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("database %u has no SVS worker slot reserved", dbOid)));

	return entry;
}

/* Call under entry->memLock. */
static void
RequireAdmitted(VamanaWorkerShmem *entry, Oid dbOid)
{
	if (entry->residencyBudget == 0)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("database %u has no SVS memory accounting entry", dbOid),
				 errhint("SvsMemoryAdmitDatabase must run before any build, load, or insert accounting for this database.")));
}

static SvsMemReservation *
FindReservation(VamanaWorkerShmem *entry, Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		if (entry->reservations[i].relid == relid)
			return &entry->reservations[i];
	return NULL;
}

static SvsMemReservation *
AllocateReservation(VamanaWorkerShmem *entry, Oid relid)
{
	SvsMemReservation *freeSlot = FindReservation(entry, InvalidOid);

	if (freeSlot == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
				 errmsg("too many concurrently tracked SVS indexes for this database"),
				 errdetail("VAMANA_MAX_INDEXES (%d) reservation slots are all in use.",
						   VAMANA_MAX_INDEXES)));

	*freeSlot = (SvsMemReservation) {0};
	freeSlot->relid = relid;
	return freeSlot;
}

static void
FreeReservation(SvsMemReservation *reservation)
{
	reservation->relid = InvalidOid;
}

static SvsMemInsertReservation *
FindFreeInsertReservation(VamanaWorkerShmem *entry)
{
	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
		if (entry->insertReservations[i].relid == InvalidOid)
			return &entry->insertReservations[i];
	return NULL;
}

/* Oldest pending insert reservation for relid, i.e. first reserved. */
static SvsMemInsertReservation *
FindOldestInsertReservation(VamanaWorkerShmem *entry, Oid relid)
{
	SvsMemInsertReservation *oldest = NULL;

	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
	{
		SvsMemInsertReservation *candidate = &entry->insertReservations[i];

		if (candidate->relid != relid)
			continue;
		if (oldest == NULL || candidate->reservedAt < oldest->reservedAt)
			oldest = candidate;
	}
	return oldest;
}

static void
FreeInsertReservation(SvsMemInsertReservation *reservation)
{
	reservation->relid = InvalidOid;
}

/*
 * Subtracts amount from *committed, flooring at 0 and warning instead of
 * wrapping negative -- a double-release or a double-unload signal, never a
 * value this module should trust past this point.
 */
static void
SubtractFloored(uint64 *committed, uint64 amount, const char *what)
{
	if (amount > *committed)
	{
		ereport(WARNING,
				(errmsg("SVS memory accounting underflow releasing %s: releasing %llu bytes but only %llu committed",
						what,
						(unsigned long long) amount, (unsigned long long) *committed)));
		*committed = 0;
	}
	else
		*committed -= amount;
}

/* Global build ceiling. Caller holds entry->memLock; this also takes the header lock. */
static bool
TryAddGlobalBuildCommitted(uint64 amount)
{
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	bool		fits;

	LWLockAcquire(header->lock, LW_EXCLUSIVE);
	fits = header->totalBuildCommittedGlobal + amount <= BuildMemoryCeilingBytes();
	if (fits)
		header->totalBuildCommittedGlobal += amount;
	LWLockRelease(header->lock);

	return fits;
}

static void
SubtractGlobalBuildCommitted(uint64 amount)
{
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();

	LWLockAcquire(header->lock, LW_EXCLUSIVE);
	SubtractFloored(&header->totalBuildCommittedGlobal, amount, "a build peak");
	LWLockRelease(header->lock);
}

uint64
SvsMemoryResidencyBudget(Oid dbOid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	uint64		budget;

	LWLockAcquire(&entry->memLock, LW_SHARED);
	RequireAdmitted(entry, dbOid);
	budget = entry->residencyBudget;
	LWLockRelease(&entry->memLock);

	return budget;
}

void
SvsMemoryAdmitDatabase(Oid dbOid, uint64 residencyBudget)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	uint64		projectedGlobalTotal;

	if (residencyBudget == 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("database %u cannot be admitted at a zero residency budget", dbOid),
				 errhint("A budget of 0 means \"not admitted\" everywhere else in this module; every admitted database needs a budget greater than zero.")));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	if (residencyBudget < entry->residencyBytesCommitted)
	{
		uint64		committed = entry->residencyBytesCommitted;

		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("database %u's residency budget cannot be lowered below its already-committed bytes",
						dbOid),
				 errdetail("Requested %llu byte budget, %llu bytes already committed.",
						   (unsigned long long) residencyBudget,
						   (unsigned long long) committed)));
	}

	LWLockAcquire(header->lock, LW_EXCLUSIVE);

	projectedGlobalTotal = header->totalResidencyCommittedGlobal;
	SubtractFloored(&projectedGlobalTotal, entry->residencyBudget, "a database's prior residency budget");
	projectedGlobalTotal += residencyBudget;

	if (projectedGlobalTotal > ResidencyMemoryCeilingBytes())
	{
		LWLockRelease(header->lock);
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("admitting database %u at %llu bytes would exceed svs.max_residency_memory",
						dbOid, (unsigned long long) residencyBudget),
				 errdetail("Every admitted database's residency budget would sum to %llu bytes, over the %llu byte ceiling.",
						   (unsigned long long) projectedGlobalTotal,
						   (unsigned long long) ResidencyMemoryCeilingBytes())));
	}

	header->totalResidencyCommittedGlobal = projectedGlobalTotal;
	entry->residencyBudget = residencyBudget;

	LWLockRelease(header->lock);
	LWLockRelease(&entry->memLock);
}

void
SvsMemoryReserveBuild(Oid dbOid, Oid relid, uint64 buildPeak, uint64 residencyEstimate)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	RequireAdmitted(entry, dbOid);

	if (FindReservation(entry, relid) != NULL)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("index %u in database %u already has an SVS memory reservation",
						relid, dbOid)));
	}

	if (entry->residencyBytesCommitted + residencyEstimate > entry->residencyBudget)
	{
		uint64		committed = entry->residencyBytesCommitted;
		uint64		budget = entry->residencyBudget;

		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("build of index %u would exceed database %u's residency budget", relid, dbOid),
				 errdetail("Requested %llu bytes, %llu already committed, %llu byte budget.",
						   (unsigned long long) residencyEstimate,
						   (unsigned long long) committed,
						   (unsigned long long) budget)));
	}

	/* Claim the reservation slot before touching any counter, so a full
	 * reservation table leaves every counter untouched. */
	reservation = AllocateReservation(entry, relid);

	if (!TryAddGlobalBuildCommitted(buildPeak))
	{
		FreeReservation(reservation);
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("build of index %u would exceed svs.max_build_memory", relid),
				 errdetail("Requested %llu bytes against the %llu byte ceiling.",
						   (unsigned long long) buildPeak,
						   (unsigned long long) BuildMemoryCeilingBytes())));
	}

	entry->buildBytesCommitted += buildPeak;
	entry->residencyBytesCommitted += residencyEstimate;

	reservation->state = SVS_MEM_RESERVED;
	reservation->ownerPid = MyProcPid;
	reservation->reservedAt = GetCurrentTimestamp();
	reservation->estimateBytes = residencyEstimate;
	reservation->measuredBytes = 0;
	reservation->buildPeakBytes = buildPeak;

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryHandoffBuild(Oid dbOid, Oid relid, uint64 buildPeak, uint64 measuredResidencyBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;
	uint64		residencyWithoutEstimate;
	bool		fits;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation == NULL)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("no pending build reservation for index %u in database %u", relid, dbOid)));
	}

	SubtractFloored(&entry->buildBytesCommitted, buildPeak, "a build peak");
	SubtractGlobalBuildCommitted(buildPeak);

	/* The build peak above is now released; the reaper must not release it again. */
	reservation->buildPeakBytes = 0;

	residencyWithoutEstimate = entry->residencyBytesCommitted;
	SubtractFloored(&residencyWithoutEstimate, reservation->estimateBytes, "a build handoff's residency estimate");
	fits = residencyWithoutEstimate + measuredResidencyBytes <= entry->residencyBudget;

	if (fits)
	{
		entry->residencyBytesCommitted = residencyWithoutEstimate + measuredResidencyBytes;
		reservation->state = SVS_MEM_CONFIRMED;
		reservation->measuredBytes = measuredResidencyBytes;
	}
	else
	{
		entry->residencyBytesCommitted = residencyWithoutEstimate;
		FreeReservation(reservation);
	}

	LWLockRelease(&entry->memLock);

	return fits;
}

void
SvsMemoryAbortBuild(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation != NULL)
	{
		uint64		residencyHeld = (reservation->state == SVS_MEM_CONFIRMED) ?
			reservation->measuredBytes : reservation->estimateBytes;

		if (reservation->buildPeakBytes > 0)
		{
			SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
							 "a build peak");
			SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
		}

		SubtractFloored(&entry->residencyBytesCommitted, residencyHeld,
						 "an aborted build's residency reservation");
		FreeReservation(reservation);
	}

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryReconcileLoad(Oid dbOid, Oid relid, uint64 measuredBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;
	bool		fits;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	RequireAdmitted(entry, dbOid);

	reservation = FindReservation(entry, relid);
	if (reservation != NULL)
	{
		uint64		priorContribution = (reservation->state == SVS_MEM_RESERVED) ?
			reservation->estimateBytes : reservation->measuredBytes;
		uint64		residencyWithoutPrior = entry->residencyBytesCommitted;

		SubtractFloored(&residencyWithoutPrior, priorContribution,
						 "a load reconcile's prior contribution");
		fits = residencyWithoutPrior + measuredBytes <= entry->residencyBudget;

		if (fits)
		{
			entry->residencyBytesCommitted = residencyWithoutPrior + measuredBytes;
			reservation->state = SVS_MEM_RESIDENT;
			reservation->ownerPid = 0;
			reservation->measuredBytes = measuredBytes;
		}
	}
	else
	{
		fits = entry->residencyBytesCommitted + measuredBytes <= entry->residencyBudget;

		if (fits)
		{
			reservation = AllocateReservation(entry, relid);
			reservation->state = SVS_MEM_RESIDENT;
			reservation->ownerPid = 0;
			reservation->reservedAt = GetCurrentTimestamp();
			reservation->estimateBytes = measuredBytes;
			reservation->measuredBytes = measuredBytes;

			entry->residencyBytesCommitted += measuredBytes;
		}
	}

	LWLockRelease(&entry->memLock);

	return fits;
}

void
SvsMemoryAccountUnload(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation == NULL)
	{
		LWLockRelease(&entry->memLock);
		ereport(WARNING,
				(errmsg("SVS memory accounting: unload of index %u in database %u has no reservation to release",
						relid, dbOid)));
		return;
	}

	SubtractFloored(&entry->residencyBytesCommitted, reservation->measuredBytes,
					"an unloaded index's residency");
	FreeReservation(reservation);

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryReserveInsert(Oid dbOid, Oid relid, uint64 deltaBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemInsertReservation *reservation;
	bool		fits;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	RequireAdmitted(entry, dbOid);

	fits = entry->residencyBytesCommitted + deltaBytes <= entry->residencyBudget;
	if (fits)
	{
		reservation = FindFreeInsertReservation(entry);
		if (reservation == NULL)
		{
			LWLockRelease(&entry->memLock);
			ereport(ERROR,
					(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
					 errmsg("too many concurrently pending SVS insert batches for database %u", dbOid),
					 errdetail("SVS_MAX_PENDING_INSERT_RESERVATIONS (%d) reservation slots are all in use.",
							   SVS_MAX_PENDING_INSERT_RESERVATIONS)));
		}

		reservation->relid = relid;
		reservation->ownerPid = MyProcPid;
		reservation->reservedAt = GetCurrentTimestamp();
		reservation->deltaBytes = deltaBytes;

		entry->residencyBytesCommitted += deltaBytes;
	}

	LWLockRelease(&entry->memLock);

	return fits;
}

void
SvsMemoryReanchorInsert(Oid dbOid, Oid relid, uint64 measuredBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;
	SvsMemInsertReservation *insertReservation;
	uint64		priorMeasured;
	uint64		pendingDelta;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation == NULL)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("no resident reservation for index %u in database %u to reanchor", relid, dbOid)));
	}

	insertReservation = FindOldestInsertReservation(entry, relid);
	priorMeasured = reservation->measuredBytes;
	pendingDelta = (insertReservation != NULL) ? insertReservation->deltaBytes : 0;

	SubtractFloored(&entry->residencyBytesCommitted, priorMeasured + pendingDelta,
					"an index's pre-reanchor residency");
	entry->residencyBytesCommitted += measuredBytes;
	reservation->measuredBytes = measuredBytes;

	if (entry->residencyBytesCommitted > entry->residencyBudget)
		ereport(WARNING,
				(errmsg("database %u's residency budget is now exceeded after an insert into index %u",
						dbOid, relid),
				 errdetail("%llu bytes committed, %llu byte budget.",
						   (unsigned long long) entry->residencyBytesCommitted,
						   (unsigned long long) entry->residencyBudget)));

	if (insertReservation != NULL)
		FreeInsertReservation(insertReservation);

	LWLockRelease(&entry->memLock);
}

/*
 * A live PID can belong to a recycled process, not the original owner --
 * cross-check reservedAt against the current occupant's start time. An
 * unreadable start time counts as alive: a false "dead" verdict double-frees
 * bytes still in use, worse than leaving a live reservation one more cycle.
 */
static bool
OwnerPidIsDead(int ownerPid, TimestampTz reservedAt)
{
	PGPROC	   *proc;
	PgBackendStatus *beentry;

	if (ownerPid == 0)
		return false;

	proc = BackendPidGetProc(ownerPid);
	if (proc == NULL)
		return true;

	beentry = pgstat_get_beentry_by_proc_number(GetNumberFromPGProc(proc));
	if (beentry == NULL)
		return false;

	return beentry->st_proc_start_timestamp > reservedAt;
}

/*
 * Reclaims only RESERVED reservations -- a build a backend started but
 * never finished. CONFIRMED and RESIDENT both mean the build succeeded;
 * a dead owner there is never an abandoned build, since every path off of
 * CONFIRMED already releases it elsewhere: a clean error unwinds through
 * SvsMemoryAbortBuild before commit, and a backend crash forces a full
 * postmaster restart that wipes this shared memory outright. Reaping
 * CONFIRMED would instead delete a committed, on-disk index's reservation
 * the moment its building backend's ordinary post-commit disconnect makes
 * that stale PID look dead.
 *
 * For a RESERVED record, buildPeakBytes is always still outstanding --
 * only HandoffBuild/AbortBuild ever zero it -- so it is released here too,
 * against both the per-database and the global build counters. Without
 * this second release, a backend that crashes between ReserveBuild and
 * HandoffBuild would leak its build peak against svs.max_build_memory
 * forever, since neither the crashed backend nor anything else ever calls
 * SvsMemoryAbortBuild for it.
 */
static void
ReapEntryReservations(VamanaWorkerShmem *entry)
{
	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		SvsMemReservation *reservation = &entry->reservations[i];

		if (reservation->relid == InvalidOid)
			continue;
		if (reservation->state != SVS_MEM_RESERVED)
			continue;
		if (!OwnerPidIsDead(reservation->ownerPid, reservation->reservedAt))
			continue;

		SubtractFloored(&entry->residencyBytesCommitted, reservation->estimateBytes,
						 "a dead backend's build reservation");

		if (reservation->buildPeakBytes > 0)
		{
			SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
							 "a dead backend's build peak");
			SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
		}

		FreeReservation(reservation);
	}

	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
	{
		SvsMemInsertReservation *reservation = &entry->insertReservations[i];

		if (reservation->relid == InvalidOid)
			continue;
		if (!OwnerPidIsDead(reservation->ownerPid, reservation->reservedAt))
			continue;

		SubtractFloored(&entry->residencyBytesCommitted, reservation->deltaBytes,
						 "a dead backend's pending insert reservation");
		FreeInsertReservation(reservation);
	}

	LWLockRelease(&entry->memLock);
}

/*
 * Snapshots which databases currently hold a slot under one LW_SHARED pass
 * over the header, then processes each separately so memLock is always
 * acquired without the header lock already held -- the reverse of that
 * would invert Section 5.5's mandated "memLock before the header lock"
 * order, since ReapEntryReservations itself takes the header lock whenever
 * it releases a dead build peak.
 */
void
SvsMemoryReapDeadReservations(void)
{
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	int			numSlots = VamanaWorkerSlotCapacity();
	Oid		   *reservedDbOids = palloc(sizeof(Oid) * numSlots);
	int			numReserved = 0;

	LWLockAcquire(header->lock, LW_SHARED);
	for (int i = 0; i < numSlots; i++)
		if (OidIsValid(header->slots[i].dbOid))
			reservedDbOids[numReserved++] = header->slots[i].dbOid;
	LWLockRelease(header->lock);

	for (int i = 0; i < numReserved; i++)
	{
		VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(reservedDbOids[i]);

		if (entry != NULL)
			ReapEntryReservations(entry);
	}

	pfree(reservedDbOids);
}

bool
SvsMemoryReadStats(Oid dbOid, SvsMemoryStats *out)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);

	if (entry == NULL)
		return false;

	LWLockAcquire(&entry->memLock, LW_SHARED);

	if (entry->residencyBudget == 0)
	{
		LWLockRelease(&entry->memLock);
		return false;
	}

	out->residencyBudget = entry->residencyBudget;
	out->residencyBytesCommitted = entry->residencyBytesCommitted;
	out->buildBytesCommitted = entry->buildBytesCommitted;

	LWLockRelease(&entry->memLock);

	return true;
}

uint64
SvsMemorySearchScratchBytesPerQuery(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);
	SvsMemReservation *reservation;
	uint64		bytesPerQuery = 0;

	Assert(OidIsValid(relid));

	if (entry == NULL)
		return 0;

	LWLockAcquire(&entry->memLock, LW_SHARED);

	reservation = FindReservation(entry, relid);
	if (reservation != NULL)
		bytesPerQuery = reservation->searchScratchBytesPerQuery;

	LWLockRelease(&entry->memLock);

	return bytesPerQuery;
}

void
SvsMemoryRecheckSearchScratchOptions(Oid dbOid, Oid relid, int searchWindowSize,
									  bool useSearchHistory)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	if (entry == NULL)
		return;

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation != NULL)
	{
		if (reservation->cachedSearchWindowSize != searchWindowSize ||
			reservation->cachedUseSearchHistory != useSearchHistory)
			reservation->searchScratchBytesPerQuery = 0;

		reservation->cachedSearchWindowSize = searchWindowSize;
		reservation->cachedUseSearchHistory = useSearchHistory;
	}

	LWLockRelease(&entry->memLock);
}

uint64
SvsMemoryResolveResidencyBudget(const VamanaWorkerShmem *entry)
{
	int			overrideMb = entry->residencyMemoryMbOverride;
	int			resolvedMb = overrideMb > 0 ? overrideMb : vamana_default_residency_memory_mb;

	return (uint64) resolvedMb * 1024 * 1024;
}

uint64
SvsMemoryResolveSearchWorkMem(const VamanaWorkerShmem *entry)
{
	int			overrideMb = entry->searchWorkMemMbOverride;
	int			resolvedMb = overrideMb > 0 ? overrideMb : vamana_default_search_work_mem_mb;

	return (uint64) resolvedMb * 1024 * 1024;
}

/*
 * Called only from VamanaWorkerResetEntryState, at first construction (no
 * concurrent access possible yet) or slot release (caller already holds
 * the header lock exclusively and has ensured no worker or backend still
 * references entry). Must not acquire entry->memLock or the header lock
 * itself.
 */
void
SvsMemoryResetDatabaseAccounting(VamanaWorkerShmem *entry)
{
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();

	SubtractFloored(&header->totalBuildCommittedGlobal, entry->buildBytesCommitted,
					 "a released database's build commitment");
	SubtractFloored(&header->totalResidencyCommittedGlobal, entry->residencyBudget,
					 "a released database's residency budget");

	entry->residencyBudget = 0;
	entry->residencyBytesCommitted = 0;
	entry->buildBytesCommitted = 0;
	pg_atomic_write_u64(&entry->searchScratchBytesInFlight, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		entry->reservations[i].relid = InvalidOid;

	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
		entry->insertReservations[i].relid = InvalidOid;
}
