/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_undo.c
 *
 * Per-transaction undo log for the BGW-mediated write path.
 *
 * When the BGW applies an INSERT on behalf of a backend, the backend records
 * (indexRelid, externalId) here.  If the transaction aborts, the XactCallback
 * submits BGW DELETE requests to undo those inserts.  On commit the log is
 * discarded automatically when the transaction memory context is freed.
 *
 * Subtransaction support: each entry also carries its SubTransactionId so
 * that a ROLLBACK TO SAVEPOINT only undoes entries from the aborting
 * subtransaction.
 */

#include "postgres.h"

#include "vamana_undo.h"
#include "vamanaworker.h"
#include "vamana_subxid_pending_array.h"

#include "access/xact.h"
#include "utils/memutils.h"

/* -----------------------------------------------------------------------
 * Data structures
 * ----------------------------------------------------------------------- */

typedef struct VamanaUndoEntry
{
	Oid			indexRelid;
	uint64		externalId;
	SubTransactionId subxid;
}			VamanaUndoEntry;

/* Per-backend (per-transaction) log; reset to NULL at transaction end. */
static VamanaSubxidPendingArray * CurrentUndoLog = NULL;

/* Whether we have registered the xact / subxact callbacks (once per backend). */
static bool undoCallbacksRegistered = false;

/* -----------------------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------------------- */
static void VamanaXactCallback(XactEvent event, void *arg);
static void VamanaSubXactCallback(SubXactEvent event, SubTransactionId mySubid,
								  SubTransactionId parentSubid, void *arg);

/* -----------------------------------------------------------------------
 * Internal helpers
 * ----------------------------------------------------------------------- */

static VamanaSubxidPendingArray *
GetOrCreateUndoLog(void)
{
	if (CurrentUndoLog == NULL)
		CurrentUndoLog = VamanaSubxidPendingArrayCreate(TopTransactionContext,
												  sizeof(VamanaUndoEntry),
												  offsetof(VamanaUndoEntry, subxid),
												  16);
	return CurrentUndoLog;
}

static void
EnsureCallbacksRegistered(void)
{
	if (!undoCallbacksRegistered)
	{
		RegisterXactCallback(VamanaXactCallback, NULL);
		RegisterSubXactCallback(VamanaSubXactCallback, NULL);
		undoCallbacksRegistered = true;
	}
}

/* -----------------------------------------------------------------------
 * Public API
 * ----------------------------------------------------------------------- */

/*
 * VamanaUndoAppend — record one (relid, externalId) for undo on abort.
 *
 * Must be called immediately after the BGW confirms the insert, while the
 * inserting transaction is still open.
 */
void
VamanaUndoAppend(Oid indexRelid, uint64 externalId)
{
	VamanaUndoEntry *entry;

	EnsureCallbacksRegistered();
	entry = VamanaSubxidPendingArrayAppend(GetOrCreateUndoLog());
	entry->indexRelid = indexRelid;
	entry->externalId = externalId;
}

/* -----------------------------------------------------------------------
 * Batched undo helpers
 * ----------------------------------------------------------------------- */

static int
undo_entry_cmp_by_relid(const void *a, const void *b)
{
	Oid			ra = ((const VamanaUndoEntry *) a)->indexRelid;
	Oid			rb = ((const VamanaUndoEntry *) b)->indexRelid;

	return (ra > rb) - (ra < rb);
}

static void
undo_flush_batch(Oid relid, const size_t *ids, int count)
{
	PG_TRY();
	{
		(void) VamanaWorkerSubmitDelete(relid, ids, count);
	}
	PG_CATCH();
	{
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana undo: failed to delete %d entries from index %u",
						count, relid)));
	}
	PG_END_TRY();
}

/* -----------------------------------------------------------------------
 * Xact callbacks
 * ----------------------------------------------------------------------- */

static void
VamanaXactCallback(XactEvent event, void *arg)
{
	switch (event)
	{
		case XACT_EVENT_COMMIT:
		case XACT_EVENT_PARALLEL_COMMIT:
			CurrentUndoLog = NULL;
			break;

		case XACT_EVENT_ABORT:
		case XACT_EVENT_PARALLEL_ABORT:
			{
				VamanaSubxidPendingArray *log = CurrentUndoLog;

				if (log != NULL && log->count > 0 && VamanaWorkerIsAvailable())
				{
					size_t		batchIds[VAMANA_MAX_DELETE_IDS];
					int			batchCount = 0;
					Oid			currentRelid = InvalidOid;
					Oid			consolidateRelids[VAMANA_MAX_INDEXES];
					int			nConsolidate = 0;

					qsort(log->entries, log->count,
						  sizeof(VamanaUndoEntry), undo_entry_cmp_by_relid);

					for (int i = 0; i < log->count; i++)
					{
						VamanaUndoEntry *entry = VamanaSubxidPendingArrayEntryAt(log, i);

						if (entry->subxid == InvalidSubTransactionId)
							continue;

						if (entry->indexRelid != currentRelid ||
							batchCount >= (int) VAMANA_MAX_DELETE_IDS)
						{
							if (batchCount > 0)
								undo_flush_batch(currentRelid, batchIds, batchCount);

							if (OidIsValid(currentRelid) &&
								(nConsolidate == 0 ||
								 consolidateRelids[nConsolidate - 1] != currentRelid))
							{
								if (nConsolidate < VAMANA_MAX_INDEXES)
									consolidateRelids[nConsolidate++] = currentRelid;
							}

							currentRelid = entry->indexRelid;
							batchCount = 0;
						}
						batchIds[batchCount++] = (size_t) entry->externalId;
					}
					if (batchCount > 0)
					{
						undo_flush_batch(currentRelid, batchIds, batchCount);
						if (OidIsValid(currentRelid) &&
							(nConsolidate == 0 ||
							 consolidateRelids[nConsolidate - 1] != currentRelid))
						{
							if (nConsolidate < VAMANA_MAX_INDEXES)
								consolidateRelids[nConsolidate++] = currentRelid;
						}
					}

					/*
					 * Consolidate each affected index to repair the entry point
					 * if any of the deleted nodes was the graph entry point.
					 * Without this, searches after a large ROLLBACK hit a deleted
					 * entry point and SVS returns an error.
					 */
					for (int i = 0; i < nConsolidate; i++)
						VamanaWorkerSubmitMaintenance(consolidateRelids[i],
													  VAMANA_MAINTENANCE_CONSOLIDATE);
				}

				CurrentUndoLog = NULL;
				break;
			}

		case XACT_EVENT_PREPARE:
			if (CurrentUndoLog != NULL && CurrentUndoLog->count > 0)
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("vamana index does not support two-phase commit")));
			break;

		default:
			break;
	}
}

static void
VamanaSubXactCallback(SubXactEvent event, SubTransactionId mySubid,
					  SubTransactionId parentSubid, void *arg)
{
	VamanaSubxidPendingArray *log = CurrentUndoLog;
	size_t		batchIds[VAMANA_MAX_DELETE_IDS];
	int			batchCount = 0;
	Oid			currentRelid = InvalidOid;

	if (event != SUBXACT_EVENT_ABORT_SUB)
		return;

	if (log == NULL || log->count == 0 || !VamanaWorkerIsAvailable())
		return;

	/*
	 * Collect entries belonging to the aborting subtransaction, batched by
	 * relid.  We iterate in insertion order; entries for the same index are
	 * typically adjacent, so batching works without a full qsort.
	 */
	for (int i = 0; i < log->count; i++)
	{
		VamanaUndoEntry *entry = VamanaSubxidPendingArrayEntryAt(log, i);

		if (entry->subxid != mySubid)
			continue;

		if (entry->indexRelid != currentRelid ||
			batchCount >= (int) VAMANA_MAX_DELETE_IDS)
		{
			if (batchCount > 0)
				undo_flush_batch(currentRelid, batchIds, batchCount);

			currentRelid = entry->indexRelid;
			batchCount = 0;
		}
		batchIds[batchCount++] = (size_t) entry->externalId;
	}
	if (batchCount > 0)
		undo_flush_batch(currentRelid, batchIds, batchCount);

	VamanaSubxidPendingArrayPruneAbortedSubxact(log, mySubid);
}
