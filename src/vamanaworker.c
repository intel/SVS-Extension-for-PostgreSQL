/*
 * vamanaworker.c
 *
 * Background worker for Vamana index.  A single dedicated process holds the
 * SVS index permanently and serves search requests from client backends via
 * shared memory.  Backends write query vectors into a per-backend slot and
 * wait on a shared latch; the worker drains all pending slots as one batch,
 * runs SVSSearch for each, and wakes the originating backends.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/table.h"
#include "access/xact.h"
#include "catalog/pg_am_d.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lmgr.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "tcop/tcopprot.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/snapmgr.h"

/*
 * PG 17 renamed BackendId/MyBackendId → ProcNumber/MyProcNumber.
 * PG_WAIT_EXTENSION moved from pgstat.h to utils/wait_classes.h in PG 17.
 */
#if PG_VERSION_NUM >= 170000
#include "storage/procnumber.h"
#include "utils/wait_classes.h"
#define VAMANA_MY_SLOT_IDX		((int) MyProcNumber)
#else
#include "pgstat.h"
#define VAMANA_MY_SLOT_IDX		(MyBackendId - 1)
#endif

/* -----------------------------------------------------------------------
 * Module-level state
 * ----------------------------------------------------------------------- */

/* Pointer to the shared memory region (all processes) */
VamanaWorkerShmem *VamanaWorkerShmemPtr = NULL;

/* Hook chains (set by VamanaWorkerInstallHooks, used by hook functions) */
static shmem_startup_hook_type prev_shmem_startup_hook = NULL;

#if PG_VERSION_NUM >= 150000
static shmem_request_hook_type prev_shmem_request_hook = NULL;
#endif

/* Signal flags (worker process only) */
static volatile sig_atomic_t worker_got_sigterm = false;
static volatile sig_atomic_t worker_got_sighup = false;

/* LWLock tranche for per-index r/w locks */
static int	VamanaIndexLockTranche = -1;
static const char *const VamanaIndexLockTrancheName = "vamana_index_rwlock";

/* -----------------------------------------------------------------------
 * Signal handlers (worker process only)
 * ----------------------------------------------------------------------- */

static void
VamanaWorkerSigterm(SIGNAL_ARGS)
{
	int			save_errno = errno;

	worker_got_sigterm = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

static void
VamanaWorkerSighup(SIGNAL_ARGS)
{
	int			save_errno = errno;

	worker_got_sighup = true;
	SetLatch(MyLatch);
	errno = save_errno;
}

/* -----------------------------------------------------------------------
 * Shared memory accessors
 *
 * Variable-length data is stored immediately after the slot-header array:
 *   [slots[maxSlots]] [queryVecs[maxSlots][MAX_DIM]] [results[...]] [dists[...]]
 * ----------------------------------------------------------------------- */

/*
 * Byte offset from the start of shmem to the beginning of the
 * variable-length data area.
 */
static inline size_t
VamanaWorkerVarDataOffset(void)
{
	return offsetof(VamanaWorkerShmem, slots) +
		(size_t) VamanaWorkerShmemPtr->maxSlots * sizeof(VamanaWorkerSlot);
}

float *
VamanaWorkerSlotQueryVec(int slotIdx)
{
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) slotIdx * VAMANA_MAX_DIM * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr + offset);
}

ItemPointer
VamanaWorkerSlotResults(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData);

	return (ItemPointer) ((char *) VamanaWorkerShmemPtr + offset);
}

float *
VamanaWorkerSlotDistances(int slotIdx)
{
	int			maxSlots = VamanaWorkerShmemPtr->maxSlots;
	size_t		offset = VamanaWorkerVarDataOffset() +
		(size_t) maxSlots * VAMANA_MAX_DIM * sizeof(float) +
		(size_t) maxSlots * VAMANA_MAX_SEARCH_WINDOW * sizeof(ItemPointerData) +
		(size_t) slotIdx * VAMANA_MAX_SEARCH_WINDOW * sizeof(float);

	return (float *) ((char *) VamanaWorkerShmemPtr + offset);
}

/* -----------------------------------------------------------------------
 * Shared memory sizing and initialisation
 * ----------------------------------------------------------------------- */

Size
VamanaWorkerShmemSize(void)
{
	Size		header;
	Size		perSlotVar;

	/*
	 * Header = fixed VamanaWorkerShmem fields + MaxBackends slot entries (via
	 * FLEXIBLE_ARRAY_MEMBER).
	 */
	header = add_size(offsetof(VamanaWorkerShmem, slots),
					  mul_size(MaxBackends, sizeof(VamanaWorkerSlot)));

	/*
	 * Variable-length data per slot: query vector + result TIDs + distances.
	 */
	perSlotVar = add_size(
						  mul_size(VAMANA_MAX_DIM, sizeof(float)),	/* query vec */
						  add_size(
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(ItemPointerData)), /* TIDs */
								   mul_size(VAMANA_MAX_SEARCH_WINDOW, sizeof(float)))); /* dists */

	return add_size(header, mul_size(MaxBackends, perSlotVar));
}

/*
 * VamanaWorkerShmemStartup: shmem_startup_hook.
 *
 * Called from the postmaster (not the worker) when shared memory is
 * initialised.  We must call InitSharedLatch() here for every latch that
 * lives in shared memory; failing to do so causes undefined behavior on
 * first WaitLatch/SetLatch.
 */
void
VamanaWorkerShmemStartup(void)
{
	bool		found;

	if (prev_shmem_startup_hook)
		prev_shmem_startup_hook();

	LWLockAcquire(AddinShmemInitLock, LW_EXCLUSIVE);

	VamanaWorkerShmemPtr = ShmemInitStruct("VamanaWorkerShmem",
										   VamanaWorkerShmemSize(), &found);
	if (!found)
	{
		memset(VamanaWorkerShmemPtr, 0, VamanaWorkerShmemSize());
		VamanaWorkerShmemPtr->dbOid = InvalidOid;
		VamanaWorkerShmemPtr->workerPid = 0;
		VamanaWorkerShmemPtr->maxSlots = MaxBackends;

		InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);

		for (int i = 0; i < MaxBackends; i++)
		{
			VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];

			pg_atomic_init_u32(&slot->status, VAMANA_SLOT_EMPTY);
			InitSharedLatch(&slot->latch);
		}

		for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
			pg_atomic_init_u32(&VamanaWorkerShmemPtr->reloadRequests[i].relid, 0);

		pg_atomic_init_u32(&VamanaWorkerShmemPtr->reload_all, 0);

		/*
		 * Initialise per-index r/w lock slots.  The tranche is registered
		 * once here; the LWLockInitialize calls below bind each lock to it.
		 */
		VamanaIndexLockTranche = LWLockNewTrancheId();
		LWLockRegisterTranche(VamanaIndexLockTranche,
							  VamanaIndexLockTrancheName);
		for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
		{
			VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];

			pg_atomic_init_u32(&ls->relid, 0);
			LWLockInitialize(&ls->lock, VamanaIndexLockTranche);
		}
	}
	else
	{
		VamanaIndexLockTranche = LWLockNewTrancheId();
		LWLockRegisterTranche(VamanaIndexLockTranche,
							  VamanaIndexLockTrancheName);
		/* Clear stale latch ownership from a previous worker instance. */
		InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);
	}

	LWLockRelease(AddinShmemInitLock);
}

/* -----------------------------------------------------------------------
 * Worker registration
 * ----------------------------------------------------------------------- */

#if PG_VERSION_NUM >= 150000
static void VamanaWorkerShmemRequest(void);
#endif

/*
 * VamanaWorkerInstallHooks: install shmem sizing and startup hooks.
 *
 * Must be called from _PG_init() while process_shared_preload_libraries_in_progress
 * is true.  In PG 15+, RequestAddinShmemSpace() must be called from
 * shmem_request_hook rather than directly.
 */
void
VamanaWorkerInstallHooks(void)
{
#if PG_VERSION_NUM >= 150000
	prev_shmem_request_hook = shmem_request_hook;
	shmem_request_hook = VamanaWorkerShmemRequest;
#else
	RequestAddinShmemSpace(VamanaWorkerShmemSize());
#endif

	prev_shmem_startup_hook = shmem_startup_hook;
	shmem_startup_hook = VamanaWorkerShmemStartup;
}

#if PG_VERSION_NUM >= 150000
static void
VamanaWorkerShmemRequest(void)
{
	if (prev_shmem_request_hook)
		prev_shmem_request_hook();
	RequestAddinShmemSpace(VamanaWorkerShmemSize());
}
#endif

void
VamanaWorkerRegister(void)
{
	BackgroundWorker bgw;

	memset(&bgw, 0, sizeof(bgw));
	snprintf(bgw.bgw_name, BGW_MAXLEN, "vamana background worker");
	snprintf(bgw.bgw_type, BGW_MAXLEN, "vamana background worker");
	snprintf(bgw.bgw_library_name, BGW_MAXLEN, "svs");
	snprintf(bgw.bgw_function_name, BGW_MAXLEN, "VamanaWorkerMain");
	bgw.bgw_flags = BGWORKER_SHMEM_ACCESS |
		BGWORKER_BACKEND_DATABASE_CONNECTION;
	bgw.bgw_start_time = BgWorkerStart_RecoveryFinished;
	bgw.bgw_restart_time = vamana_worker_restart_time;
	bgw.bgw_main_arg = (Datum) 0;
	bgw.bgw_notify_pid = 0;

	RegisterBackgroundWorker(&bgw);
}

/* -----------------------------------------------------------------------
 * Per-index r/w lock helpers (worker-internal)
 * ----------------------------------------------------------------------- */

/*
 * Return the LWLock for the given index OID, allocating a slot if none exists.
 * Returns NULL if the table is full (> VAMANA_MAX_INDEXES live indexes).
 *
 * Must be called from within the worker process (or shmem startup).
 */
static LWLock *
VamanaGetIndexLock(Oid relid)
{
	int			free_slot = -1;

	Assert(OidIsValid(relid));

	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];
		uint32		cur = pg_atomic_read_u32(&ls->relid);

		if (cur == (uint32) relid)
			return &ls->lock;

		if (cur == 0 && free_slot < 0)
			free_slot = i;
	}

	if (free_slot < 0)
	{
		ereport(WARNING,
				(errmsg("vamana worker: index lock table full (VAMANA_MAX_INDEXES=%d); "
						"cannot allocate lock for index %u",
						VAMANA_MAX_INDEXES, relid)));
		return NULL;
	}

	/* CAS 0 → relid to claim the slot */
	{
		uint32		expected = 0;

		if (!pg_atomic_compare_exchange_u32(
											&VamanaWorkerShmemPtr->indexLocks[free_slot].relid,
											&expected, (uint32) relid))
		{
			/* Lost the race; search again (recursive retry) */
			return VamanaGetIndexLock(relid);
		}
	}

	return &VamanaWorkerShmemPtr->indexLocks[free_slot].lock;
}

void
VamanaReleaseIndexLock(Oid relid)
{
	for (int i = 0; i < VAMANA_MAX_INDEXES; i++)
	{
		VamanaIndexLockSlot *ls = &VamanaWorkerShmemPtr->indexLocks[i];

		if (pg_atomic_read_u32(&ls->relid) == (uint32) relid)
		{
			pg_atomic_write_u32(&ls->relid, 0);
			return;
		}
	}
}

/* -----------------------------------------------------------------------
 * Worker-internal helpers
 * ----------------------------------------------------------------------- */

/*
 * Reset any slot that is not EMPTY.  Called at worker startup to clean up
 * slots left behind by backends that died while waiting.
 */
static void
VamanaWorkerResetStaleSlots(void)
{
	for (int i = 0; i < VamanaWorkerShmemPtr->maxSlots; i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];
		uint32		s = pg_atomic_read_u32(&slot->status);

		if (s != VAMANA_SLOT_EMPTY)
		{
			ereport(DEBUG1,
					(errmsg("vamana worker: resetting stale slot %d (status=%u) at startup",
							i, s)));
			pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		}
	}
}

/*
 * VamanaWorkerTrySaveIndex
 *
 * Best-effort wrapper: save a freshly rebuilt index to disk, swallowing any
 * error.  Extracted into its own function to avoid nesting PG_TRY blocks
 * (which causes -Wshadow=compatible-local warnings for the macro-generated
 * locals _save_exception_stack, _save_context_stack, _local_sigjmp_buf, and
 * _do_rethrow).
 */
static void
VamanaWorkerTrySaveIndex(Relation indexRel, SVSIndexHandle index, Oid relid)
{
	PG_TRY();
	{
		VamanaSaveIndexToDisk(indexRel, index, MAIN_FORKNUM);
	}
	PG_CATCH();
	{
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana worker: could not save rebuilt index %u to disk",
						relid)));
	}
	PG_END_TRY();
}

/*
 * VamanaWorkerGetOrLoadIndex
 *
 * Return the cached SVSIndexHandle for the given index OID.  If the index is
 * not yet in the worker's in-process cache, open the relation, try to load
 * from disk, and fall back to a full rebuild.  Returns NULL on failure.
 *
 * Must be called from within an active transaction (or the caller must open
 * one).
 */
static SVSIndexHandle
VamanaWorkerGetOrLoadIndex(Oid relid)
{
	bool		needsRebuild;
	SVSIndexHandle index;
	Relation	indexRel;

	/* Fast path: already loaded */
	index = VamanaGetCachedIndex(relid, &needsRebuild);
	if (!needsRebuild)
		return index;

	/*
	 * Acquire AccessShareLock non-blocking before opening the relation.
	 * A background worker must never block on a relation-level lock: if DDL
	 * (DROP TABLE, TRUNCATE) holds AccessExclusiveLock on a related relation,
	 * blocking here creates a lock-ordering cycle and deadlock.  This mirrors
	 * the autovacuum pattern of using ConditionalLockRelationOid.
	 */
	if (!ConditionalLockRelationOid(relid, AccessShareLock))
	{
		ereport(LOG,
				(errmsg("vamana worker: index %u locked by DDL, skipping reload", relid)));
		return NULL;
	}

	/* Open the index relation inside the caller's transaction */
	PG_TRY();
	{
		indexRel = index_open(relid, NoLock);
		index = LoadIndexFromPages(indexRel);
		if (index == NULL)
		{
			ereport(LOG,
					(errmsg("vamana worker: no saved copy for index %u, rebuilding", relid)));
			index = VamanaRebuildFromTable(indexRel);

			if (index != NULL)
			{
				VamanaWorkerTrySaveIndex(indexRel, index, relid);
			}
			else
			{
				/*
				 * Table has 0 vectors.  Cache an empty entry so subsequent
				 * lookups return quickly with 0 results instead of retrying
				 * the rebuild each time.
				 */
				VamanaOptions *opts = (VamanaOptions *) indexRel->rd_options;
				int		dims = TupleDescAttr(indexRel->rd_att, 0)->atttypmod;

				VamanaCacheIndex(relid, NULL, dims,
								opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE,
								opts ? opts->alpha : VAMANA_DEFAULT_ALPHA,
								NULL, 0, 0, 0, 0);
			}
		}
		index_close(indexRel, AccessShareLock);
	}
	PG_CATCH();
	{
		UnlockRelationOid(relid, AccessShareLock);
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana worker: failed to load index %u", relid)));
		index = NULL;
	}
	PG_END_TRY();

	return index;
}

/*
 * VamanaWorkerLoadAllIndexes
 *
 * At worker startup, enumerate all Vamana indexes in the connected database
 * via SPI and pre-load each one.  Called inside a transaction.
 */
static void
VamanaWorkerLoadAllIndexes(void)
{
	int			ret;
	uint64		nindexes;
	MemoryContext oldctx;

	SetCurrentStatementStartTimestamp();
	StartTransactionCommand();
	PushActiveSnapshot(GetTransactionSnapshot());

	if (SPI_connect() != SPI_OK_CONNECT)
	{
		PopActiveSnapshot();
		AbortCurrentTransaction();
		ereport(WARNING, (errmsg("vamana worker: SPI_connect failed")));
		return;
	}

	/*
	 * Find all Vamana index OIDs in this database.  We join through pg_class
	 * and pg_am so we don't hardcode an OID.
	 */
	ret = SPI_execute(
					  "SELECT c.oid "
					  "FROM pg_catalog.pg_class c "
					  "JOIN pg_catalog.pg_am a ON a.oid = c.relam "
					  "WHERE a.amname = 'vamana' AND c.relkind = 'i'",
					  true, 0);

	if (ret != SPI_OK_SELECT)
	{
		SPI_finish();
		PopActiveSnapshot();
		AbortCurrentTransaction();
		ereport(WARNING, (errmsg("vamana worker: failed to enumerate indexes")));
		return;
	}

	nindexes = SPI_processed;
	oldctx = MemoryContextSwitchTo(TopMemoryContext);

	for (uint64 i = 0; i < nindexes; i++)
	{
		bool		isnull;
		Oid			relid = DatumGetObjectId(
											 SPI_getbinval(SPI_tuptable->vals[i],
														   SPI_tuptable->tupdesc,
														   1, &isnull));

		if (isnull)
			continue;

		MemoryContextSwitchTo(oldctx);

		(void) VamanaWorkerGetOrLoadIndex(relid);

		oldctx = MemoryContextSwitchTo(TopMemoryContext);
	}

	MemoryContextSwitchTo(oldctx);
	SPI_finish();
	PopActiveSnapshot();
	CommitTransactionCommand();
}

/* -----------------------------------------------------------------------
 * Request processing
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
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "vamana worker: index %u not loaded", relid);
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
				snprintf(slot->errorMessage, sizeof(slot->errorMessage),
						 "SVS search failed with code %d", nr);

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
static void
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
static void
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
		bool			needsRebuild;

		saveIndex = VamanaGetCachedIndex(relid, &needsRebuild);
		if (saveIndex != NULL && !needsRebuild)
		{
			VamanaIndexCache *cache = VamanaGetCache(relid);
			Relation		  indexRel;

			SetCurrentStatementStartTimestamp();
			StartTransactionCommand();
			PushActiveSnapshot(GetTransactionSnapshot());
			indexRel = index_open(relid, AccessShareLock);
			VamanaWorkerTrySaveIndex(indexRel, saveIndex, relid);
			if (cache != NULL && cache->tidMapping != NULL &&
				cache->tidMappingCapacity > 0)
			{
				char	savedir[MAXPGPATH];

				VamanaGetIndexSavePath(relid, savedir, sizeof(savedir));
				if (access(savedir, F_OK) == 0)
					VamanaSaveTidMapAtomically(relid, cache->tidMapping,
											   cache->tidMappingCapacity);
			}
			index_close(indexRel, AccessShareLock);
			PopActiveSnapshot();
			CommitTransactionCommand();
			VamanaCacheSetNeedsSave(relid, false);
		}
	}
}

/*
 * VamanaWorkerProcessRequests
 *
 * Collect all PENDING slots, transition them to PROCESSING.
 * SEARCH slots are batched and dispatched together via VamanaWorkerDispatchBatch.
 * Write slots (INSERT/DELETE/MAINTENANCE) are processed individually via
 * VamanaWorkerProcessWriteSlot, which holds LW_EXCLUSIVE for the duration.
 * After all processing, wake every waiting backend.
 */
static void
VamanaWorkerProcessRequests(void)
{
	int		   *searchPending;
	int		   *writePending;
	int			numSearch = 0;
	int			numWrite = 0;
	int			maxBatch;
	int			numTotal = 0;
	int		   *allPending;

	maxBatch = (vamana_max_batch_size > 0) ? vamana_max_batch_size : MaxBackends;

	searchPending = palloc(MaxBackends * sizeof(int));
	writePending = palloc(MaxBackends * sizeof(int));
	allPending = palloc(MaxBackends * sizeof(int));

	/* Collect all PENDING slots (single worker, no contention here) */
	for (int i = 0;
		 i < VamanaWorkerShmemPtr->maxSlots && numTotal < maxBatch;
		 i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];

		if (pg_atomic_read_u32(&slot->status) == VAMANA_SLOT_PENDING)
		{
			pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PROCESSING);
			allPending[numTotal++] = i;

			if (slot->slotKind == VAMANA_SLOTKIND_SEARCH)
				searchPending[numSearch++] = i;
			else
				writePending[numWrite++] = i;
		}
	}

	if (numTotal == 0)
	{
		pfree(searchPending);
		pfree(writePending);
		pfree(allPending);
		return;
	}

	ereport(DEBUG1,
			(errmsg("vamana worker: dispatching %d search + %d write request(s)",
					numSearch, numWrite)));

	/* Process searches as a batch (LW_SHARED). */
	if (numSearch > 0)
		VamanaWorkerDispatchBatch(searchPending, numSearch);

	/* Process write slots individually (each acquires LW_EXCLUSIVE). */
	for (int i = 0; i < numWrite; i++)
		VamanaWorkerProcessWriteSlot(writePending[i]);

	/* Wake all waiting backends */
	for (int i = 0; i < numTotal; i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[allPending[i]];

		SetLatch(&slot->latch);
	}

	pfree(searchPending);
	pfree(writePending);
	pfree(allPending);
}

/*
 * VamanaWorkerProcessReloads
 *
 * Check the reload queue for OIDs that backends have signaled need
 * reloading (after INSERT/UPDATE/DELETE/REINDEX).  For each pending OID,
 * reload the index from disk (or rebuild) and clear the queue entry.
 *
 * Must NOT use SIGUSR1: that signal is owned by PostgreSQL's ProcSignal
 * infrastructure.  This polling approach is the correct alternative.
 */
static void
VamanaWorkerProcessReloads(void)
{
	bool		anyReload = false;

	/*
	 * If a backend set reload_all (because the per-OID queue overflowed),
	 * evict every cached entry and reload all Vamana indexes from disk. This
	 * guarantees no stale handles survive an overflow event.
	 */
	if (pg_atomic_exchange_u32(&VamanaWorkerShmemPtr->reload_all, 0) != 0)
	{
		ereport(LOG,
				(errmsg("vamana worker: reload_all set, evicting all cached indexes and reloading")));
		VamanaEvictAllCacheEntries();
		VamanaWorkerLoadAllIndexes();
		return;
	}

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
	{
		uint32		relid_u32;
		Oid			relid;

		relid_u32 = pg_atomic_read_u32(
									   &VamanaWorkerShmemPtr->reloadRequests[i].relid);
		if (relid_u32 == 0)
			continue;

		relid = (Oid) relid_u32;

		/*
		 * Clear the slot first (before loading) so that a new invalidation
		 * that arrives during the load is not silently lost.
		 */
		pg_atomic_write_u32(
							&VamanaWorkerShmemPtr->reloadRequests[i].relid, 0);

		ereport(LOG,
				(errmsg("vamana worker: reloading index %u", relid)));

		/*
		 * Evict only the in-process cache entry so VamanaWorkerGetOrLoadIndex
		 * picks up the fresh on-disk copy.  Do NOT use
		 * VamanaInvalidateCache() here: that would delete the on-disk saved
		 * copy (preventing reload from disk) and re-signal the worker
		 * (causing a reload loop).
		 */
		VamanaEvictCacheEntry(relid);
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());

		(void) VamanaWorkerGetOrLoadIndex(relid);

		PopActiveSnapshot();
		CommitTransactionCommand();

		anyReload = true;
	}

	(void) anyReload;
}

/* -----------------------------------------------------------------------
 * Worker main entry point
 * ----------------------------------------------------------------------- */

PGDLLEXPORT void
VamanaWorkerMain(Datum main_arg)
{
	/*
	 * Set up signal handlers.  Do NOT override SIGUSR1: it is owned by
	 * PostgreSQL's ProcSignal infrastructure.
	 */
	pqsignal(SIGTERM, VamanaWorkerSigterm);
	pqsignal(SIGHUP, VamanaWorkerSighup);
	BackgroundWorkerUnblockSignals();

	VamanaWorkerShmemPtr->workerPid = MyProcPid;
	VamanaWorkerShmemPtr->dbOid = InvalidOid;
	InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);
	OwnLatch(&VamanaWorkerShmemPtr->workerLatch);

	if (strcmp(vamana_worker_database, "postgres") == 0)
		ereport(WARNING,
				(errmsg("vamana worker connecting to default database \"postgres\""),
				 errhint("Set vamana.worker_database if your Vamana indexes are in a different database.")));
	BackgroundWorkerInitializeConnection(vamana_worker_database, NULL, 0);

	VamanaWorkerShmemPtr->dbOid = MyDatabaseId;

	VamanaWorkerResetStaleSlots();
	VamanaWorkerLoadAllIndexes();

	ereport(LOG, (errmsg("vamana background worker started for database \"%s\"",
						 vamana_worker_database)));

	while (!worker_got_sigterm)
	{
		int			rc;

		rc = WaitLatch(&VamanaWorkerShmemPtr->workerLatch,
					   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
					   1000L,	/* 1-second heartbeat */
					   PG_WAIT_EXTENSION);

		ResetLatch(&VamanaWorkerShmemPtr->workerLatch);

		if (rc & WL_POSTMASTER_DEATH)
		{
			DisownLatch(&VamanaWorkerShmemPtr->workerLatch);
			proc_exit(1);
		}

		CHECK_FOR_INTERRUPTS();

		if (worker_got_sighup)
		{
			ProcessConfigFile(PGC_SIGHUP);
			worker_got_sighup = false;
		}

		VamanaWorkerProcessReloads();

		/*
		 * Process pending search requests on every iteration, not only when
		 * the latch was set.  A latch set can race WL_TIMEOUT attribution,
		 * leaving a PENDING slot unprocessed for up to 1 s otherwise.
		 */
		VamanaWorkerProcessRequests();
	}

	ereport(LOG, (errmsg("vamana background worker shutting down")));
	DisownLatch(&VamanaWorkerShmemPtr->workerLatch);
	proc_exit(0);
}

/* -----------------------------------------------------------------------
 * Backend-side API
 * ----------------------------------------------------------------------- */

/*
 * VamanaWorkerIsAvailable: true if the worker is running and serving the
 * current backend's database.
 */
bool
VamanaWorkerIsAvailable(void)
{
	if (VamanaWorkerShmemPtr == NULL)
		return false;
	if (VamanaWorkerShmemPtr->workerPid == 0)
		return false;
	if (VamanaWorkerShmemPtr->dbOid != MyDatabaseId)
		return false;
	return true;
}

/*
 * VamanaWorkerAssertDatabase
 *
 * If the background worker is running but serving a different database, throw
 * an immediate ERROR.  This is a permanent misconfiguration — no amount of
 * waiting will fix it — so we must not spin.
 */
void
VamanaWorkerAssertDatabase(void)
{
	if (VamanaWorkerShmemPtr != NULL &&
		VamanaWorkerShmemPtr->workerPid != 0 &&
		VamanaWorkerShmemPtr->dbOid != InvalidOid &&
		VamanaWorkerShmemPtr->dbOid != MyDatabaseId)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("vamana index is not enabled for this database"),
				 errdetail("The background worker is running for database OID %u, not %u.",
						   VamanaWorkerShmemPtr->dbOid, MyDatabaseId),
				 errhint("Set vamana.worker_database to the name of this database and restart the server.")));
}

/*
 * VamanaWorkerWaitUntilAvailable
 *
 * Spin-wait for the background worker to finish startup.  Once the BGW sets
 * workerPid in shared memory this returns immediately.  If the worker does not
 * become available within vamana_worker_startup_timeout_ms milliseconds, an
 * ERROR is thrown so the caller gets an actionable message rather than silent
 * data loss or stale results.
 *
 * This uses a different timeout than vamana_worker_timeout_ms (IPC response
 * time) because startup can take well over 5 s when there are many large
 * indexes to deserialize from disk.
 */
void
VamanaWorkerWaitUntilAvailable(Oid indexRelid, const char *operation)
{
	int			total_waited_ms = 0;

	VamanaWorkerAssertDatabase();

	if (VamanaWorkerIsAvailable())
		return;

	while (total_waited_ms < vamana_worker_startup_timeout_ms)
	{
		long		wait_ms = Min(200, vamana_worker_startup_timeout_ms - total_waited_ms);

		(void) WaitLatch(MyLatch,
						 WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						 wait_ms,
						 PG_WAIT_EXTENSION);
		ResetLatch(MyLatch);
		CHECK_FOR_INTERRUPTS();
		VamanaWorkerAssertDatabase();

		if (VamanaWorkerIsAvailable())
			return;

		total_waited_ms += (int) wait_ms;
	}

	ereport(ERROR,
			(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
			 errmsg("vamana background worker unavailable after %d ms; cannot %s index %u",
					total_waited_ms, operation, indexRelid),
			 errhint("Ensure vamana is in shared_preload_libraries and the server was restarted.")));
}

/*
 * VamanaWorkerSubmitSearch
 *
 * Backend-side: write the query into this backend's shared-memory slot,
 * wake the worker, and wait for results.  Returns the number of results
 * written to the results/distances arrays, or -1 on failure/timeout.
 */
int
VamanaWorkerSubmitSearch(Oid indexRelid,
						 const float *queryVector,
						 int dimensions, int k, int searchWindowSize,
						 ItemPointer results, float *distances)
{
	VamanaWorkerSlot *slot;
	int			slotIdx;
	uint32		status;
	int			total_waited_ms = 0;

	if (!VamanaWorkerIsAvailable())
		return -1;

	slotIdx = VAMANA_MY_SLOT_IDX;
	Assert(slotIdx >= 0 && slotIdx < VamanaWorkerShmemPtr->maxSlots);

	slot = &VamanaWorkerShmemPtr->slots[slotIdx];

	status = pg_atomic_read_u32(&slot->status);

	/*
	 * A DONE or ERROR slot here means a previous request timed out after the
	 * worker finished (backend gave up while slot was PROCESSING, worker then
	 * wrote DONE/ERROR and called SetLatch on the disowned latch).  Clear
	 * those leftovers so this backend can reuse its slot.
	 */
	if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
	{
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		status = VAMANA_SLOT_EMPTY;
	}

	if (status != VAMANA_SLOT_EMPTY)
	{
		ereport(WARNING,
				(errmsg("vamana worker slot %d not empty (status=%u), falling back",
						slotIdx, status)));
		return -1;
	}

	/*
	 * Validate dimensions and k fit in the shared-memory slot.  The result
	 * buffer per slot is sized at VAMANA_MAX_SEARCH_WINDOW entries (see
	 * VamanaWorkerShmemSize), so k is capped to that limit to avoid overrun.
	 */
	if (dimensions > VAMANA_MAX_DIM || k > VAMANA_MAX_SEARCH_WINDOW)
	{
		ereport(WARNING,
				(errmsg("vamana worker: query dimensions %d or k %d exceed max (%d/%d)",
						dimensions, k, VAMANA_MAX_DIM, VAMANA_MAX_SEARCH_WINDOW)));
		return -1;
	}

	memcpy(VamanaWorkerSlotQueryVec(slotIdx), queryVector,
		   dimensions * sizeof(float));

	slot->indexRelid = indexRelid;
	slot->slotKind = VAMANA_SLOTKIND_SEARCH;
	slot->dimensions = dimensions;
	slot->k = k;
	slot->searchWindowSize = searchWindowSize;

	/*
	 * Own the slot latch before setting PENDING to avoid a race where the
	 * worker completes and calls SetLatch before we enter WaitLatch.
	 */
	OwnLatch(&slot->latch);
	ResetLatch(&slot->latch);

	/*
	 * Store-release: ensure metadata writes above are visible to the worker
	 * before it reads PENDING status.
	 */
	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PENDING);

	SetLatch(&VamanaWorkerShmemPtr->workerLatch);

	PG_TRY();
	{
		while (true)
		{
			int			rc;
			long		wait_ms;

			wait_ms = Min(1000, vamana_worker_timeout_ms - total_waited_ms);
			if (wait_ms <= 0)
				break;

			rc = WaitLatch(&slot->latch,
						   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						   wait_ms,
						   PG_WAIT_EXTENSION);
			ResetLatch(&slot->latch);

			if (rc & WL_POSTMASTER_DEATH)
				ereport(ERROR, (errmsg("postmaster died")));

			CHECK_FOR_INTERRUPTS();

			status = pg_atomic_read_u32(&slot->status);
			if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
				break;

			if (rc & WL_TIMEOUT)
			{
				total_waited_ms += (int) wait_ms;
				if (total_waited_ms >= vamana_worker_timeout_ms)
					break;
			}
		}
	}
	PG_CATCH();
	{
		/*
		 * Exception (e.g., query cancel): try to cancel the pending request
		 * so the worker does not write to a slot about to be reused.
		 */
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
		DisownLatch(&slot->latch);
		PG_RE_THROW();
	}
	PG_END_TRY();

	DisownLatch(&slot->latch);

	status = pg_atomic_read_u32(&slot->status);

	if (status == VAMANA_SLOT_DONE)
	{
		int			nr;

		/*
		 * Load-acquire barrier before reading numResults and result data:
		 * ensures we observe all worker writes that happened before the DONE
		 * status store.  Must precede every load from the slot, including
		 * numResults itself.
		 */
		pg_read_barrier();
		nr = slot->numResults;

		if (nr > 0)
		{
			memcpy(results, VamanaWorkerSlotResults(slotIdx),
				   nr * sizeof(ItemPointerData));
			memcpy(distances, VamanaWorkerSlotDistances(slotIdx),
				   nr * sizeof(float));
		}
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return nr;
	}

	if (status == VAMANA_SLOT_ERROR)
	{
		ereport(WARNING,
				(errmsg("vamana worker error: %s", slot->errorMessage)));
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return -1;
	}

	/* Timeout or unexpected state: try to cancel if still PENDING */
	{
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
	}

	ereport(DEBUG1,
			(errmsg("vamana worker timed out after %d ms (status=%u)",
					total_waited_ms, status)));
	return -1;
}

/*
 * VamanaWorkerSignalReload
 *
 * Ask the worker to reload the given index (e.g., after an INSERT/REINDEX).
 * Writes the OID into the reload queue and kicks the worker latch.
 * Must NOT use SIGUSR1: that is owned by PostgreSQL's ProcSignal layer.
 */
void
VamanaWorkerSignalReload(Oid indexRelid)
{
	Assert(OidIsValid(indexRelid));

	for (int i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
	{
		uint32		expected = 0;

		if (pg_atomic_compare_exchange_u32(
										   &VamanaWorkerShmemPtr->reloadRequests[i].relid,
										   &expected, (uint32) indexRelid))
		{
			SetLatch(&VamanaWorkerShmemPtr->workerLatch);
			return;
		}
	}

	/*
	 * Queue full: set the reload_all flag so the worker performs a full
	 * reload of all cached indexes on its next cycle, ensuring no OID is
	 * silently dropped.
	 */
	pg_atomic_write_u32(&VamanaWorkerShmemPtr->reload_all, 1);
	ereport(WARNING,
			(errmsg("vamana worker reload queue full for index %u; "
					"worker will reload all cached indexes on next cycle",
					indexRelid)));
	SetLatch(&VamanaWorkerShmemPtr->workerLatch);
}

/*
 * VamanaWorkerWaitForSlot
 *
 * Shared wait-loop used by all backend-side submit helpers.  Owns the
 * backend's slot latch, waits for the worker to write DONE or ERROR, then
 * releases the latch.  Returns true on DONE, false on ERROR or timeout.
 * On false the slot is reset to EMPTY and slot->errorMessage is populated.
 */
static bool
VamanaWorkerWaitForSlot(VamanaWorkerSlot *slot, int timeout_ms)
{
	uint32		status;
	int			total_waited_ms = 0;

	PG_TRY();
	{
		while (true)
		{
			int			rc;
			long		wait_ms;

			wait_ms = Min(1000, timeout_ms - total_waited_ms);
			if (wait_ms <= 0)
				break;

			rc = WaitLatch(&slot->latch,
						   WL_LATCH_SET | WL_TIMEOUT | WL_POSTMASTER_DEATH,
						   wait_ms,
						   PG_WAIT_EXTENSION);
			ResetLatch(&slot->latch);

			if (rc & WL_POSTMASTER_DEATH)
				ereport(ERROR, (errmsg("postmaster died")));

			CHECK_FOR_INTERRUPTS();

			status = pg_atomic_read_u32(&slot->status);
			if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
				break;

			if (rc & WL_TIMEOUT)
			{
				total_waited_ms += (int) wait_ms;
				if (total_waited_ms >= timeout_ms)
					break;
			}
		}
	}
	PG_CATCH();
	{
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
		DisownLatch(&slot->latch);
		PG_RE_THROW();
	}
	PG_END_TRY();

	DisownLatch(&slot->latch);

	status = pg_atomic_read_u32(&slot->status);

	if (status == VAMANA_SLOT_DONE)
	{
		pg_read_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return true;
	}

	if (status == VAMANA_SLOT_ERROR)
	{
		pg_read_barrier();
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		return false;
	}

	/* Timeout: try to cancel the pending request. */
	{
		uint32		expected = VAMANA_SLOT_PENDING;

		pg_atomic_compare_exchange_u32(&slot->status, &expected,
									   VAMANA_SLOT_EMPTY);
	}
	snprintf(slot->errorMessage, sizeof(slot->errorMessage),
			 "vamana worker timed out after %d ms", total_waited_ms);
	return false;
}

static inline bool
VamanaWorkerWaitForSlotIPC(VamanaWorkerSlot *slot)
{
	return VamanaWorkerWaitForSlot(slot, vamana_worker_timeout_ms);
}


/*
 * VamanaWorkerClaimSlot
 *
 * Validate that the worker is available, claim this backend's slot, and
 * initialise the latch.  Returns the slot pointer on success, NULL on
 * failure (not available, slot busy).
 */
static VamanaWorkerSlot *
VamanaWorkerClaimSlot(Oid indexRelid)
{
	int			slotIdx;
	VamanaWorkerSlot *slot;
	uint32		status;

	if (!VamanaWorkerIsAvailable())
		return NULL;

	slotIdx = VAMANA_MY_SLOT_IDX;
	Assert(slotIdx >= 0 && slotIdx < VamanaWorkerShmemPtr->maxSlots);
	slot = &VamanaWorkerShmemPtr->slots[slotIdx];

	status = pg_atomic_read_u32(&slot->status);

	/* Clean up any leftover DONE/ERROR from a previous timed-out request. */
	if (status == VAMANA_SLOT_DONE || status == VAMANA_SLOT_ERROR)
	{
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		status = VAMANA_SLOT_EMPTY;
	}

	if (status != VAMANA_SLOT_EMPTY)
	{
		ereport(WARNING,
				(errmsg("vamana worker slot %d not empty (status=%u), cannot submit",
						slotIdx, status)));
		return NULL;
	}

	slot->indexRelid = indexRelid;
	OwnLatch(&slot->latch);
	ResetLatch(&slot->latch);

	return slot;
}

/*
 * VamanaWorkerSubmitInsert
 *
 * Backend-side: ask the worker to call SVSAddPoints for one vector.
 * On success, *externalId_out receives the allocated external ID.
 * Returns true on success, false on error (ereport(ERROR) in the latter case).
 */
bool
VamanaWorkerSubmitInsert(Oid indexRelid, const float *vector,
						 int dimensions, ItemPointer heap_tid,
						 uint64 *externalId_out)
{
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;
	bool		ok;

	slot = VamanaWorkerClaimSlot(indexRelid);
	if (slot == NULL)
	{
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("vamana index operations require the vamana background worker"),
				 errhint("Ensure svs is in shared_preload_libraries and restart PostgreSQL.")));
	}

	if (dimensions > VAMANA_MAX_DIM)
	{
		DisownLatch(&slot->latch);
		ereport(ERROR,
				(errmsg("vamana worker: insert vector has %d dimensions, max is %d",
						dimensions, VAMANA_MAX_DIM)));
	}

	memcpy(VamanaWorkerSlotQueryVec(slotIdx), vector,
		   dimensions * sizeof(float));
	slot->dimensions = dimensions;
	ItemPointerCopy(heap_tid, &slot->writeHeapTid);
	slot->slotKind = VAMANA_SLOTKIND_INSERT;

	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PENDING);
	SetLatch(&VamanaWorkerShmemPtr->workerLatch);

	ok = VamanaWorkerWaitForSlotIPC(slot);

	if (!ok)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("vamana worker insert failed: %s", slot->errorMessage)));

	pg_read_barrier();
	*externalId_out = slot->writeExternalId;
	return true;
}

/*
 * VamanaWorkerSubmitDelete
 *
 * Backend-side: ask the worker to call SVSDeletePoints for a list of IDs.
 * Returns true on success, false on error (logs a WARNING — vacuum must not
 * throw from the delete path because it is already iterating over a relation).
 */
bool
VamanaWorkerSubmitDelete(Oid indexRelid, const size_t *externalIds, int nIds)
{
	VamanaWorkerSlot *slot;
	int			slotIdx = VAMANA_MY_SLOT_IDX;
	bool		ok;

	if (nIds <= 0)
		return true;

	slot = VamanaWorkerClaimSlot(indexRelid);
	if (slot == NULL)
		return false;

	/*
	 * Pack external IDs into the query-vector buffer (reused as input for
	 * DELETE).  float[VAMANA_MAX_DIM] = 4*2000 = 8000 bytes; size_t is 8
	 * bytes, so we can hold up to 1000 IDs with natural alignment.
	 *
	 * Callers (vamanabulkdelete, undo_flush_batch) pre-split into batches of
	 * VAMANA_MAX_DELETE_IDS before calling.
	 */
	Assert(nIds <= (int) VAMANA_MAX_DELETE_IDS);

	memcpy(VamanaWorkerSlotQueryVec(slotIdx), externalIds, nIds * sizeof(size_t));

	slot->numResults = nIds;
	slot->slotKind = VAMANA_SLOTKIND_DELETE;

	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PENDING);
	SetLatch(&VamanaWorkerShmemPtr->workerLatch);

	ok = VamanaWorkerWaitForSlotIPC(slot);

	if (!ok)
	{
		ereport(WARNING,
				(errmsg("vamana worker delete failed: %s", slot->errorMessage)));
		return false;
	}
	return true;
}

/*
 * VamanaWorkerSubmitMaintenance
 *
 * Backend-side: ask the worker to run CONSOLIDATE or COMPACT.
 * Returns true on success, false on error.
 */
bool
VamanaWorkerSubmitMaintenance(Oid indexRelid, uint8 op)
{
	VamanaWorkerSlot *slot;
	bool		ok;

	slot = VamanaWorkerClaimSlot(indexRelid);
	if (slot == NULL)
		return false;

	slot->slotKind = VAMANA_SLOTKIND_MAINTENANCE;
	slot->maintenanceOp = op;

	pg_write_barrier();
	pg_atomic_write_u32(&slot->status, VAMANA_SLOT_PENDING);
	SetLatch(&VamanaWorkerShmemPtr->workerLatch);

	ok = VamanaWorkerWaitForSlotIPC(slot);

	if (!ok)
	{
		ereport(WARNING,
				(errmsg("vamana worker maintenance failed: %s", slot->errorMessage)));
		return false;
	}
	return true;
}


