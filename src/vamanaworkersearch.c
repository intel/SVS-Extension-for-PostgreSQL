/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanaworkersearch.c
 *
 * Worker-side batch search execution: group pending search slots by index OID
 * and dispatch them as a single SVS batch call where possible.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/xact.h"
#include "miscadmin.h"
#include "storage/lwlock.h"
#include "utils/injection_point.h"
#include "utils/snapmgr.h"

/* -----------------------------------------------------------------------
 * Batch search dispatch
 * ----------------------------------------------------------------------- */

/*
 * VamanaWorkerRunBatch
 *
 * Process a batch of search requests that all target the same index OID.
 * For each slot, calls SVSSearch and writes results + DONE/ERROR status.
 * SetLatch on each backend is called from the caller AFTER this returns.
 *
 * Contract:
 *   1. Write results to VamanaWorkerSlotResults(slotIdx)
 *   2. Write distances to VamanaWorkerSlotDistances(slotIdx)
 *   3. Write slot->numResults
 *   4. pg_write_barrier(): ensure result data visible before status
 *   5. pg_atomic_write_u32(&slot->status, DONE or ERROR)
 */
static void
VamanaWorkerRunBatch(Oid relid, int *slotIdxs, int n)
{
	SVSIndexHandle index;

	/*
	 * Get or load the index.  Avoid the transaction and catch-up drain if the
	 * index is already warm in process memory.
	 *
	 * VamanaWorkerEnsureIndexCurrent calls VamanaWorkerGetOrLoadIndex, which
	 * propagates ERRCODE_CONFIGURATION_LIMIT_EXCEEDED (cache full) rather than
	 * returning NULL.  Catch that here so a full-cache denial on the search path
	 * fails the queued slots cleanly instead of escaping to the BGW top-level
	 * handler and killing the worker.
	 */
	{
		bool		needsRebuild;
		bool		loadFailed = false;
		char		loadErrMsg[512];	/* same size as VamanaWorkerSlot.errorMessage */

		index = VamanaGetCachedIndex(relid, &needsRebuild);
		if (needsRebuild)
		{
			MemoryContext oldcontext = CurrentMemoryContext;

			PG_TRY();
			{
				index = VamanaWorkerEnsureIndexCurrent(relid);
			}
			PG_CATCH();
			{
				ErrorData  *edata;

				MemoryContextSwitchTo(oldcontext);
				edata = CopyErrorData();
				FlushErrorState();

				/*
				 * VamanaWorkerEnsureIndexCurrent opens a transaction and pushes a
				 * snapshot before calling into the load path.  Those are skipped
				 * when the error propagates, so clean them up here before the
				 * worker continues.  AbortCurrentTransaction must come after
				 * FlushErrorState so the error state is clear when the abort runs.
				 */
				if (ActiveSnapshotSet())
					PopActiveSnapshot();
				if (IsTransactionState())
					AbortCurrentTransaction();

				/*
				 * Only forward the cache-full message verbatim: it is a sanitized
				 * compile-time constant.  Any other load error (SVS library failure,
				 * I/O error) may contain internal detail, so substitute a generic
				 * string and keep the detail in the server log only.
				 */
				if (edata->sqlerrcode == ERRCODE_CONFIGURATION_LIMIT_EXCEEDED &&
					edata->message != NULL)
					snprintf(loadErrMsg, sizeof(loadErrMsg), "%s", edata->message);
				else
					snprintf(loadErrMsg, sizeof(loadErrMsg),
							 "error loading vamana index; see server log for detail");
				FreeErrorData(edata);
				loadFailed = true;
				index = NULL;
			}
			PG_END_TRY();
		}

		if (loadFailed)
		{
			for (int i = 0; i < n; i++)
			{
				VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdxs[i]];

				slot->numResults = 0;
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "%s", loadErrMsg);
				slot->errorCategory = VAMANA_ERR_INTERNAL;
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
			}
			return;
		}
	}

	/*
	 * index == NULL: either the table was empty (valid, return 0 results)
	 * or the index failed to load (error).  Distinguish via the cache:
	 * an empty-table index is cached with isValid=true and numVectors=0.
	 */
	if (index == NULL)
	{
		VamanaIndexCache *cache = VamanaGetCache(relid);
		bool		isEmpty = (cache != NULL && cache->isValid && cache->numVectors == 0);

		for (int i = 0; i < n; i++)
		{
			VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdxs[i]];

			slot->numResults = 0;
			if (!isEmpty)
			{
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "vamana worker: index %u not loaded", relid);
				slot->errorCategory = VAMANA_ERR_INTERNAL;
			}
			pg_write_barrier();
			pg_atomic_write_u32(&slot->status,
								isEmpty ? VAMANA_SLOT_DONE : VAMANA_SLOT_ERROR);
		}
		return;
	}

	/*
	 * Acquire the per-index r/w lock in shared mode for the duration of all
	 * searches in this batch.  This serializes against concurrent writes
	 * (INSERT, DELETE, MAINTENANCE) that hold LW_EXCLUSIVE.
	 *
	 * PG_TRY catches any ereport(ERROR) from the SVS library (e.g. a deleted
	 * entry point that survived a ROLLBACK before consolidate could repair it).
	 * Without this, an uncaught ERROR propagates to the BGW top-level handler
	 * and kills the worker.
	 */
	{
		LWLock	   *rwlock = VamanaGetIndexLock(VamanaWorkerShmemPtr, relid);
		bool		batch_done = false;
		MemoryContext oldcontext = CurrentMemoryContext;

		if (rwlock != NULL)
			LWLockAcquire(rwlock, LW_SHARED);

		PG_TRY();
		{
			/* Test hook: TAP forces a search failure while the rwlock is held. */
			INJECTION_POINT("vamana-worker-search-error", NULL);

			/*
			 * Native batch path: if all slots share the same k and dimensions,
			 * pack query vectors into one buffer and call SVSBatchSearch once.
			 * Far more efficient than N sequential single-query calls.  Falls
			 * back to the sequential loop when n==1 or slots have heterogeneous
			 * k/dimensions.
			 */
			if (n > 1)
			{
				VamanaWorkerSlot *first = &VamanaWorkerShmemPtr->slots[slotIdxs[0]];
				int			k0 = first->k;
				int			dims0 = first->dimensions;
				bool		uniform = true;

				for (int i = 1; i < n; i++)
				{
					VamanaWorkerSlot *s = &VamanaWorkerShmemPtr->slots[slotIdxs[i]];

					if (s->k != k0 || s->dimensions != dims0 ||
						s->searchWindowSize != first->searchWindowSize)
					{
						uniform = false;
						break;
					}
				}

				if (uniform)
				{
					int			k = k0;
					int			dims = dims0;
					float	   *queryBuf;
					int		   *nrBuf;
					ItemPointerData *resBuf;
					float	   *distBuf;
					int			total;

					ereport(DEBUG1,
							(errmsg("vamana worker: native batch search for %d queries "
									"(index %u, k=%d, dims=%d)",
									n, relid, k, dims)));

					queryBuf = palloc((size_t) n * dims * sizeof(float));
					nrBuf = palloc(n * sizeof(int));
					resBuf = palloc((size_t) n * k * sizeof(ItemPointerData));
					distBuf = palloc((size_t) n * k * sizeof(float));

					for (int i = 0; i < n; i++)
						memcpy(queryBuf + (size_t) i * dims,
							   VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdxs[i]),
							   dims * sizeof(float));

					total = SVSBatchSearch(relid, index,
										   queryBuf, n,
										   dims, k,
										   first->searchWindowSize,
										   resBuf, distBuf,
										   nrBuf);

					for (int i = 0; i < n; i++)
					{
						int			slotIdx = slotIdxs[i];
						VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];

						if (total >= 0)
						{
							int			nr = nrBuf[i];
							ItemPointer resptr = VamanaWorkerSlotResults(VamanaWorkerShmemPtr, slotIdx);
							float	   *distptr = VamanaWorkerSlotDistances(VamanaWorkerShmemPtr, slotIdx);

							if (nr > 0)
							{
								memcpy(resptr, resBuf + (size_t) i * k,
									   nr * sizeof(ItemPointerData));
								memcpy(distptr, distBuf + (size_t) i * k,
									   nr * sizeof(float));
							}
							slot->numResults = nr;
							pg_write_barrier();
							pg_atomic_write_u32(&slot->status, VAMANA_SLOT_DONE);
						}
						else
						{
							slot->numResults = 0;
							snprintf(slot->errorMessage, sizeof(slot->errorMessage),
									 "SVS batch search failed");
							slot->errorCategory = VAMANA_ERR_INTERNAL;
							pg_write_barrier();
							pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
						}
					}

					pfree(queryBuf);
					pfree(nrBuf);
					pfree(resBuf);
					pfree(distBuf);

					batch_done = true;
				}
			}

			if (!batch_done)
			{
				/*
				 * Sequential fallback: n==1, or slots have heterogeneous
				 * k/dimensions.
				 */
				ereport(DEBUG1,
						(errmsg("vamana worker: sequential search for %d %s (index %u)",
								n,
								(n == 1) ? "query" : "queries (heterogeneous k/dims)",
								relid)));

				for (int i = 0; i < n; i++)
				{
					int			slotIdx = slotIdxs[i];
					VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdx];
					float	   *qvec = VamanaWorkerSlotQueryVec(VamanaWorkerShmemPtr, slotIdx);
					ItemPointer resptr = VamanaWorkerSlotResults(VamanaWorkerShmemPtr, slotIdx);
					float	   *distptr = VamanaWorkerSlotDistances(VamanaWorkerShmemPtr, slotIdx);
					int			nr;

					nr = SVSSearch(relid, index,
								   qvec, slot->dimensions,
								   slot->k, slot->searchWindowSize,
								   resptr, distptr);

					slot->numResults = (nr >= 0) ? nr : 0;

					if (nr < 0)
					{
						snprintf(slot->errorMessage, sizeof(slot->errorMessage),
								 "SVS search failed with code %d", nr);
						slot->errorCategory = VAMANA_ERR_INTERNAL;
					}

					pg_write_barrier();
					pg_atomic_write_u32(&slot->status,
										(nr >= 0) ? VAMANA_SLOT_DONE : VAMANA_SLOT_ERROR);
				}
			}

			if (rwlock != NULL)
				LWLockRelease(rwlock);
		}
		PG_CATCH();
		{
			ErrorData  *edata;

			LWLockReleaseAll();
			MemoryContextSwitchTo(oldcontext);

			edata = CopyErrorData();
			FlushErrorState();

			ereport(LOG,
					(errmsg("vamana worker: search error on index %u: %s",
							relid, edata->message ? edata->message : "unknown")));
			FreeErrorData(edata);

			for (int i = 0; i < n; i++)
			{
				VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[slotIdxs[i]];

				slot->numResults = 0;
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "vamana worker: search error on index %u", relid);
				slot->errorCategory = VAMANA_ERR_INTERNAL;
				pg_write_barrier();
				pg_atomic_write_u32(&slot->status, VAMANA_SLOT_ERROR);
			}
		}
		PG_END_TRY();
	}
}

/*
 * VamanaWorkerDispatchBatch
 *
 * Group a set of slot indices by indexRelid and call VamanaWorkerRunBatch
 * for each group.  A processed[] bitset ensures each slot is dispatched
 * exactly once even when relids are interleaved.
 */
void
VamanaWorkerDispatchBatch(int *slotIdxs, int n)
{
	bool	   *processed;
	int		   *batch;

	/* Heap-allocate to avoid VLA; n is bounded by MaxBackends at runtime. */
	processed = palloc0(n * sizeof(bool));
	batch = palloc(n * sizeof(int));

	for (int i = 0; i < n; i++)
	{
		Oid			relid;
		int			batchSize = 0;

		if (processed[i])
			continue;

		relid = VamanaWorkerShmemPtr->slots[slotIdxs[i]].indexRelid;

		for (int j = i; j < n; j++)
		{
			if (!processed[j] &&
				VamanaWorkerShmemPtr->slots[slotIdxs[j]].indexRelid == relid)
			{
				batch[batchSize++] = slotIdxs[j];
				processed[j] = true;
			}
		}

		VamanaWorkerRunBatch(relid, batch, batchSize);
	}

	pfree(batch);
	pfree(processed);
}
