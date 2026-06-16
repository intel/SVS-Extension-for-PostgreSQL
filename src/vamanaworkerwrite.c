/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkerwrite.c
 *
 * Worker-side execution of non-SEARCH slots: INSERT, DELETE, MAINTENANCE.
 * Each write operation holds LW_EXCLUSIVE on the per-index lock for its
 * duration to serialize against concurrent shared-mode search batches.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/table.h"
#include "access/xact.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

/* -----------------------------------------------------------------------
 * Write slot execution
 * ----------------------------------------------------------------------- */

/*
 * VamanaWorkerProcessWriteSlot
 *
 * Execute a single non-SEARCH slot (INSERT / DELETE / MAINTENANCE)
 * under the per-index LW_EXCLUSIVE lock.  Writes DONE or ERROR into the slot
 * status.  SetLatch on the waiting backend is the caller's responsibility.
 *
 * Called from VamanaWorkerProcessRequests after the slot has been transitioned
 * to PROCESSING.  The function must not throw: all errors are caught and
 * converted into VAMANA_SLOT_ERROR.
 */
void
VamanaWorkerProcessWriteSlot(int slotIdx)
{
	VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
	Oid			relid = slot->indexRelid;
	LWLock	   *rwlock;
	SVSIndexHandle index;
	bool		needsRebuild;

	/*
	 * Load the index if needed (requires a transaction to open the relation).
	 */
	index = VamanaGetCachedIndex(relid, &needsRebuild);
	if (needsRebuild)
	{
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());
		index = VamanaWorkerGetOrLoadIndex(relid);
		PopActiveSnapshot();
		CommitTransactionCommand();
	}

	if (index == NULL)
	{
		snprintf(slot->errorMessage, sizeof(slot->errorMessage),
				 "vamana worker: index %u not loaded for write", relid);
		slot->errorCategory = VAMANA_ERR_INTERNAL;
		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
		return;
	}

	/* Acquire LW_EXCLUSIVE — blocks until all shared (search) holders exit. */
	rwlock = VamanaGetIndexLock(relid);
	if (rwlock != NULL)
		LWLockAcquire(rwlock, LW_EXCLUSIVE);

	PG_TRY();
	{
		switch (slot->slotKind)
		{
			case VAMANA_SLOTKIND_INSERT:
				{
					/*
					 * The query vector and heap_tid are already in the slot.
					 * Allocate the next external ID from the cached
					 * nextExternalId, then call SVSAddPoints.
					 */
					VamanaIndexCache *cache = VamanaGetCache(relid);
					size_t		externalId;
					int			added;
					float	   *vec = VamanaWorkerSlotQueryVec(slotIdx);

					if (cache == NULL)
						ereport(ERROR,
								(errmsg("vamana worker: no cache entry for insert on index %u",
										relid)));

					externalId = (size_t) cache->nextExternalId;
					added = SVSAddPoints(index, vec, &externalId, 1);

					if (added <= 0)
						ereport(ERROR,
								(errmsg("vamana worker: SVSAddPoints failed for index %u",
										relid)));

					/* Grow tidMapping if needed. */
					if ((int) externalId >= cache->tidMappingCapacity)
					{
						int			newCap = cache->tidMappingCapacity > 0 ?
							cache->tidMappingCapacity * 2 : 1024;
						MemoryContext oldCtx;

						if (newCap <= (int) externalId)
							newCap = (int) externalId + 1;

						oldCtx = MemoryContextSwitchTo(TopMemoryContext);
						cache->tidMapping = repalloc(cache->tidMapping,
													 (Size) newCap * sizeof(ItemPointerData));
						MemSet(cache->tidMapping + cache->tidMappingCapacity, 0,
							   (Size) (newCap - cache->tidMappingCapacity) *
							   sizeof(ItemPointerData));
						MemoryContextSwitchTo(oldCtx);
						cache->tidMappingCapacity = newCap;
					}

					ItemPointerCopy(&slot->writeHeapTid,
									&cache->tidMapping[externalId]);
					cache->nextExternalId = externalId + 1;
					cache->numVectors++;
					cache->needsSave = true;

					/* Return the allocated external ID to the backend. */
					slot->writeExternalId = (uint64) externalId;

					/*
					 * Persist counters to the metapage.  We need an open
					 * relation for this; open and close inside a transaction.
					 */
					{
						Relation	indexRel;

						SetCurrentStatementStartTimestamp();
						StartTransactionCommand();
						PushActiveSnapshot(GetTransactionSnapshot());
						indexRel = index_open(relid, AccessShareLock);
						VamanaWriteMetaPageDynamic(indexRel,
												   cache->nextExternalId,
												   (uint32) cache->numVectors,
												   (uint32) cache->numDeleted,
												   (uint32) cache->tidMappingCapacity,
												   MAIN_FORKNUM);
						index_close(indexRel, AccessShareLock);
						PopActiveSnapshot();
						CommitTransactionCommand();
					}

					slot->numResults = 1;
					pg_write_barrier();
					pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
					break;
				}

			case VAMANA_SLOTKIND_DELETE:
				{
					/*
					 * The backend wrote the count of IDs into
					 * slot->numResults and packed the size_t IDs into the
					 * query-vector buffer (reused for input; float[] is
					 * naturally aligned for size_t).
					 */
					int			nIds = slot->numResults;
					size_t	   *ids = (size_t *) VamanaWorkerSlotQueryVec(slotIdx);
					int			deleted;
					VamanaIndexCache *cache = VamanaGetCache(relid);

					deleted = SVSDeletePoints(index, ids, nIds);

					if (deleted < 0)
						ereport(ERROR,
								(errmsg("vamana worker: SVSDeletePoints failed for index %u",
										relid)));

					if (cache != NULL)
					{
						cache->numDeleted += nIds;
						cache->numVectors = (cache->numVectors > nIds) ?
							cache->numVectors - nIds : 0;
						cache->needsSave = true;

						{
							Relation	indexRel;

							SetCurrentStatementStartTimestamp();
							StartTransactionCommand();
							PushActiveSnapshot(GetTransactionSnapshot());
							indexRel = index_open(relid, AccessShareLock);
							VamanaWriteMetaPageDynamic(indexRel,
													   cache->nextExternalId,
													   (uint32) cache->numVectors,
													   (uint32) cache->numDeleted,
													   (uint32) cache->tidMappingCapacity,
													   MAIN_FORKNUM);
							index_close(indexRel, AccessShareLock);
							PopActiveSnapshot();
							CommitTransactionCommand();
						}
					}

					slot->numResults = deleted;
					pg_write_barrier();
					pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
					break;
				}

			case VAMANA_SLOTKIND_MAINTENANCE:
				{
					VamanaIndexCache *cache = VamanaGetCache(relid);

					if (slot->maintenanceOp == VAMANA_MAINTENANCE_CONSOLIDATE)
					{
						if (!SVSConsolidate(index))
							ereport(ERROR,
									(errmsg("vamana worker: SVSConsolidate failed for index %u",
											relid)));
					}
					else if (slot->maintenanceOp == VAMANA_MAINTENANCE_COMPACT)
					{
						if (!SVSCompact(index, 0))
							ereport(ERROR,
									(errmsg("vamana worker: SVSCompact failed for index %u",
											relid)));
						if (cache != NULL)
							cache->numDeleted = 0;
					}

					if (cache != NULL)
						cache->needsSave = true;

					slot->numResults = 0;
					pg_write_barrier();
					pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
					break;
				}

			default:
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "vamana worker: unknown slotKind %u", slot->slotKind);
				slot->errorCategory = VAMANA_ERR_INTERNAL;
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
				break;
		}
	}
	PG_CATCH();
	{
		ErrorData  *edata;

		if (rwlock != NULL)
			LWLockRelease(rwlock);

		if (IsTransactionState())
			AbortCurrentTransaction();

		edata = CopyErrorData();
		FlushErrorState();

		snprintf(slot->errorMessage, sizeof(slot->errorMessage),
				 "%s", edata->message ? edata->message : "unknown error");
		slot->errorCategory = VamanaCategorizeSQLState(edata->sqlerrcode);
		FreeErrorData(edata);

		pg_write_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
		return;
	}
	PG_END_TRY();

	if (rwlock != NULL)
		LWLockRelease(rwlock);

	/*
	 * Persist the updated index to disk if any write modified it.  This keeps
	 * the on-disk copy in sync with the in-memory state so that a reload
	 * (triggered by SignalReload after CREATE INDEX) sees the latest data.
	 *
	 * The LW lock was released above, but write slots are dispatched serially
	 * (one at a time through VamanaWorkerProcessWriteSlot), so no concurrent
	 * writer can modify cache->tidMapping here.  If write slots are ever
	 * parallelized, this will need re-examination.
	 */
	if (VamanaCacheGetNeedsSave(relid))
	{
		SVSIndexHandle	saveIndex;
		bool			needsRebuild2;

		saveIndex = VamanaGetCachedIndex(relid, &needsRebuild2);
		if (saveIndex != NULL && !needsRebuild2)
		{
			VamanaIndexCache *cache = VamanaGetCache(relid);
			Relation		  indexRel;

			Assert(cache != NULL);
			SetCurrentStatementStartTimestamp();
			StartTransactionCommand();
			PushActiveSnapshot(GetTransactionSnapshot());
			indexRel = index_open(relid, AccessShareLock);
			PG_TRY();
			{
				VamanaSaveIndexToDisk(indexRel, saveIndex, MAIN_FORKNUM, cache);
				index_close(indexRel, AccessShareLock);
				PopActiveSnapshot();
				CommitTransactionCommand();
			}
			PG_CATCH();
			{
				/*
				 * needsSave remains true; next write cycle retries.
				 * Log loudly but do not propagate: the INSERT that triggered
				 * this save succeeded and the backend must not see an error.
				 */
				index_close(indexRel, AccessShareLock);
				PopActiveSnapshot();
				AbortCurrentTransaction();
				FlushErrorState();
				ereport(LOG,
						(errmsg("vamana index %u: periodic save failed, "
								"will retry on next write; index durability degraded",
								relid)));
			}
			PG_END_TRY();
		}
	}
}
