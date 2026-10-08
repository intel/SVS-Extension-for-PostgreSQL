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

#include "svs_memory.h"
#include "vamana_undo.h"
#include "vamanaworker.h"
#include "vamana_subxid_pending_array.h"

#include "access/xact.h"
#include "miscadmin.h"
#include "utils/memutils.h"

/* -----------------------------------------------------------------------
 * Data structures
 * ----------------------------------------------------------------------- */

typedef struct VamanaUndoEntry
{
	Oid			indexRelid;
	uint64		externalId;
	SubTransactionId subxid;

	/*
	 * This insert's own contribution to its index's raw measured size, and
	 * which residentGeneration it was measured against -- both copied
	 * straight from SvsMemoryReanchorInsert's outputs at apply time. Fed to
	 * SvsMemoryCreditAbortedInserts if this entry is ever undone, so the
	 * credit matches exactly what this insert actually grew, no more.
	 */
	uint64		growthBytes;
	uint32		generation;
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
VamanaUndoAppend(Oid indexRelid, uint64 externalId, uint64 growthBytes, uint32 generation)
{
	VamanaUndoEntry *entry;

	EnsureCallbacksRegistered();
	entry = VamanaSubxidPendingArrayAppend(GetOrCreateUndoLog());
	entry->indexRelid = indexRelid;
	entry->externalId = externalId;
	entry->growthBytes = growthBytes;
	entry->generation = generation;
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

/*
 * Returns true only if VamanaWorkerSubmitDelete itself reported success.
 * The caller uses this to gate SvsMemoryCreditAbortedInserts: a failed or
 * timed-out delete leaves the rows Valid in the graph, and crediting them
 * back would understate memory that is still genuinely live.
 */
static bool
undo_flush_batch(Oid relid, const size_t *ids, int count)
{
	bool		ok = false;

	PG_TRY();
	{
		ok = VamanaWorkerSubmitDelete(relid, ids, count);
	}
	PG_CATCH();
	{
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana undo: failed to delete %d entries from index %u",
						count, relid)));
		ok = false;
	}
	PG_END_TRY();

	return ok;
}

/*
 * ConsolidatingUndoBatch — groups undone entries by index and, once every
 * entry has been fed in, consolidates each affected index to repair its
 * graph entry point if one of the undone nodes was serving as it.  Without
 * this, a search that starts its traversal from a deleted entry point gets
 * an error from the SVS library.
 *
 * Shared by the full-abort and subxact-abort callbacks: both need "batch
 * deletes by relid, then consolidate every relid touched," and only differ
 * in which entries they feed it.
 */
typedef struct ConsolidatingUndoBatch
{
	Oid			currentRelid;
	size_t		batchIds[VAMANA_MAX_DELETE_IDS];
	int			batchCount;

	/*
	 * Growth to credit for currentRelid's accumulating batch, and which
	 * generation it belongs to. Entries whose generation is lower than the
	 * highest seen so far for this relid are stale (the graph was reloaded
	 * or rebuilt since they applied) and are left out of batchGrowth
	 * entirely -- see the comment on ConsolidatingUndoBatchAdd. This
	 * converges to "sum of entries at the group's true maximum generation"
	 * regardless of the order entries are fed in, which matters because the
	 * full-abort callback feeds them in qsort (by relid only, not stable)
	 * order.
	 */
	uint64		batchGrowth;
	uint32		batchGeneration;

	Oid			consolidateRelids[VAMANA_MAX_INDEXES];
	int			nConsolidate;

	/* Relids SvsMemoryCreditAbortedInserts reported as over the reclaim
	 * cap; COMPACT is requested for each, once, after every CONSOLIDATE. */
	Oid			compactRelids[VAMANA_MAX_INDEXES];
	int			nCompact;
}			ConsolidatingUndoBatch;

static void
ConsolidatingUndoBatchInit(ConsolidatingUndoBatch *batch)
{
	batch->currentRelid = InvalidOid;
	batch->batchCount = 0;
	batch->batchGrowth = 0;
	batch->batchGeneration = 0;
	batch->nConsolidate = 0;
	batch->nCompact = 0;
}

static void
ConsolidatingUndoBatchTrackRelid(Oid *relids, int *nRelids, Oid relid)
{
	if (!OidIsValid(relid))
		return;

	for (int i = 0; i < *nRelids; i++)
		if (relids[i] == relid)
			return;

	if (*nRelids < VAMANA_MAX_INDEXES)
		relids[(*nRelids)++] = relid;
}

static void
ConsolidatingUndoBatchTrackConsolidate(ConsolidatingUndoBatch *batch, Oid relid)
{
	ConsolidatingUndoBatchTrackRelid(batch->consolidateRelids, &batch->nConsolidate, relid);
}

static void
ConsolidatingUndoBatchTrackCompact(ConsolidatingUndoBatch *batch, Oid relid)
{
	ConsolidatingUndoBatchTrackRelid(batch->compactRelids, &batch->nCompact, relid);
}

/*
 * Flush the batch accumulated for batch->currentRelid, if any, crediting
 * its growth back once the delete is confirmed and flagging it for a
 * follow-up COMPACT if that credit pushed the database over its reclaim
 * cap. Shared by the relid-change branch of ConsolidatingUndoBatchAdd and
 * by ConsolidatingUndoBatchFinish.
 */
static void
ConsolidatingUndoBatchFlushCurrent(ConsolidatingUndoBatch *batch)
{
	if (batch->batchCount == 0)
		return;

	if (undo_flush_batch(batch->currentRelid, batch->batchIds, batch->batchCount) &&
		batch->batchGrowth > 0)
	{
		if (SvsMemoryCreditAbortedInserts(MyDatabaseId, batch->currentRelid,
										   batch->batchGeneration, batch->batchGrowth))
			ConsolidatingUndoBatchTrackCompact(batch, batch->currentRelid);
	}

	ConsolidatingUndoBatchTrackConsolidate(batch, batch->currentRelid);
}

/*
 * Feed one undone entry into the batch.  Entries for the same relid must
 * arrive together (sorted, or naturally adjacent by insertion order); a
 * change in relid flushes the pending batch and records it for consolidate.
 */
static void
ConsolidatingUndoBatchAdd(ConsolidatingUndoBatch *batch, const VamanaUndoEntry *entry)
{
	if (entry->indexRelid != batch->currentRelid ||
		batch->batchCount >= (int) VAMANA_MAX_DELETE_IDS)
	{
		ConsolidatingUndoBatchFlushCurrent(batch);

		batch->currentRelid = entry->indexRelid;
		batch->batchCount = 0;
		batch->batchGrowth = 0;
		batch->batchGeneration = 0;
	}
	batch->batchIds[batch->batchCount++] = (size_t) entry->externalId;

	/*
	 * Keep only the growth belonging to the highest generation seen so far
	 * for this relid's batch; an entry from an older generation is simply
	 * dropped from the sum (not credited at all), which leaves the budget
	 * honestly over-counted rather than crediting bytes against a graph
	 * that no longer matches what was measured. See the struct comment.
	 */
	if (entry->generation > batch->batchGeneration)
	{
		batch->batchGeneration = entry->generation;
		batch->batchGrowth = entry->growthBytes;
	}
	else if (entry->generation == batch->batchGeneration)
		batch->batchGrowth += entry->growthBytes;
}

/* Flush whatever is still pending, then consolidate and compact every affected index. */
static void
ConsolidatingUndoBatchFinish(ConsolidatingUndoBatch *batch)
{
	ConsolidatingUndoBatchFlushCurrent(batch);

	for (int i = 0; i < batch->nConsolidate; i++)
		VamanaWorkerSubmitMaintenance(batch->consolidateRelids[i],
									  VAMANA_MAINTENANCE_CONSOLIDATE);

	for (int i = 0; i < batch->nCompact; i++)
		VamanaWorkerSubmitMaintenance(batch->compactRelids[i],
									  VAMANA_MAINTENANCE_COMPACT);
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
					ConsolidatingUndoBatch batch;

					qsort(log->entries, log->count,
						  sizeof(VamanaUndoEntry), undo_entry_cmp_by_relid);

					ConsolidatingUndoBatchInit(&batch);
					for (int i = 0; i < log->count; i++)
					{
						VamanaUndoEntry *entry = VamanaSubxidPendingArrayEntryAt(log, i);

						if (entry->subxid == InvalidSubTransactionId)
							continue;

						ConsolidatingUndoBatchAdd(&batch, entry);
					}
					ConsolidatingUndoBatchFinish(&batch);
				}

				CurrentUndoLog = NULL;
				break;
			}

		/* See VamanaSlotDropXactCallback: PREPARE is too late to refuse. */
		case XACT_EVENT_PRE_PREPARE:
			if (CurrentUndoLog != NULL &&
				VamanaSubxidPendingArrayHasLiveEntries(CurrentUndoLog))
				ereport(ERROR,
						(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
						 errmsg("vamana index does not support two-phase commit")));
			break;

		case XACT_EVENT_PREPARE:
			CurrentUndoLog = NULL;
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

	if (log == NULL)
		return;

	if (event == SUBXACT_EVENT_COMMIT_SUB)
	{
		VamanaSubxidPendingArrayReparentSubxact(log, mySubid, parentSubid);
		return;
	}

	if (event != SUBXACT_EVENT_ABORT_SUB || log->count == 0 || !VamanaWorkerIsAvailable())
		return;

	/*
	 * Collect entries belonging to the aborting subtransaction.  We iterate
	 * in insertion order; entries for the same index are typically
	 * adjacent, so batching works without a full qsort.
	 */
	{
		ConsolidatingUndoBatch batch;

		ConsolidatingUndoBatchInit(&batch);
		for (int i = 0; i < log->count; i++)
		{
			VamanaUndoEntry *entry = VamanaSubxidPendingArrayEntryAt(log, i);

			if (entry->subxid != mySubid)
				continue;

			ConsolidatingUndoBatchAdd(&batch, entry);
		}
		ConsolidatingUndoBatchFinish(&batch);
	}

	VamanaSubxidPendingArrayPruneAbortedSubxact(log, mySubid);
}
