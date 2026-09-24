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
 * memLock.
 */

#include "postgres.h"

#include "commands/dbcommands.h"
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

/*
 * Call under entry->memLock; releases it and errors if dbOid was never
 * admitted.
 *
 * residencyBudget stays at exactly 0 for two reasons that call for opposite
 * responses. One is genuinely transient: admission runs as a backend-local
 * pre-commit callback keyed off the enrolling INSERT into vamana_databases,
 * so a slot can exist for a handful of statements, in the enrolling
 * backend's own transaction, before that callback lands. The other is a
 * standing misconfiguration: enrolling (an INSERT into vamana_databases, or
 * svs_restart_worker()) while connected to a database other than
 * svs.launcher_database still runs that same pre-commit callback and still
 * sets residencyBudget, from the enrolling backend's own connection, so it
 * does not actually leave this check at 0 -- the enrolled database's worker
 * simply never spawns, because the launcher only ever reads vamana_databases
 * from svs.launcher_database's copy of that table, and the enrolling row
 * lands in a different database's copy instead. dbOid carries no record of
 * which database its own enrolment ran from, so this function cannot detect
 * that failure; it can only warn about it. The warning is keyed on dbOid
 * itself not being svs.launcher_database, which is also the ordinary,
 * healthy shape of most enrolled databases, so it fires on both the rare
 * misconfiguration and the common transient window whenever dbOid is not
 * the launcher database. It is phrased as a follow-up to try if retrying
 * does not resolve the wait, not as a diagnosis.
 */
static void
RequireAdmitted(VamanaWorkerShmem *entry, Oid dbOid)
{
	char	   *dbname;
	bool		isLauncherDatabase;

	if (entry->residencyBudget != 0)
		return;

	dbname = get_database_name(dbOid);
	isLauncherDatabase = dbname != NULL &&
		strcmp(dbname, vamana_launcher_database) == 0;

	LWLockRelease(&entry->memLock);

	if (isLauncherDatabase)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("database %u has not completed SVS memory admission yet", dbOid),
				 errdetail("Admission runs synchronously when the enrolling transaction commits."),
				 errhint("Retry once it has.")));
	else
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("database %u has not completed SVS memory admission yet", dbOid),
				 errdetail("The enrolling INSERT into vamana_databases, or svs_restart_worker(), must run while connected to svs.launcher_database (currently \"%s\"), not database %u; enrolling from any other database is admitted but never gets a worker.",
						   vamana_launcher_database, dbOid),
				 errhint("Retry once the enrolling transaction has committed. If the wait does not clear, re-run the enrolment from svs.launcher_database.")));
}

static SvsMemReservation *
FindReservation(VamanaWorkerShmem *entry, Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		if (entry->reservations[i].relid == relid)
			return &entry->reservations[i];
	return NULL;
}

/*
 * Which operation is asking AllocateReservation for a fresh slot, purely to
 * pick the right exhaustion message: a build failing to reserve is the
 * build's own failure, but a load failing to reserve is a read hitting a
 * limit someone else's build (or this database's own resident indexes) is
 * responsible for, and the two must not read as the same failure.
 */
typedef enum SvsAllocationContext
{
	SVS_ALLOC_FOR_BUILD,
	SVS_ALLOC_FOR_LOAD,
} SvsAllocationContext;

/*
 * Call under entry->memLock; releases it and errors if no slot is free.
 *
 * On exhaustion, counts reservations in RESERVED/CONFIRMED/HANDOFF as
 * builds in progress: each is a not-yet-resident reservation that either
 * finishes into RESIDENT or aborts and frees its slot, so waiting on one is
 * a real, if not guaranteed, path to a free slot. RESIDENT and REBUILDING
 * both count on the other side, "steady-state occupancy": a RESIDENT
 * reservation already reached the table's real limit, and a REBUILDING one
 * reused its own already-RESIDENT slot to get there (SvsMemoryReserveBuild
 * never calls this function for a rebuild), so it does not free that slot
 * either way its rebuild ends. The two counts drive the errhint, not the
 * decision to error, which is unconditional on the table being full.
 */
static SvsMemReservation *
AllocateReservation(VamanaWorkerShmem *entry, Oid relid, SvsAllocationContext context)
{
	SvsMemReservation *freeSlot = FindReservation(entry, InvalidOid);

	if (freeSlot == NULL)
	{
		int			buildsInProgress = 0;

		for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		{
			SvsMemReservationState state = entry->reservations[i].state;

			if (state == SVS_MEM_RESERVED || state == SVS_MEM_CONFIRMED ||
				state == SVS_MEM_HANDOFF)
				buildsInProgress++;
		}

		LWLockRelease(&entry->memLock);

		if (context == SVS_ALLOC_FOR_LOAD)
		{
			if (buildsInProgress > 0)
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("cannot track index %u for load: too many concurrently tracked SVS indexes in this database", relid),
						 errdetail("VAMANA_MAX_INDEXES (%d) reservation slots are all in use, %d of them by in-progress builds.",
								   VAMANA_MAX_INDEXES, buildsInProgress),
						 errhint("This load did not fail on its own account. Wait for the in-progress builds to finish, or find out who is running them.")));
			else
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("cannot track index %u for load: too many concurrently tracked SVS indexes in this database", relid),
						 errdetail("VAMANA_MAX_INDEXES (%d) reservation slots are all in use, all of them by resident indexes.",
								   VAMANA_MAX_INDEXES),
						 errhint("This load did not fail on its own account. Reduce the number of indexes on this database, or accept the limit.")));
		}
		else
		{
			if (buildsInProgress > 0)
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("too many concurrently tracked SVS indexes for this database"),
						 errdetail("VAMANA_MAX_INDEXES (%d) reservation slots are all in use, %d of them by in-progress builds.",
								   VAMANA_MAX_INDEXES, buildsInProgress),
						 errhint("Wait for the in-progress builds to finish, or find out who is running them.")));
			else
				ereport(ERROR,
						(errcode(ERRCODE_PROGRAM_LIMIT_EXCEEDED),
						 errmsg("too many concurrently tracked SVS indexes for this database"),
						 errdetail("VAMANA_MAX_INDEXES (%d) reservation slots are all in use, all of them by resident indexes.",
								   VAMANA_MAX_INDEXES),
						 errhint("Reduce the number of indexes on this database, or accept the limit.")));
		}
	}

	*freeSlot = (SvsMemReservation) {0};
	freeSlot->relid = relid;
	return freeSlot;
}

static void
FreeReservation(SvsMemReservation *reservation)
{
	reservation->relid = InvalidOid;
}

/*
 * Returns a REBUILDING reservation to RESIDENT at exactly the size it held
 * before the rebuild began, on every path off of REBUILDING other than a
 * successful confirm. residencyBytesCommitted already counts these bytes as
 * resident, and has done so continuously since the RESIDENT -> REBUILDING
 * transition, so this touches only the reservation's own fields, never the
 * counter. Callers release buildPeakBytes against the build counters
 * themselves, immediately before calling this, so this only zeroes the
 * field in place -- a RESIDENT reservation never holds an outstanding build
 * peak, and the reaper must not release the same bytes again on a later
 * cycle.
 */
static void
RestorePriorResidency(VamanaWorkerShmem *entry, SvsMemReservation *reservation)
{
	Assert(reservation->state == SVS_MEM_REBUILDING);
	Assert(reservation->priorResidentBytes <= entry->residencyBytesCommitted);

	reservation->measuredBytes = reservation->priorResidentBytes;
	reservation->priorResidentBytes = 0;
	reservation->ownerPid = 0;
	reservation->buildPeakBytes = 0;
	reservation->state = SVS_MEM_RESIDENT;
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

static SvsMemInsertReservation *
FindInsertReservationByOwner(VamanaWorkerShmem *entry, Oid relid, int ownerPid)
{
	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
	{
		SvsMemInsertReservation *candidate = &entry->insertReservations[i];

		if (candidate->relid == relid && candidate->ownerPid == ownerPid)
			return candidate;
	}
	return NULL;
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

/* Caller holds entry->memLock. A no-op if relid has no pending insert reservation. */
static void
ReleaseOldestInsertReservation(VamanaWorkerShmem *entry, Oid relid)
{
	SvsMemInsertReservation *reservation = FindOldestInsertReservation(entry, relid);

	if (reservation != NULL)
	{
		SubtractFloored(&entry->residencyBytesCommitted, reservation->deltaBytes,
						 "a released pending insert reservation");
		FreeInsertReservation(reservation);
	}
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
SvsMemoryAdmitDatabase(Oid dbOid, uint64 residencyBudget, uint64 durableCommittedFloor)
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

	{
		uint64		committedFloor = Max(entry->residencyBytesCommitted, durableCommittedFloor);

		if (residencyBudget < committedFloor)
		{
			LWLockRelease(&entry->memLock);
			ereport(ERROR,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("database %u's residency budget cannot be lowered below its already-committed bytes",
							dbOid),
					 errdetail("Requested %llu byte budget, %llu bytes already committed.",
							   (unsigned long long) residencyBudget,
							   (unsigned long long) committedFloor)));
		}
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

/* No ceiling re-check here: already-committed bytes must never be stranded, even if that leaves the total over svs.max_residency_memory until the next admission. */
void
SvsMemoryRestoreResidencyBudget(Oid dbOid, uint64 priorBudget)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	uint64		restoredBudget;
	uint64		projectedGlobalTotal;

	if (entry == NULL)
		return;

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	restoredBudget = Max(priorBudget, entry->residencyBytesCommitted);
	if (restoredBudget != priorBudget)
		ereport(WARNING,
				(errmsg("SVS memory accounting: database %u's residency budget restored to %llu bytes on transaction abort, not its pre-transaction %llu, to cover bytes already committed under the aborted value",
						dbOid,
						(unsigned long long) restoredBudget,
						(unsigned long long) priorBudget)));

	LWLockAcquire(header->lock, LW_EXCLUSIVE);

	projectedGlobalTotal = header->totalResidencyCommittedGlobal;
	SubtractFloored(&projectedGlobalTotal, entry->residencyBudget,
					 "a database's aborted residency budget change");
	header->totalResidencyCommittedGlobal = projectedGlobalTotal + restoredBudget;
	entry->residencyBudget = restoredBudget;

	LWLockRelease(header->lock);
	LWLockRelease(&entry->memLock);
}

void
SvsMemoryReserveBuild(Oid dbOid, Oid relid, uint64 buildPeak, uint64 residencyEstimate)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *existing;
	SvsMemReservation *reservation;
	bool		isRebuild;
	uint64		priorResidentBytes = 0;
	uint64		residencyBaseline;
	bool		fits;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	RequireAdmitted(entry, dbOid);

	existing = FindReservation(entry, relid);
	isRebuild = existing != NULL && existing->state == SVS_MEM_RESIDENT;

	if (existing != NULL && !isRebuild)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("index %u in database %u already has an SVS memory reservation",
						relid, dbOid)));
	}

	/*
	 * A RESIDENT reservation for relid means a rebuild (REINDEX, or a
	 * worker-restart rebuild of an index whose reservation survived the
	 * restart), not a fresh build: the same relid's earlier load is still
	 * fully resident. Hold its prior bytes aside rather than folding them
	 * out of residencyBytesCommitted here, so the counter never understates
	 * what is genuinely resident for as long as the rebuild is in progress;
	 * a concurrent load elsewhere in the database can therefore consume the
	 * headroom this rebuild is counting on, and the rebuild then fails at
	 * confirm rather than here. That is the correct trade, since the
	 * alternative is a counter that understates live residency for the
	 * whole duration of a long rebuild.
	 */
	if (isRebuild)
	{
		residencyBaseline = entry->residencyBytesCommitted;
		priorResidentBytes = existing->measuredBytes;
		SubtractFloored(&residencyBaseline, priorResidentBytes,
						 "a rebuild's prior resident bytes");
	}
	else
		residencyBaseline = entry->residencyBytesCommitted;

	fits = residencyBaseline + residencyEstimate <= entry->residencyBudget;

	if (!fits)
	{
		uint64		budget = entry->residencyBudget;

		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("build of index %u would exceed database %u's residency budget", relid, dbOid),
				 errdetail("Requested %llu bytes, %llu already committed, %llu byte budget.",
						   (unsigned long long) residencyEstimate,
						   (unsigned long long) residencyBaseline,
						   (unsigned long long) budget)));
	}

	/*
	 * Claim the reservation slot before touching any counter, so a full
	 * reservation table leaves every counter untouched. A rebuild reuses its
	 * existing slot instead of claiming a new one, so the table can never be
	 * full on that path.
	 */
	reservation = isRebuild ? existing : AllocateReservation(entry, relid, SVS_ALLOC_FOR_BUILD);

	if (!TryAddGlobalBuildCommitted(buildPeak))
	{
		if (!isRebuild)
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
	/* A rebuild's prior resident bytes stay committed; nothing new is added
	 * here for that case, only for a fresh build's estimate. */
	if (!isRebuild)
		entry->residencyBytesCommitted += residencyEstimate;

	reservation->ownerPid = MyProcPid;
	reservation->reservedAt = GetCurrentTimestamp();
	reservation->estimateBytes = residencyEstimate;
	reservation->measuredBytes = 0;
	reservation->buildPeakBytes = buildPeak;
	reservation->priorResidentBytes = priorResidentBytes;
	reservation->state = isRebuild ? SVS_MEM_REBUILDING : SVS_MEM_RESERVED;

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryConfirmBuild(Oid dbOid, Oid relid, uint64 buildPeak, uint64 measuredResidencyBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;
	uint64		residencyWithoutPrior;
	uint64		priorContribution;
	bool		isRebuild;
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

	/*
	 * A reservation can only be pending confirmation in RESERVED (a fresh
	 * build) or REBUILDING (a rebuild). Any other state means something
	 * else already finished it -- most notably, ReconcileLoad's own
	 * independent load can claim a REBUILDING record straight to RESIDENT
	 * ahead of this call. Confirming against that record would fold out
	 * its stale estimateBytes instead of its real committed measuredBytes,
	 * and stamp it CONFIRMED with no owner. Error instead of guessing.
	 */
	if (reservation->state != SVS_MEM_RESERVED && reservation->state != SVS_MEM_REBUILDING)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("build reservation for index %u in database %u is not pending confirmation",
						relid, dbOid)));
	}

	isRebuild = reservation->state == SVS_MEM_REBUILDING;

	SubtractFloored(&entry->buildBytesCommitted, buildPeak, "a build peak");
	SubtractGlobalBuildCommitted(buildPeak);

	/* The build peak above is now released; the reaper must not release it again. */
	reservation->buildPeakBytes = 0;

	/*
	 * A fresh build's committed bytes include its estimate, added by
	 * ReserveBuild; a rebuild's committed bytes never got its estimate
	 * added at all and instead still hold its prior resident measurement,
	 * left there by ReserveBuild on purpose. Either way, this is the
	 * contribution to fold out before testing the newly measured size.
	 */
	priorContribution = isRebuild ? reservation->priorResidentBytes : reservation->estimateBytes;

	residencyWithoutPrior = entry->residencyBytesCommitted;
	SubtractFloored(&residencyWithoutPrior, priorContribution, "a build handoff's prior residency contribution");
	fits = residencyWithoutPrior + measuredResidencyBytes <= entry->residencyBudget;

	if (fits)
	{
		entry->residencyBytesCommitted = residencyWithoutPrior + measuredResidencyBytes;
		reservation->state = SVS_MEM_CONFIRMED;
		reservation->measuredBytes = measuredResidencyBytes;
		reservation->priorResidentBytes = 0;
	}
	else if (isRebuild)
	{
		/*
		 * The old graph is still fully resident and on disk; the failed
		 * rebuild attempt must not strip its accounting, only give up its
		 * own new estimate.
		 */
		RestorePriorResidency(entry, reservation);
	}
	else
	{
		entry->residencyBytesCommitted = residencyWithoutPrior;
		FreeReservation(reservation);
	}

	LWLockRelease(&entry->memLock);

	return fits;
}

void
SvsMemoryHandoffBuild(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation == NULL)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("no confirmed build reservation for index %u in database %u", relid, dbOid)));
	}

	if (reservation->state != SVS_MEM_CONFIRMED)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("build reservation for index %u in database %u is not confirmed, cannot hand off", relid, dbOid)));
	}
	reservation->state = SVS_MEM_HANDOFF;

	LWLockRelease(&entry->memLock);
}

void
SvsMemoryAbortBuild(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);

	/*
	 * A RESIDENT reservation already belongs to the database, handed off by
	 * SvsMemoryReconcileLoad; only SvsMemoryAccountUnload may release it.
	 * This function is reached in that state when a synchronous warm-up
	 * load succeeds and a later statement in the same build transaction
	 * still fails, so leave the reservation exactly as it is.
	 */
	if (reservation != NULL && reservation->state != SVS_MEM_RESIDENT)
	{
		/*
		 * CREATE INDEX's relation lock keeps any other backend out of
		 * RESERVED/CONFIRMED/HANDOFF/REBUILDING for this relid, so only the
		 * reserving backend can ever reach this branch for it.
		 */
		Assert(reservation->ownerPid == MyProcPid);

		if (reservation->buildPeakBytes > 0)
		{
			SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
							 "a build peak");
			SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
		}

		if (reservation->state == SVS_MEM_REBUILDING)
		{
			/*
			 * The old graph is still fully resident and on disk; an
			 * aborted rebuild must give back only its own new estimate,
			 * never the bytes the database already held before it started.
			 */
			RestorePriorResidency(entry, reservation);
		}
		else
		{
			uint64		residencyHeld = (reservation->state == SVS_MEM_RESERVED) ?
				reservation->estimateBytes : reservation->measuredBytes;

			SubtractFloored(&entry->residencyBytesCommitted, residencyHeld,
							 "an aborted build's residency reservation");
			FreeReservation(reservation);
		}
	}

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryReconcileLoad(Oid dbOid, Oid relid, uint64 measuredBytes, uint64 capacityHeadroomVectors)
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
		uint64		priorContribution;
		uint64		residencyWithoutPrior;

		/*
		 * RESERVED's committed contribution is its estimate; REBUILDING's is
		 * priorResidentBytes, since ReserveBuild never adds a rebuild's
		 * estimate to residencyBytesCommitted at all; every other state's is
		 * its measured size.
		 */
		if (reservation->state == SVS_MEM_RESERVED)
			priorContribution = reservation->estimateBytes;
		else if (reservation->state == SVS_MEM_REBUILDING)
			priorContribution = reservation->priorResidentBytes;
		else
			priorContribution = reservation->measuredBytes;

		residencyWithoutPrior = entry->residencyBytesCommitted;

		SubtractFloored(&residencyWithoutPrior, priorContribution,
						 "a load reconcile's prior contribution");
		fits = residencyWithoutPrior + measuredBytes <= entry->residencyBudget;

		if (fits)
		{
			/*
			 * A REBUILDING record reaching here ahead of its own Confirm
			 * still owes the RESIDENT convention: no outstanding build peak,
			 * no leftover prior-residency figure.
			 */
			if (reservation->state == SVS_MEM_REBUILDING && reservation->buildPeakBytes > 0)
			{
				SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
								 "a build peak");
				SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
			}

			entry->residencyBytesCommitted = residencyWithoutPrior + measuredBytes;
			reservation->state = SVS_MEM_RESIDENT;
			reservation->ownerPid = 0;
			reservation->measuredBytes = measuredBytes;
			reservation->capacityHeadroomVectors = capacityHeadroomVectors;
			reservation->priorResidentBytes = 0;
			reservation->buildPeakBytes = 0;
		}
	}
	else
	{
		fits = entry->residencyBytesCommitted + measuredBytes <= entry->residencyBudget;

		if (fits)
		{
			reservation = AllocateReservation(entry, relid, SVS_ALLOC_FOR_LOAD);
			reservation->state = SVS_MEM_RESIDENT;
			reservation->ownerPid = 0;
			reservation->reservedAt = GetCurrentTimestamp();
			reservation->estimateBytes = measuredBytes;
			reservation->measuredBytes = measuredBytes;
			reservation->capacityHeadroomVectors = capacityHeadroomVectors;

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
	uint64		residencyHeld;

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

	/*
	 * A REBUILDING record's committed contribution is priorResidentBytes,
	 * not measuredBytes -- measuredBytes stays 0 until a rebuild confirms.
	 * Its build peak, otherwise only released by
	 * ConfirmBuild/AbortBuild/the reaper, must be released here too, since
	 * dropping the index takes the in-flight rebuild down with it.
	 */
	if (reservation->state == SVS_MEM_REBUILDING)
	{
		residencyHeld = reservation->priorResidentBytes;
		if (reservation->buildPeakBytes > 0)
		{
			SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
							 "a build peak");
			SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
		}
	}
	else
		residencyHeld = reservation->measuredBytes;

	SubtractFloored(&entry->residencyBytesCommitted, residencyHeld,
					"an unloaded index's residency");
	FreeReservation(reservation);

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryReserveInsert(Oid dbOid, Oid relid, uint64 deltaBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *resident;
	SvsMemInsertReservation *reservation;
	bool		consumesHeadroom;
	uint64		chargeBytes;
	bool		fits;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	RequireAdmitted(entry, dbOid);

	resident = FindReservation(entry, relid);
	consumesHeadroom = resident != NULL && resident->capacityHeadroomVectors > 0;
	chargeBytes = consumesHeadroom ? 0 : deltaBytes;

	fits = entry->residencyBytesCommitted + chargeBytes <= entry->residencyBudget;
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
		reservation->deltaBytes = chargeBytes;
		reservation->consumedHeadroom = consumesHeadroom;

		entry->residencyBytesCommitted += chargeBytes;
		if (consumesHeadroom)
			resident->capacityHeadroomVectors--;
	}

	LWLockRelease(&entry->memLock);

	return fits;
}

static SvsMemReservation *
FindResidentReservationOrError(VamanaWorkerShmem *entry, Oid dbOid, Oid relid,
								const char *action)
{
	SvsMemReservation *reservation = FindReservation(entry, relid);

	if (reservation == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("no resident reservation for index %u in database %u to %s",
						relid, dbOid, action)));

	return reservation;
}

static void
WarnIfResidencyOverBudget(VamanaWorkerShmem *entry, Oid dbOid, Oid relid, const char *afterWhat)
{
	if (entry->residencyBytesCommitted > entry->residencyBudget)
		ereport(WARNING,
				(errmsg("database %u's residency budget is now exceeded after %s index %u",
						dbOid, afterWhat, relid),
				 errdetail("%llu bytes committed, %llu byte budget.",
						   (unsigned long long) entry->residencyBytesCommitted,
						   (unsigned long long) entry->residencyBudget)));
}

void
SvsMemoryReanchorInsert(Oid dbOid, Oid relid, uint64 measuredBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindResidentReservationOrError(entry, dbOid, relid, "reanchor");

	SubtractFloored(&entry->residencyBytesCommitted, reservation->measuredBytes,
					"an index's pre-reanchor residency");
	ReleaseOldestInsertReservation(entry, relid);
	entry->residencyBytesCommitted += measuredBytes;
	reservation->measuredBytes = measuredBytes;

	WarnIfResidencyOverBudget(entry, dbOid, relid, "an insert into");

	LWLockRelease(&entry->memLock);
}

void
SvsMemoryReconcileResident(Oid dbOid, Oid relid, uint64 measuredBytes,
						   uint64 capacityHeadroomVectors)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindResidentReservationOrError(entry, dbOid, relid, "reconcile");
	if (reservation->state != SVS_MEM_RESIDENT)
	{
		LWLockRelease(&entry->memLock);
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("reservation for index %u in database %u is not resident, cannot reconcile",
						relid, dbOid)));
	}

	SubtractFloored(&entry->residencyBytesCommitted, reservation->measuredBytes,
					"an index's pre-reconcile residency");
	entry->residencyBytesCommitted += measuredBytes;
	reservation->measuredBytes = measuredBytes;
	reservation->capacityHeadroomVectors = capacityHeadroomVectors;

	WarnIfResidencyOverBudget(entry, dbOid, relid, "a compact of");

	LWLockRelease(&entry->memLock);
}

/*
 * Closes out the pending insert reservation vamanainsert() opened for relid,
 * once its bytes are already accounted for under a reservation created by
 * SvsMemoryReconcileLoad rather than an existing one, as SvsMemoryReanchorInsert
 * assumes.
 */
void
SvsMemoryCloseInsertReservation(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);
	ReleaseOldestInsertReservation(entry, relid);
	LWLockRelease(&entry->memLock);
}

void
SvsMemoryAbortInsert(Oid dbOid, Oid relid)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	SvsMemInsertReservation *reservation;

	Assert(OidIsValid(relid));

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindInsertReservationByOwner(entry, relid, MyProcPid);
	if (reservation != NULL)
	{
		SubtractFloored(&entry->residencyBytesCommitted, reservation->deltaBytes,
						"an aborted pending insert reservation");
		if (reservation->consumedHeadroom)
		{
			SvsMemReservation *resident = FindReservation(entry, relid);

			if (resident != NULL)
				resident->capacityHeadroomVectors++;
		}
		FreeInsertReservation(reservation);
	}

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
 * Reclaims only RESERVED and REBUILDING reservations -- a build, or a
 * rebuild, a backend started but never finished. CONFIRMED, HANDOFF, and
 * RESIDENT all mean the build (or rebuild) succeeded; a dead owner there is
 * never an abandoned build, since every path off of CONFIRMED already
 * releases it elsewhere: a clean error unwinds through SvsMemoryAbortBuild
 * before commit, and a backend crash forces a full postmaster restart that
 * wipes this shared memory outright. Reaping CONFIRMED or HANDOFF would
 * instead delete a committed, on-disk index's reservation the moment its
 * building backend's ordinary post-commit disconnect makes that stale PID
 * look dead.
 *
 * For a RESERVED record, buildPeakBytes is always still outstanding --
 * only ConfirmBuild/AbortBuild ever zero it -- so it is released here too,
 * against both the per-database and the global build counters. Without
 * this second release, a backend that crashes between ReserveBuild and
 * ConfirmBuild would leak its build peak against svs.max_build_memory
 * forever, since neither the crashed backend nor anything else ever calls
 * SvsMemoryAbortBuild for it.
 *
 * A REBUILDING record's buildPeakBytes is released the same way, but its
 * residency bytes are not touched at all: ReserveBuild never added anything
 * to residencyBytesCommitted for a rebuild, so there is nothing to give
 * back. RestorePriorResidency instead just returns the reservation to
 * RESIDENT at its pre-rebuild measured size, the same restoration a live
 * backend's own AbortBuild would have performed; a dead owner mid-rebuild
 * must leave the old, still-resident graph's bytes correctly committed, not
 * leaked and not deleted.
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
		if (reservation->state != SVS_MEM_RESERVED &&
			reservation->state != SVS_MEM_REBUILDING)
			continue;
		if (!OwnerPidIsDead(reservation->ownerPid, reservation->reservedAt))
			continue;

		if (reservation->buildPeakBytes > 0)
		{
			SubtractFloored(&entry->buildBytesCommitted, reservation->buildPeakBytes,
							 "a dead backend's build peak");
			SubtractGlobalBuildCommitted(reservation->buildPeakBytes);
		}

		if (reservation->state == SVS_MEM_REBUILDING)
			RestorePriorResidency(entry, reservation);
		else
		{
			SubtractFloored(&entry->residencyBytesCommitted, reservation->estimateBytes,
							 "a dead backend's build reservation");
			FreeReservation(reservation);
		}
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

static bool
OidInArray(Oid relid, const Oid *array, int count)
{
	for (int i = 0; i < count; i++)
		if (array[i] == relid)
			return true;
	return false;
}

void
SvsMemoryReconcileResidentReservations(Oid dbOid, const Oid *liveRelids, int numLiveRelids,
										Oid *droppedRelids, int *numDropped)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);

	*numDropped = 0;

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		SvsMemReservation *reservation = &entry->reservations[i];

		if (reservation->relid == InvalidOid)
			continue;
		if (reservation->state != SVS_MEM_RESIDENT)
			continue;
		if (OidInArray(reservation->relid, liveRelids, numLiveRelids))
			continue;

		SubtractFloored(&entry->residencyBytesCommitted, reservation->measuredBytes,
						 "a dropped index's stale resident reservation");
		droppedRelids[(*numDropped)++] = reservation->relid;
		FreeReservation(reservation);
	}

	LWLockRelease(&entry->memLock);
}

/*
 * Snapshots which databases currently hold a slot under one LW_SHARED pass
 * over the header, then processes each separately so memLock is always
 * acquired without the header lock already held -- the reverse of that
 * would invert the mandated "memLock before the header lock" order, since
 * ReapEntryReservations itself takes the header lock whenever it releases a
 * dead build peak.
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

void
SvsMemorySetSearchScratchBytesPerQuery(Oid dbOid, Oid relid, uint64 bytesPerQuery)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(dbOid);
	SvsMemReservation *reservation;

	Assert(OidIsValid(relid));

	if (entry == NULL)
		return;

	LWLockAcquire(&entry->memLock, LW_EXCLUSIVE);

	reservation = FindReservation(entry, relid);
	if (reservation != NULL)
		reservation->searchScratchBytesPerQuery = bytesPerQuery;

	LWLockRelease(&entry->memLock);
}

bool
SvsMemoryReserveSearchScratch(Oid dbOid, uint64 batchBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	uint64		budget;
	uint64		current;

	/* searchWorkMemMbOverride is guarded by the header lock, not memLock. */
	LWLockAcquire(header->lock, LW_SHARED);
	budget = SvsMemoryResolveSearchWorkMem(entry);
	LWLockRelease(header->lock);

	current = pg_atomic_read_u64(&entry->searchScratchBytesInFlight);
	for (;;)
	{
		if (current + batchBytes > budget)
			return false;

		if (pg_atomic_compare_exchange_u64(&entry->searchScratchBytesInFlight,
											&current, current + batchBytes))
			return true;

		/* CAS failure refreshed current to the live value; retry against it. */
	}
}

void
SvsMemoryReleaseSearchScratch(Oid dbOid, uint64 batchBytes)
{
	VamanaWorkerShmem *entry = LookupEntryOrError(dbOid);
	uint64		before = pg_atomic_read_u64(&entry->searchScratchBytesInFlight);

	for (;;)
	{
		uint64		updated = (batchBytes > before) ? 0 : before - batchBytes;

		if (pg_atomic_compare_exchange_u64(&entry->searchScratchBytesInFlight,
											&before, updated))
			break;
	}

	if (batchBytes > before)
		ereport(WARNING,
				(errmsg("SVS search-scratch accounting underflow releasing database %u: "
						"releasing %llu bytes but only %llu in flight",
						dbOid,
						(unsigned long long) batchBytes, (unsigned long long) before)));
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
