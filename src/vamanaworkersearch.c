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
	 * Get or load the index.  If not cached we need a transaction, but we
	 * avoid opening one if the index is already in process memory.
	 */
	{
		bool		needsRebuild;

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
	 */
	{
		LWLock	   *rwlock = VamanaGetIndexLock(relid);

		if (rwlock != NULL)
			LWLockAcquire(rwlock, LW_SHARED);

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
						   VamanaWorkerSlotQueryVec(slotIdxs[i]),
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
						ItemPointer resptr = VamanaWorkerSlotResults(slotIdx);
						float	   *distptr = VamanaWorkerSlotDistances(slotIdx);

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

				if (rwlock != NULL)
					LWLockRelease(rwlock);
				return;
			}
		}

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
			float	   *qvec = VamanaWorkerSlotQueryVec(slotIdx);
			ItemPointer resptr = VamanaWorkerSlotResults(slotIdx);
			float	   *distptr = VamanaWorkerSlotDistances(slotIdx);
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

		if (rwlock != NULL)
			LWLockRelease(rwlock);
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
