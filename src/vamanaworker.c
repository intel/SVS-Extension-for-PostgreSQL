/*
 * vamanaworker.c
 *
 * Background worker for Vamana index.  A single dedicated process holds the
 * SVS index permanently and serves search requests from client backends via
 * shared memory.  Backends write query vectors into a per-backend slot and
 * wait on a shared latch; the worker drains all pending slots as one batch,
 * runs SVSSearch for each, and wakes the originating backends.
 *
 * This file contains: signal handlers, the main event loop and its helpers
 * (ProcessRequests, ProcessReloads), and the backend-side IPC API used by
 * client backends to submit operations and wait for results.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/xact.h"
#include "funcapi.h"
#include "miscadmin.h"
#include "postmaster/bgworker.h"
#include "storage/ipc.h"
#include "storage/latch.h"
#include "storage/lwlock.h"
#include "tcop/tcopprot.h"
#include "utils/builtins.h"
#include "utils/inval.h"
#include "utils/timestamp.h"
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
 * Signal flags (worker process only)
 * ----------------------------------------------------------------------- */

volatile sig_atomic_t worker_got_sigterm = false;
volatile sig_atomic_t worker_got_sighup = false;

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
 * Worker main loop helpers
 * ----------------------------------------------------------------------- */

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

/*
 * VACUUM FULL / CLUSTER replace the relfilenode without triggering any
 * extension AM callback.  This relcache callback catches those cases so
 * the BGW doesn't serve stale TIDs from the old heap.
 */
static void
VamanaRelcacheCallback(Datum arg, Oid relid)
{
	if (relid == InvalidOid)
		VamanaEvictAllCacheEntries();
	else
		VamanaEvictCacheEntry(relid);
}

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

	VamanaWorkerShmemPtr->dbOid = InvalidOid;
	InitSharedLatch(&VamanaWorkerShmemPtr->workerLatch);
	OwnLatch(&VamanaWorkerShmemPtr->workerLatch);

	if (strcmp(vamana_worker_database, "postgres") == 0)
		ereport(WARNING,
				(errmsg("vamana worker connecting to default database \"postgres\""),
				 errhint("Set svs.worker_database if your Vamana indexes are in a different database.")));
	BackgroundWorkerInitializeConnection(vamana_worker_database, NULL, 0);

	CacheRegisterRelcacheCallback(VamanaRelcacheCallback, (Datum) 0);

	VamanaWorkerShmemPtr->dbOid = MyDatabaseId;

	VamanaWorkerResetStaleSlots();
	VamanaWorkerLoadAllIndexes();

	/* Write pid last; backends treat non-zero pid as "cache is warm". */
	VamanaWorkerShmemPtr->workerPid = MyProcPid;

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

		pg_atomic_write_u64(&VamanaWorkerShmemPtr->heartbeat_ts,
							(uint64) GetCurrentTimestamp());

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

	/*
	 * A non-zero heartbeat that is older than VAMANA_HEARTBEAT_STALE_MS means the
	 * BGW main loop has stopped running — it is hung inside a library call
	 * and cannot drain slots or update its timestamp.
	 */
	{
		uint64		hb = pg_atomic_read_u64(&VamanaWorkerShmemPtr->heartbeat_ts);

		if (hb != 0)
		{
			TimestampTz now = GetCurrentTimestamp();
			long		age_ms;

			age_ms = (long) ((now - (TimestampTz) hb) / 1000);
			if (age_ms > VAMANA_HEARTBEAT_STALE_MS)
				return false;
		}
	}

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
				 errhint("Set svs.worker_database to the name of this database and restart the server.")));
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

	/*
	 * If the worker has written at least one heartbeat it was running
	 * recently.  A stale heartbeat means it is now hung, not still starting
	 * up — fail immediately rather than spinning for startup_timeout_ms.
	 */
	if (VamanaWorkerShmemPtr != NULL &&
		pg_atomic_read_u64(&VamanaWorkerShmemPtr->heartbeat_ts) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("vamana background worker unavailable after waiting up to %d ms; cannot %s index %u",
						VAMANA_HEARTBEAT_STALE_MS, operation, indexRelid),
				 errhint("Ensure vamana is in shared_preload_libraries and the server was restarted.")));

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
		char		msg[512];
		int			errcode_val = VamanaSlotErrcode(slot->errorCategory);

		strlcpy(msg, slot->errorMessage, sizeof(msg));
		pg_atomic_write_u32(&slot->status, VAMANA_SLOT_EMPTY);
		ereport(ERROR,
				(errcode(errcode_val),
				 errmsg("vamana worker error: %s", msg)));
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
				 errhint("Ensure the svs extension is listed in shared_preload_libraries and restart PostgreSQL.")));
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
				(errcode(VamanaSlotErrcode(slot->errorCategory)),
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
				(errcode(VamanaSlotErrcode(slot->errorCategory)),
				 errmsg("vamana worker delete failed: %s", slot->errorMessage)));
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
				(errcode(VamanaSlotErrcode(slot->errorCategory)),
				 errmsg("vamana worker maintenance failed: %s", slot->errorMessage)));
		return false;
	}
	return true;
}

/* -----------------------------------------------------------------------
 * pg_stat_vamana_worker(): SQL-callable SRF exposing worker shmem state.
 *
 * Returns one row per slot (indexed 0..maxSlots-1).  Worker-level fields
 * (worker_pid, db_oid, reload_queue_depth, active_slot_count, reload_all)
 * are repeated on every row so callers can filter or aggregate freely.
 *
 * Column layout (11 columns):
 *   0  worker_pid            int4
 *   1  db_oid                oid
 *   2  reload_queue_depth    int4
 *   3  active_slot_count     int4
 *   4  reload_all            bool
 *   5  heartbeat_ts          timestamptz (NULL if worker has not written first heartbeat)
 *   6  slot_index            int4
 *   7  slot_status           text   ("empty"/"pending"/"processing"/"done"/"error")
 *   8  index_relid           oid    (InvalidOid shown as NULL)
 *   9  slot_kind             text   ("search"/"insert"/"delete"/"maintenance"/NULL)
 *  10  error_message         text   (NULL unless status == error)
 * ----------------------------------------------------------------------- */

#define PG_STAT_VAMANA_WORKER_COLS 11

PGDLLEXPORT PG_FUNCTION_INFO_V1(pg_stat_vamana_worker);
Datum
pg_stat_vamana_worker(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	int			maxSlots;
	int			reloadQueueDepth;
	int			activeSlotCount;
	bool		reloadAll;
	pid_t		workerPid;
	Oid			dbOid;
	uint64		heartbeatRaw;
	int			i;

	InitMaterializedSRF(fcinfo, 0);

	if (VamanaWorkerShmemPtr == NULL)
		PG_RETURN_NULL();

	/*
	 * Take a consistent snapshot of the worker-level scalar fields.  Individual
	 * slot statuses are read with pg_atomic_read_u32 (no lock needed — each
	 * status word is updated atomically by the worker).
	 */
	workerPid = VamanaWorkerShmemPtr->workerPid;
	dbOid = VamanaWorkerShmemPtr->dbOid;
	maxSlots = VamanaWorkerShmemPtr->maxSlots;
	reloadAll = (pg_atomic_read_u32(&VamanaWorkerShmemPtr->reload_all) != 0);
	heartbeatRaw = pg_atomic_read_u64(&VamanaWorkerShmemPtr->heartbeat_ts);

	reloadQueueDepth = 0;
	for (i = 0; i < VAMANA_MAX_RELOAD_QUEUE; i++)
	{
		if (pg_atomic_read_u32(&VamanaWorkerShmemPtr->reloadRequests[i].relid) != 0)
			reloadQueueDepth++;
	}

	activeSlotCount = 0;
	for (i = 0; i < maxSlots; i++)
	{
		uint32		s = pg_atomic_read_u32(&VamanaWorkerShmemPtr->slots[i].status);

		if (s == VAMANA_SLOT_PENDING || s == VAMANA_SLOT_PROCESSING)
			activeSlotCount++;
	}

	for (i = 0; i < maxSlots; i++)
	{
		VamanaWorkerSlot *slot = &VamanaWorkerShmemPtr->slots[i];
		uint32		status;
		const char *statusStr;
		const char *kindStr;
		Datum		values[PG_STAT_VAMANA_WORKER_COLS];
		bool		nulls[PG_STAT_VAMANA_WORKER_COLS];

		memset(nulls, 0, sizeof(nulls));

		status = pg_atomic_read_u32(&slot->status);

		switch (status)
		{
			case VAMANA_SLOT_EMPTY:		 statusStr = "empty";		break;
			case VAMANA_SLOT_PENDING:	 statusStr = "pending";		break;
			case VAMANA_SLOT_PROCESSING: statusStr = "processing";	break;
			case VAMANA_SLOT_DONE:		 statusStr = "done";		break;
			case VAMANA_SLOT_ERROR:		 statusStr = "error";		break;
			default:					 statusStr = "unknown";		break;
		}

		if (status == VAMANA_SLOT_EMPTY)
		{
			kindStr = NULL;
		}
		else
		{
			switch (slot->slotKind)
			{
				case VAMANA_SLOTKIND_SEARCH:	  kindStr = "search";	    break;
				case VAMANA_SLOTKIND_INSERT:	  kindStr = "insert";	    break;
				case VAMANA_SLOTKIND_DELETE:	  kindStr = "delete";	    break;
				case VAMANA_SLOTKIND_MAINTENANCE: kindStr = "maintenance";  break;
				default:					      kindStr = "unknown";      break;
			}
		}

		/* worker-level columns */
		values[0] = Int32GetDatum((int32) workerPid);
		values[1] = ObjectIdGetDatum(dbOid);
		values[2] = Int32GetDatum(reloadQueueDepth);
		values[3] = Int32GetDatum(activeSlotCount);
		values[4] = BoolGetDatum(reloadAll);

		if (heartbeatRaw != 0)
			values[5] = TimestampTzGetDatum((TimestampTz) heartbeatRaw);
		else
			nulls[5] = true;

		/* slot-level columns */
		values[6] = Int32GetDatum(i);
		values[7] = CStringGetTextDatum(statusStr);

		if (slot->indexRelid != InvalidOid)
			values[8] = ObjectIdGetDatum(slot->indexRelid);
		else
			nulls[8] = true;

		if (kindStr != NULL)
			values[9] = CStringGetTextDatum(kindStr);
		else
			nulls[9] = true;

		if (status == VAMANA_SLOT_ERROR && slot->errorMessage[0] != '\0')
			values[10] = CStringGetTextDatum(slot->errorMessage);
		else
			nulls[10] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}
