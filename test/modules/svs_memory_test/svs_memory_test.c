/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_memory_test.c
 *
 * SQL-callable driver for svs_memory's accounting API, so pg_regress can
 * assert on it. Not part of the svs extension; never installed alongside
 * it.
 */

#include "postgres.h"

#include "funcapi.h"
#include "utils/builtins.h"

#include "svs_memory.h"
#include "vamanaworker.h"

PG_MODULE_MAGIC;

static uint64
GetNonNegativeArgAsUint64(PG_FUNCTION_ARGS, int argnum)
{
	int64		value = PG_GETARG_INT64(argnum);

	if (value < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("byte argument %d must not be negative", argnum)));

	return (uint64) value;
}

static const char *
ReservationStateName(SvsMemReservationState state)
{
	switch (state)
	{
		case SVS_MEM_RESERVED:
			return "RESERVED";
		case SVS_MEM_CONFIRMED:
			return "CONFIRMED";
		case SVS_MEM_HANDOFF:
			return "HANDOFF";
		case SVS_MEM_RESIDENT:
			return "RESIDENT";
	}
	return "UNKNOWN";
}

static SvsMemReservation *
FindTestReservation(VamanaWorkerShmem *entry, Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		if (entry->reservations[i].relid == relid)
			return &entry->reservations[i];
	return NULL;
}

/*
 * Several pending insert reservations can share a relid, so unlike
 * FindTestReservation this also matches on deltaBytes to pick out one of
 * them for owner-pid faking in a test.
 */
static SvsMemInsertReservation *
FindTestInsertReservation(VamanaWorkerShmem *entry, Oid relid, uint64 deltaBytes)
{
	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
	{
		SvsMemInsertReservation *r = &entry->insertReservations[i];

		if (r->relid == relid && r->deltaBytes == deltaBytes)
			return r;
	}
	return NULL;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_build_ceiling_bytes);
Datum
svs_memory_test_build_ceiling_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) vamana_max_build_memory_mb * 1024 * 1024);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_residency_ceiling_bytes);
Datum
svs_memory_test_residency_ceiling_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) vamana_max_residency_memory_mb * 1024 * 1024);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_global_build_committed_bytes);
Datum
svs_memory_test_global_build_committed_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) VamanaWorkerHeader()->totalBuildCommittedGlobal);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_global_residency_committed_bytes);
Datum
svs_memory_test_global_residency_committed_bytes(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) VamanaWorkerHeader()->totalResidencyCommittedGlobal);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_reservations);
Datum
svs_memory_test_reservations(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		SvsMemReservation *r = &entry->reservations[i];
		Datum		values[7];
		bool		nulls[7] = {false, false, false, false, false, false, false};

		if (r->relid == InvalidOid)
			continue;

		values[0] = ObjectIdGetDatum(r->relid);
		values[1] = CStringGetTextDatum(ReservationStateName(r->state));
		values[2] = Int32GetDatum((int32) r->ownerPid);
		values[3] = Int64GetDatum((int64) r->estimateBytes);
		values[4] = Int64GetDatum((int64) r->measuredBytes);
		values[5] = Int64GetDatum((int64) r->buildPeakBytes);
		if (r->searchScratchBytesPerQuery != 0)
			values[6] = Int64GetDatum((int64) r->searchScratchBytesPerQuery);
		else
			nulls[6] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_insert_reservations);
Datum
svs_memory_test_insert_reservations(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (int i = 0; i < SVS_MAX_PENDING_INSERT_RESERVATIONS; i++)
	{
		SvsMemInsertReservation *r = &entry->insertReservations[i];
		Datum		values[3];
		bool		nulls[3] = {false, false, false};

		if (r->relid == InvalidOid)
			continue;

		values[0] = ObjectIdGetDatum(r->relid);
		values[1] = Int32GetDatum((int32) r->ownerPid);
		values[2] = Int64GetDatum((int64) r->deltaBytes);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_set_owner_pid);
Datum
svs_memory_test_set_owner_pid(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));
	Oid			relid = PG_GETARG_OID(1);
	SvsMemReservation *reservation = FindTestReservation(entry, relid);

	if (reservation == NULL)
		ereport(ERROR,
				(errmsg("no reservation for index %u in database %u", relid,
						PG_GETARG_OID(0))));

	reservation->ownerPid = PG_GETARG_INT32(2);
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_set_insert_reservation_owner_pid);
Datum
svs_memory_test_set_insert_reservation_owner_pid(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));
	Oid			relid = PG_GETARG_OID(1);
	uint64		deltaBytes = GetNonNegativeArgAsUint64(fcinfo, 2);
	SvsMemInsertReservation *reservation = FindTestInsertReservation(entry, relid, deltaBytes);

	if (reservation == NULL)
		ereport(ERROR,
				(errmsg("no pending insert reservation for index %u in database %u with delta %llu",
						relid, PG_GETARG_OID(0), (unsigned long long) deltaBytes)));

	reservation->ownerPid = PG_GETARG_INT32(3);
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_reset_database_accounting);
Datum
svs_memory_test_reset_database_accounting(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));

	SvsMemoryResetDatabaseAccounting(entry);
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_resolve_residency_budget);
Datum
svs_memory_test_resolve_residency_budget(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));

	PG_RETURN_INT64((int64) SvsMemoryResolveResidencyBudget(entry));
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_resolve_search_work_mem);
Datum
svs_memory_test_resolve_search_work_mem(PG_FUNCTION_ARGS)
{
	VamanaWorkerShmem *entry = VamanaWorkerLookupSlot(PG_GETARG_OID(0));

	PG_RETURN_INT64((int64) SvsMemoryResolveSearchWorkMem(entry));
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_residency_budget);
Datum
svs_memory_test_residency_budget(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT64((int64) SvsMemoryResidencyBudget(PG_GETARG_OID(0)));
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_search_scratch_bytes_per_query);
Datum
svs_memory_test_search_scratch_bytes_per_query(PG_FUNCTION_ARGS)
{
	uint64		bytesPerQuery = SvsMemorySearchScratchBytesPerQuery(PG_GETARG_OID(0),
																	  PG_GETARG_OID(1));

	if (bytesPerQuery == 0)
		PG_RETURN_NULL();
	PG_RETURN_INT64((int64) bytesPerQuery);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_recheck_search_scratch_options);
Datum
svs_memory_test_recheck_search_scratch_options(PG_FUNCTION_ARGS)
{
	SvsMemoryRecheckSearchScratchOptions(PG_GETARG_OID(0), PG_GETARG_OID(1),
										  PG_GETARG_INT32(2), PG_GETARG_BOOL(3));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_set_search_scratch_bytes_per_query);
Datum
svs_memory_test_set_search_scratch_bytes_per_query(PG_FUNCTION_ARGS)
{
	SvsMemorySetSearchScratchBytesPerQuery(PG_GETARG_OID(0), PG_GETARG_OID(1),
											(uint64) PG_GETARG_INT64(2));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_admit_database);
Datum
svs_memory_admit_database(PG_FUNCTION_ARGS)
{
	SvsMemoryAdmitDatabase(PG_GETARG_OID(0), GetNonNegativeArgAsUint64(fcinfo, 1),
							GetNonNegativeArgAsUint64(fcinfo, 2));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_restore_residency_budget);
Datum
svs_memory_restore_residency_budget(PG_FUNCTION_ARGS)
{
	SvsMemoryRestoreResidencyBudget(PG_GETARG_OID(0), GetNonNegativeArgAsUint64(fcinfo, 1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reserve_build);
Datum
svs_memory_reserve_build(PG_FUNCTION_ARGS)
{
	SvsMemoryReserveBuild(PG_GETARG_OID(0), PG_GETARG_OID(1),
						   GetNonNegativeArgAsUint64(fcinfo, 2),
						   GetNonNegativeArgAsUint64(fcinfo, 3));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_confirm_build);
Datum
svs_memory_confirm_build(PG_FUNCTION_ARGS)
{
	bool		confirmed = SvsMemoryConfirmBuild(PG_GETARG_OID(0), PG_GETARG_OID(1),
												   GetNonNegativeArgAsUint64(fcinfo, 2),
												   GetNonNegativeArgAsUint64(fcinfo, 3));

	PG_RETURN_BOOL(confirmed);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_handoff_build);
Datum
svs_memory_handoff_build(PG_FUNCTION_ARGS)
{
	SvsMemoryHandoffBuild(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_abort_build);
Datum
svs_memory_abort_build(PG_FUNCTION_ARGS)
{
	SvsMemoryAbortBuild(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reconcile_load);
Datum
svs_memory_reconcile_load(PG_FUNCTION_ARGS)
{
	bool		fits = SvsMemoryReconcileLoad(PG_GETARG_OID(0), PG_GETARG_OID(1),
											  GetNonNegativeArgAsUint64(fcinfo, 2));

	PG_RETURN_BOOL(fits);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_account_unload);
Datum
svs_memory_account_unload(PG_FUNCTION_ARGS)
{
	SvsMemoryAccountUnload(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reserve_insert);
Datum
svs_memory_reserve_insert(PG_FUNCTION_ARGS)
{
	bool		fits = SvsMemoryReserveInsert(PG_GETARG_OID(0), PG_GETARG_OID(1),
											  GetNonNegativeArgAsUint64(fcinfo, 2));

	PG_RETURN_BOOL(fits);
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reanchor_insert);
Datum
svs_memory_reanchor_insert(PG_FUNCTION_ARGS)
{
	SvsMemoryReanchorInsert(PG_GETARG_OID(0), PG_GETARG_OID(1),
							 GetNonNegativeArgAsUint64(fcinfo, 2));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_abort_insert);
Datum
svs_memory_abort_insert(PG_FUNCTION_ARGS)
{
	SvsMemoryAbortInsert(PG_GETARG_OID(0), PG_GETARG_OID(1));
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_reap_dead_reservations);
Datum
svs_memory_reap_dead_reservations(PG_FUNCTION_ARGS)
{
	SvsMemoryReapDeadReservations();
	PG_RETURN_VOID();
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_read_stats);
Datum
svs_memory_read_stats(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	SvsMemoryStats stats;

	InitMaterializedSRF(fcinfo, 0);

	if (SvsMemoryReadStats(PG_GETARG_OID(0), &stats))
	{
		Datum		values[3];
		bool		nulls[3] = {false, false, false};

		values[0] = Int64GetDatum((int64) stats.residencyBudget);
		values[1] = Int64GetDatum((int64) stats.residencyBytesCommitted);
		values[2] = Int64GetDatum((int64) stats.buildBytesCommitted);

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

static void PushInvariantViolation(ReturnSetInfo *rsinfo, Oid dbOid, const char *fmt,...) pg_attribute_printf(3, 4);

static void
PushInvariantViolation(ReturnSetInfo *rsinfo, Oid dbOid, const char *fmt,...)
{
	StringInfoData buf;
	Datum		values[2];
	bool		nulls[2] = {false, false};

	initStringInfo(&buf);

	for (;;)
	{
		va_list		args;
		int			needed;

		va_start(args, fmt);
		needed = appendStringInfoVA(&buf, fmt, args);
		va_end(args);

		if (needed == 0)
			break;
		enlargeStringInfo(&buf, needed);
	}

	if (OidIsValid(dbOid))
		values[0] = ObjectIdGetDatum(dbOid);
	else
		nulls[0] = true;
	values[1] = CStringGetTextDatum(buf.data);

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	pfree(buf.data);
}

/*
 * A reported overage is not always a bug: ReanchorInsert warns but allows
 * one. The caller, not this function, knows whether that's the case here.
 */
PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_memory_test_check_invariants);
Datum
svs_memory_test_check_invariants(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	VamanaWorkerShmemHeader *header = VamanaWorkerHeader();
	uint64		residencyBudgetSum = 0;
	uint64		buildCommittedSum = 0;

	InitMaterializedSRF(fcinfo, 0);

	for (int i = 0; i < header->numSlots; i++)
	{
		VamanaWorkerShmem *entry = &header->slots[i];
		uint64		expectedResidency = 0;
		uint64		expectedBuild = 0;

		if (!OidIsValid(entry->dbOid))
			continue;

		for (int j = 0; j < VAMANA_MAX_INDEXES; j++)
		{
			SvsMemReservation *r = &entry->reservations[j];

			if (r->relid == InvalidOid)
				continue;

			expectedResidency += (r->state == SVS_MEM_RESERVED) ?
				r->estimateBytes : r->measuredBytes;
			expectedBuild += r->buildPeakBytes;
		}

		for (int j = 0; j < SVS_MAX_PENDING_INSERT_RESERVATIONS; j++)
		{
			SvsMemInsertReservation *r = &entry->insertReservations[j];

			if (r->relid != InvalidOid)
				expectedResidency += r->deltaBytes;
		}

		if (expectedResidency != entry->residencyBytesCommitted)
			PushInvariantViolation(rsinfo, entry->dbOid,
									"residencyBytesCommitted is %llu, expected %llu from its reservations",
									(unsigned long long) entry->residencyBytesCommitted,
									(unsigned long long) expectedResidency);

		if (expectedBuild != entry->buildBytesCommitted)
			PushInvariantViolation(rsinfo, entry->dbOid,
									"buildBytesCommitted is %llu, expected %llu from its reservations",
									(unsigned long long) entry->buildBytesCommitted,
									(unsigned long long) expectedBuild);

		if (entry->residencyBudget != 0 &&
			entry->residencyBytesCommitted > entry->residencyBudget)
			PushInvariantViolation(rsinfo, entry->dbOid,
									"residencyBytesCommitted %llu exceeds residencyBudget %llu",
									(unsigned long long) entry->residencyBytesCommitted,
									(unsigned long long) entry->residencyBudget);

		if (entry->residencyBudget != 0)
			residencyBudgetSum += entry->residencyBudget;
		buildCommittedSum += entry->buildBytesCommitted;
	}

	if (residencyBudgetSum != header->totalResidencyCommittedGlobal)
		PushInvariantViolation(rsinfo, InvalidOid,
								"totalResidencyCommittedGlobal is %llu, expected %llu from every admitted database's budget",
								(unsigned long long) header->totalResidencyCommittedGlobal,
								(unsigned long long) residencyBudgetSum);

	if (buildCommittedSum != header->totalBuildCommittedGlobal)
		PushInvariantViolation(rsinfo, InvalidOid,
								"totalBuildCommittedGlobal is %llu, expected %llu from every database's buildBytesCommitted",
								(unsigned long long) header->totalBuildCommittedGlobal,
								(unsigned long long) buildCommittedSum);

	return (Datum) 0;
}
