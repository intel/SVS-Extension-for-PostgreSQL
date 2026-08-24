/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_replication.c
 *
 * Logical replication slot lifecycle and WAL replay for Vamana indexes.
 * Slot naming: "vamana_<dboid>_<indexoid>"
 */

#include "postgres.h"

#include "vamana.h"
#include "vamana_replication.h"
#include "vamana_subxact_guard.h"
#include "vamanaworker.h"

#include "access/heapam_xlog.h"
#include "access/tableam.h"
#include "access/xact.h"
#include "access/xlog.h"
#include "access/xlogrecovery.h"
#include "access/xlogutils.h"
#include "executor/tuptable.h"
#include "miscadmin.h"
#include "replication/decode.h"
#include "replication/logical.h"
#include "replication/snapbuild.h"
#include "replication/slot.h"
#include "storage/lwlock.h"
#include "utils/hsearch.h"
#include "utils/injection_point.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/relcache.h"
#include "utils/resowner.h"
#include "utils/snapmgr.h"
#include "utils/timestamp.h"

/*
 * One entry in the per-replay lsnToTidList hash.
 *
 * Single INSERT and DELETE: nTids == 1.
 * MULTI_INSERT: nTids == xlrec->ntuples, tids palloc'd in the decoding context
 * memory context.  nextIdx tracks which TID PluginChange should pop next;
 * PluginChange fires once per decoded row in FIFO order, guaranteed by
 * dlist_push_tail ordering in the reorder buffer.
 */
typedef struct LsnTidEntry
{
	XLogRecPtr		lsn;		/* hash key — must be first */
	ItemPointerData *tids;
	int				nTids;
	int				nextIdx;
} LsnTidEntry;

/*
 * Output-plugin private state allocated in ctx->context for the duration of
 * one VamanaReplayPendingChanges call.  Set as ctx->output_plugin_private by
 * PluginStartup.
 */
typedef struct VamanaReplayContext
{
	VamanaIndexCache *cache;		/* set after CreateDecodingContext */
	HTAB			 *lsnToTidList; /* XLogRecPtr → LsnTidEntry */
	int				  opsDecoded;
	XLogRecPtr		  lastChangeLsn;
	RelFileNumber	  heapRelfilenode;	/* current relfilenode of cache->heapRelid,
										 * resolved once per replay pass */
} VamanaReplayContext;

static void
SlotName(Oid dboid, Oid indexRelid, char *buf)
{
	snprintf(buf, NAMEDATALEN, "vamana_%u_%u", dboid, indexRelid);
}

/* Shared by every CreateDecodingContext/CreateInitDecodingContext call. */
#define VAMANA_XLOG_ROUTINE \
	XL_ROUTINE(.page_read = read_local_xlog_page, \
			   .segment_open = wal_segment_open, \
			   .segment_close = wal_segment_close)

static const VamanaReplayRole PrimaryReplayRole = {
	.current_wal_end     = GetFlushRecPtr,
	.creates_slot_on_load = false,
	.processes_write_ipc  = true,
	.persists_index      = true,
};

static const VamanaReplayRole StandbyReplayRole = {
	.current_wal_end     = GetXLogReplayRecPtr,
	.creates_slot_on_load = true,
	.processes_write_ipc  = false,
	.persists_index      = false,
};

const VamanaReplayRole *
VamanaGetReplayRole(void)
{
	return RecoveryInProgress() ? &StandbyReplayRole : &PrimaryReplayRole;
}

/*
 * Is this node the primary (not in recovery)?
 *
 * A node fact, evaluated against the calling process at call time; recovery
 * state is node-global.  Derived from the replay role rather than a second
 * RecoveryInProgress() call so this file stays that predicate's sole reader.
 */
bool
VamanaNodeIsPrimary(void)
{
	return VamanaGetReplayRole()->processes_write_ipc;
}

static void
DropSlotIfInactive(const char *slotName)
{
	ReplicationSlot *existing;

	/* need_lock=true holds ReplicationSlotControlLock while we read active_pid */
	existing = SearchNamedReplicationSlot(slotName, true);
	if (existing == NULL)
		return;

	if (existing->active_pid != 0)
		return;

	ReplicationSlotDrop(slotName, /*nowait=*/ false);
}

/*
 * PluginStartup
 *
 * Called by both CreateInitDecodingContext (is_init=true, slot creation) and
 * CreateDecodingContext (is_init=false, replay).  On the replay path allocate
 * a VamanaReplayContext and the lsnToTidList hash in ctx->context so they are
 * freed automatically with FreeDecodingContext.  VamanaReplayPendingChanges
 * sets priv->cache immediately after CreateDecodingContext returns.
 */
static void
PluginStartup(LogicalDecodingContext *ctx, OutputPluginOptions *opt,
			  bool is_init)
{
	opt->output_type = OUTPUT_PLUGIN_BINARY_OUTPUT;
	opt->receive_rewrites = false;

	if (!is_init)
	{
		VamanaReplayContext *priv;
		HASHCTL				hctl;

		priv = MemoryContextAllocZero(ctx->context, sizeof(VamanaReplayContext));
		priv->lastChangeLsn = InvalidXLogRecPtr;

		memset(&hctl, 0, sizeof(hctl));
		hctl.keysize   = sizeof(XLogRecPtr);
		hctl.entrysize = sizeof(LsnTidEntry);
		hctl.hcxt      = ctx->context;
		priv->lsnToTidList = hash_create("vamana lsnToTidList",
										 128,
										 &hctl,
										 HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

		ctx->output_plugin_private = priv;
	}
}

/*
 * VamanaPreScanWalRecord
 *
 * Inspect the raw WAL record currently loaded in ctx->reader and, if it is a
 * heap INSERT or DELETE on the relation priv->cache->heapRelid, store the
 * heap TID(s) in priv->lsnToTidList keyed by ReadRecPtr.
 *
 * This must be called before LogicalDecodingProcessRecord because logical
 * decoding deliberately invalidates t_self on every decoded tuple.  PluginChange
 * then retrieves the TID by looking up change->lsn.
 */
static void
VamanaPreScanWalRecord(LogicalDecodingContext *ctx, VamanaReplayContext *priv)
{
	uint8			rmid;
	uint8			info;
	RelFileLocator	rlocator;
	BlockNumber		blkno;
	XLogRecPtr		lsn;
	LsnTidEntry	   *entry;
	bool			found;

	if (priv == NULL || priv->cache == NULL)
		return;

	rmid = XLogRecGetRmid(ctx->reader);
	info = XLogRecGetInfo(ctx->reader) & XLOG_HEAP_OPMASK;
	lsn  = ctx->reader->ReadRecPtr;

	ereport(DEBUG1,
			(errmsg("vamana prescan: rmid=%u info=0x%x lsn=%X/%X",
					(unsigned) rmid, (unsigned) info,
					LSN_FORMAT_ARGS(lsn))));

	if (rmid == RM_HEAP_ID && info == XLOG_HEAP_DELETE)
	{
		xl_heap_delete *xlrec = (xl_heap_delete *) XLogRecGetData(ctx->reader);

		XLogRecGetBlockTag(ctx->reader, 0, &rlocator, NULL, &blkno);
		if (rlocator.relNumber != priv->heapRelfilenode)
			return;

		entry = hash_search(priv->lsnToTidList, &lsn, HASH_ENTER, &found);
		if (!found)
		{
			entry->tids = MemoryContextAlloc(ctx->context,
											 sizeof(ItemPointerData));
			entry->nTids   = 1;
			entry->nextIdx = 0;
		}
		ItemPointerSet(&entry->tids[0], blkno, xlrec->offnum);
	}
	else if (rmid == RM_HEAP_ID && info == XLOG_HEAP_INSERT)
	{
		xl_heap_insert *xlrec = (xl_heap_insert *) XLogRecGetData(ctx->reader);

		XLogRecGetBlockTag(ctx->reader, 0, &rlocator, NULL, &blkno);
		if (!(xlrec->flags & XLH_INSERT_CONTAINS_NEW_TUPLE))
			return;
		if (rlocator.relNumber != priv->heapRelfilenode)
			return;

		entry = hash_search(priv->lsnToTidList, &lsn, HASH_ENTER, &found);
		if (!found)
		{
			entry->tids = MemoryContextAlloc(ctx->context,
											 sizeof(ItemPointerData));
			entry->nTids   = 1;
			entry->nextIdx = 0;
		}
		ItemPointerSet(&entry->tids[0], blkno, xlrec->offnum);
	}
	else if (rmid == RM_HEAP2_ID &&
			 ((XLogRecGetInfo(ctx->reader) & XLOG_HEAP_OPMASK) == XLOG_HEAP2_MULTI_INSERT))
	{
		xl_heap_multi_insert *xlrec =
			(xl_heap_multi_insert *) XLogRecGetData(ctx->reader);
		bool	isinit;
		int		i;

		if (!(xlrec->flags & XLH_INSERT_CONTAINS_NEW_TUPLE))
			return;

		XLogRecGetBlockTag(ctx->reader, 0, &rlocator, NULL, &blkno);
		if (rlocator.relNumber != priv->heapRelfilenode)
			return;

		isinit = (XLogRecGetInfo(ctx->reader) & XLOG_HEAP_INIT_PAGE) != 0;

		entry = hash_search(priv->lsnToTidList, &lsn, HASH_ENTER, &found);
		if (!found)
		{
			entry->tids = MemoryContextAlloc(ctx->context,
											 (Size) xlrec->ntuples *
											 sizeof(ItemPointerData));
			entry->nTids   = xlrec->ntuples;
			entry->nextIdx = 0;
		}

		for (i = 0; i < xlrec->ntuples; i++)
		{
			OffsetNumber offnum = isinit
				? (OffsetNumber) (FirstOffsetNumber + i)
				: xlrec->offsets[i];

			ItemPointerSet(&entry->tids[i], blkno, offnum);
		}
	}
}

static void
PluginBegin(LogicalDecodingContext *ctx, ReorderBufferTXN *txn)
{
	ereport(DEBUG1,
			(errmsg("vamana PluginBegin: xid=%u lsn=%X/%X",
					txn->xid,
					LSN_FORMAT_ARGS(txn->first_lsn))));
}

/*
 * ApplyInsertChange
 *
 * Fetch the heap tuple at tid, detoast the vector, and add it to the SVS
 * graph, then update the TID mappings and counters.  The heap fetch and
 * detoast are the only operations that can ERROR (VACUUMed TID, missing TOAST
 * chunks, OOM); they run strictly before the non-transactional SVSAddPoints so
 * a failure never leaves the graph half-mutated.  Runs inside the caller's
 * per-record subtransaction.
 */
static void
ApplyInsertChange(VamanaReplayContext *priv, Relation relation,
				  ItemPointerData tid, XLogRecPtr lsn)
{
	VamanaIndexCache *cache = priv->cache;
	TupleTableSlot *slot;
	Datum		datum;
	bool		isnull;
	Vector	   *vec;
	size_t		externalId;
	int			added;

	/* Idempotency: TID already in graph (e.g. restored from checkpoint). */
	if (cache->tidToExternalId != NULL &&
		hash_search(cache->tidToExternalId, &tid, HASH_FIND, NULL) != NULL)
		return;

	if (cache->svsIndex == NULL)
		return;

	/*
	 * Logical decoding only delivers committed changes, so SnapshotAny is
	 * correct.  CheckXidAlive is InvalidTransactionId here because we do
	 * not use streaming or two-phase decoding.
	 */
	slot = MakeSingleTupleTableSlot(RelationGetDescr(relation),
									&TTSOpsBufferHeapTuple);
	if (!table_tuple_fetch_row_version(relation, &tid, SnapshotAny, slot))
	{
		ExecDropSingleTupleTableSlot(slot);
		return;
	}

	datum = slot_getattr(slot, cache->vectorAttNum + 1, &isnull);
	if (isnull)
	{
		ExecDropSingleTupleTableSlot(slot);
		return;
	}

	/* Models a detoast/fetch failure (VACUUMed TID, missing TOAST) for tests. */
	INJECTION_POINT("vamana-replay-apply-insert", NULL);

	vec = (Vector *) PG_DETOAST_DATUM_COPY(datum);
	ExecDropSingleTupleTableSlot(slot);

	externalId = (size_t) cache->nextExternalId;
	added = SVSAddPoints(cache->svsIndex, vec->x, &externalId, 1);
	pfree(vec);

	if (added <= 0)
	{
		ereport(WARNING,
				(errmsg("vamana replay: SVSAddPoints failed for index %u",
						cache->indexRelid)));
		return;
	}

	if ((int) externalId >= cache->tidMappingCapacity)
	{
		int			newCap = cache->tidMappingCapacity > 0
			? cache->tidMappingCapacity * 2 : 1024;
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

	ItemPointerCopy(&tid, &cache->tidMapping[externalId]);

	if (cache->tidToExternalId != NULL)
	{
		bool	found;
		uint64	eid = (uint64) externalId;
		char   *hentry = (char *) hash_search(cache->tidToExternalId,
											  &tid, HASH_ENTER, &found);

		if (!found)
			memcpy(hentry + sizeof(ItemPointerData), &eid, sizeof(uint64));
	}

	cache->nextExternalId = externalId + 1;
	cache->numVectors++;
	cache->opsSinceCheckpoint++;
	cache->lastWriteTime = GetCurrentTimestamp();
	priv->lastChangeLsn = lsn;
	priv->opsDecoded++;

	ereport(DEBUG1,
			(errmsg("vamana replay: applied INSERT TID (%u,%u) externalId=%zu index %u",
					ItemPointerGetBlockNumber(&tid),
					ItemPointerGetOffsetNumber(&tid),
					externalId,
					cache->indexRelid)));
}

/*
 * ApplyDeleteChange
 *
 * Remove the point mapped to tid from the SVS graph and drop its TID mappings.
 * All operations are in-memory lookups and graph-library calls that report
 * failure by return code, so this branch does not touch the heap and cannot
 * ERROR on VACUUMed or missing data.
 */
static void
ApplyDeleteChange(VamanaReplayContext *priv, ItemPointerData tid,
				  XLogRecPtr lsn)
{
	VamanaIndexCache *cache = priv->cache;
	char	   *hentry;
	uint64		externalId;
	size_t		deleteId;
	int			deleted;

	if (cache->tidToExternalId == NULL)
		return;

	hentry = (char *) hash_search(cache->tidToExternalId, &tid,
								  HASH_FIND, NULL);
	if (hentry == NULL)
		return;

	memcpy(&externalId, hentry + sizeof(ItemPointerData), sizeof(uint64));

	if (cache->svsIndex == NULL)
		return;

	deleteId = (size_t) externalId;
	deleted = SVSDeletePoints(cache->svsIndex, &deleteId, 1);

	if (deleted < 0)
	{
		ereport(WARNING,
				(errmsg("vamana replay: SVSDeletePoints failed for index %u externalId=%lu",
						cache->indexRelid, (unsigned long) externalId)));
		return;
	}

	if ((int) externalId < cache->tidMappingCapacity)
		ItemPointerSetInvalid(&cache->tidMapping[externalId]);

	hash_search(cache->tidToExternalId, &tid, HASH_REMOVE, NULL);

	cache->numDeleted++;
	cache->numVectors = (cache->numVectors > 0) ? cache->numVectors - 1 : 0;
	cache->opsSinceCheckpoint++;
	cache->lastWriteTime = GetCurrentTimestamp();
	priv->lastChangeLsn = lsn;
	priv->opsDecoded++;
}

/* Arguments for ApplyChangeBody, bundled for VamanaRunInSubXact. */
typedef struct ApplyChangeArgs
{
	VamanaReplayContext	   *priv;
	Relation				relation;
	ReorderBufferChange	   *change;
	ItemPointerData			tid;
} ApplyChangeArgs;

static void
ApplyChangeBody(void *arg)
{
	ApplyChangeArgs *args = (ApplyChangeArgs *) arg;

	if (args->change->action == REORDER_BUFFER_CHANGE_INSERT)
		ApplyInsertChange(args->priv, args->relation, args->tid, args->change->lsn);
	else
		ApplyDeleteChange(args->priv, args->tid, args->change->lsn);
}

/*
 * ReplayChangeGuarded
 *
 * Apply one decoded change inside a per-record subtransaction so that a
 * corrupt or already-VACUUMed source tuple is skipped with a WARNING instead
 * of aborting the whole replay pass.  This is the in-tree "catch, log, skip,
 * continue" pattern (PL/pgSQL exec_stmt_block, ReorderBufferProcessTXN); a
 * bare PG_TRY would not work because a heap/TOAST ERROR aborts the surrounding
 * transaction, which cannot then be reused. A shutdown cancel is not a
 * corrupt change, so VamanaRunInSubXact re-throws it instead of swallowing it,
 * letting the drain owner run rather than dropping a good change.
 *
 * A skipped INSERT costs only recall (the vector is absent from the graph) and
 * is self-consistent, so no failure state is recorded.
 */
static void
ReplayChangeGuarded(VamanaReplayContext *priv, Relation relation,
					ReorderBufferChange *change, ItemPointerData tid)
{
	ApplyChangeArgs		args = {priv, relation, change, tid};
	VamanaSubXactResult	result;

	result = VamanaRunInSubXact(ApplyChangeBody, &args, VamanaShutdownCancelPending);

	if (!result.succeeded)
	{
		ereport(WARNING,
				(errmsg("vamana replay: skipping change at %X/%X: %s",
						LSN_FORMAT_ARGS(change->lsn), result.edata->message)));
		FreeErrorData(result.edata);
	}
}

/*
 * PluginChange
 *
 * Called once per committed heap change.  Looks up the TID that
 * VamanaPreScanWalRecord pre-populated for this change's LSN, then applies the
 * mutation (INSERT or DELETE) to the in-memory SVS graph under a per-record
 * subtransaction.
 */
static void
PluginChange(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			 Relation relation, ReorderBufferChange *change)
{
	VamanaReplayContext *priv = (VamanaReplayContext *) ctx->output_plugin_private;
	LsnTidEntry		   *entry;
	ItemPointerData		tid;

	if (priv == NULL || priv->cache == NULL)
		return;

	if (RelationGetRelid(relation) != priv->cache->heapRelid)
		return;

	if (change->action != REORDER_BUFFER_CHANGE_INSERT &&
		change->action != REORDER_BUFFER_CHANGE_DELETE)
		return;

	ereport(DEBUG1,
			(errmsg("vamana PluginChange: action=%d relid=%u heapRelid=%u",
					change->action,
					RelationGetRelid(relation),
					priv->cache->heapRelid)));

	/*
	 * Consume this change's TID.  The cursor advances even when the apply is
	 * skipped: the change has been delivered and must not be reprocessed.
	 */
	entry = hash_search(priv->lsnToTidList, &change->lsn, HASH_FIND, NULL);
	if (entry == NULL || entry->nextIdx >= entry->nTids)
		return;

	tid = entry->tids[entry->nextIdx++];

	ReplayChangeGuarded(priv, relation, change, tid);
}

static void
PluginCommit(LogicalDecodingContext *ctx, ReorderBufferTXN *txn,
			 XLogRecPtr commitLsn)
{
	ereport(DEBUG1,
			(errmsg("vamana PluginCommit: xid=%u commitLsn=%X/%X",
					txn->xid,
					LSN_FORMAT_ARGS(commitLsn))));
}

void
_PG_output_plugin_init(OutputPluginCallbacks *cb)
{
	cb->startup_cb = PluginStartup;
	cb->begin_cb   = PluginBegin;
	cb->change_cb  = PluginChange;
	cb->commit_cb  = PluginCommit;
}

/*
 * VamanaTryAcquireSlotNoWait
 *
 * Acquire the named slot without blocking. Returns false, with no slot held,
 * if it does not exist or is already active in another process -- both
 * ordinary, retryable outcomes, not decoding failures. Any other error from
 * ReplicationSlotAcquire still propagates.
 */
static bool
VamanaTryAcquireSlotNoWait(const char *slotName)
{
	bool		acquired = true;

	PG_TRY();
	{
		ReplicationSlotAcquire(slotName, /*nowait=*/ true,
							   /*error_if_invalid=*/ false);
	}
	PG_CATCH();
	{
		int			sqlerrcode = geterrcode();

		if (sqlerrcode != ERRCODE_OBJECT_IN_USE &&
			sqlerrcode != ERRCODE_UNDEFINED_OBJECT)
			PG_RE_THROW();

		FlushErrorState();
		acquired = false;
	}
	PG_END_TRY();

	return acquired;
}

/*
 * VamanaOpenDecoder
 *
 * Build a LogicalDecodingContext against the slot already acquired by
 * VamanaTryAcquireSlotNoWait, and position its reader at restart_lsn.  Shared
 * by every caller that walks WAL from the slot's last confirmed point.
 */
static LogicalDecodingContext *
VamanaOpenDecoder(void)
{
	LogicalDecodingContext *ctx;

	ctx = CreateDecodingContext(InvalidXLogRecPtr,
								NIL,
								/*fast_forward=*/ false,
								VAMANA_XLOG_ROUTINE,
								NULL, NULL, NULL);
	XLogBeginRead(ctx->reader, MyReplicationSlot->data.restart_lsn);
	return ctx;
}

/*
 * VamanaRunDecodeLoop
 *
 * Read WAL records from ctx->reader up to endOfWal.  perRecord owns all
 * per-record work, including the LogicalDecodingProcessRecord call itself
 * (callers differ in whether other work must happen before or after it), and
 * may return true to stop the loop early (e.g. once the SnapBuild reaches
 * CONSISTENT).  errContext tags the WAL-read-error message so each caller's
 * existing wording survives as an argument rather than a copy.
 */
static void
VamanaRunDecodeLoop(LogicalDecodingContext *ctx, XLogRecPtr endOfWal,
					 const char *errContext,
					 bool (*perRecord) (LogicalDecodingContext *ctx, void *arg),
					 void *arg)
{
	while (ctx->reader->EndRecPtr < endOfWal)
	{
		XLogRecord *record;
		char	   *errm = NULL;

		record = XLogReadRecord(ctx->reader, &errm);
		if (errm != NULL)
			elog(ERROR, "%s: WAL read error: %s", errContext, errm);
		if (record == NULL)
			break;

		if (perRecord(ctx, arg))
			break;

		CHECK_FOR_INTERRUPTS();
	}
}

/* Release ctx and the slot it was opened against, on the success path. */
static void
VamanaCloseDecoder(LogicalDecodingContext *ctx)
{
	FreeDecodingContext(ctx);
	ReplicationSlotRelease();
}

/* Per-record callback for VamanaReplayPendingChanges's decode loop. */
static bool
ReplayRecordCallback(LogicalDecodingContext *ctx, void *arg)
{
	VamanaReplayContext *priv = (VamanaReplayContext *) arg;

	/* Models an unrecoverable decode error escaping to the drain handler. */
	INJECTION_POINT("vamana-replay-decode-record", NULL);

	VamanaPreScanWalRecord(ctx, priv);
	LogicalDecodingProcessRecord(ctx, ctx->reader);
	return false;
}

/*
 * VamanaReplayPendingChanges
 *
 * Acquire the index's replication slot, open a LogicalDecodingContext starting
 * from the slot's restart_lsn, and drive the WAL decode loop up to the current
 * end-of-WAL.  VamanaPreScanWalRecord populates lsnToTidList before each
 * LogicalDecodingProcessRecord call so that PluginChange can resolve heap TIDs.
 *
 * Assumes an open transaction with an active snapshot; VamanaReplicationDrainSlot
 * owns that lifecycle.  Returns silently if the slot is already acquired by
 * another process, and releases the slot on the normal-completion path.
 */
static void
VamanaReplayPendingChanges(VamanaIndexCache *cache)
{
	VamanaReplicationSlot  *slot = cache->replicationSlot;
	LogicalDecodingContext *ctx;
	VamanaReplayContext	   *priv;
	XLogRecPtr				endOfWal;

	{
		XLogRecPtr currentEnd = VamanaGetReplayRole()->current_wal_end(NULL);

		if (cache->lastReplayWalEnd != InvalidXLogRecPtr &&
			currentEnd <= cache->lastReplayWalEnd)
			return;
	}

	if (!VamanaTryAcquireSlotNoWait(slot->slotName))
		return;

	/* test/t/08_standby_replay.pl counts these to bound idle decode attempts. */
	ereport(DEBUG1,
			(errmsg("vamana replay: entering CreateDecodingContext for slot \"%s\" confirmed_flush=%X/%X",
					slot->slotName,
					LSN_FORMAT_ARGS(MyReplicationSlot->data.confirmed_flush))));

	ctx = VamanaOpenDecoder();
	priv = (VamanaReplayContext *) ctx->output_plugin_private;
	priv->cache = cache;

	endOfWal = VamanaGetReplayRole()->current_wal_end(NULL);

	InvalidateSystemCaches();

	{
		Relation	heapRel = RelationIdGetRelation(cache->heapRelid);

		priv->heapRelfilenode = RelationIsValid(heapRel)
			? heapRel->rd_locator.relNumber
			: InvalidRelFileNumber;
		if (RelationIsValid(heapRel))
			RelationClose(heapRel);
	}

	VamanaRunDecodeLoop(ctx, endOfWal, "vamana replay", ReplayRecordCallback, priv);

	if (priv->lastChangeLsn != InvalidXLogRecPtr)
		cache->lastReplayLsn = priv->lastChangeLsn;

	if (priv->opsDecoded > 0)
		LogicalConfirmReceivedLocation(ctx->reader->EndRecPtr);

	cache->lastReplayWalEnd = endOfWal;

	VamanaCloseDecoder(ctx);
}

/*
 * VamanaReplicationSlotWalLagExceeds
 *
 * True when the index's slot pins more than max_slot_wal_size worth of WAL,
 * measured as current-WAL-end minus restart_lsn (the same raw LSN subtraction
 * PG uses for slot retention accounting).  Used to bound disk usage: a slot
 * this far behind (BGW downtime, infrequent checkpoints, long transactions) is
 * cheaper to drop and rebuild from the heap than to drain.
 *
 * No-op-safe when the slot does not exist or has no restart_lsn yet.
 */
bool
VamanaReplicationSlotWalLagExceeds(Oid indexRelid, int maxLagMb)
{
	char				slotName[NAMEDATALEN];
	ReplicationSlot	   *slot;
	XLogRecPtr			restartLsn;
	XLogRecPtr			currentEnd;

	SlotName(VamanaWorkerShmemPtr->dbOid, indexRelid, slotName);

	slot = SearchNamedReplicationSlot(slotName, true);
	if (slot == NULL)
		return false;

	SpinLockAcquire(&slot->mutex);
	restartLsn = slot->data.restart_lsn;
	SpinLockRelease(&slot->mutex);

	if (restartLsn == InvalidXLogRecPtr)
		return false;

	currentEnd = VamanaGetReplayRole()->current_wal_end(NULL);

	return currentEnd - restartLsn > (uint64) maxLagMb * 1024 * 1024;
}

/*
 * True once the index's slot has reached snapshot consistency (confirmed_flush
 * is set).  A freshly created slot has confirmed_flush unset until snapshot
 * build reaches CONSISTENT, so a slot handle existing is not by itself proof
 * of consistency.  False if the slot does not exist.
 */
bool
VamanaReplicationSlotIsConsistent(Oid dboid, Oid indexRelid)
{
	char				slotName[NAMEDATALEN];
	ReplicationSlot	   *slot;
	XLogRecPtr			confirmedFlush;

	SlotName(dboid, indexRelid, slotName);

	slot = SearchNamedReplicationSlot(slotName, true);
	if (slot == NULL)
		return false;

	SpinLockAcquire(&slot->mutex);
	confirmedFlush = slot->data.confirmed_flush;
	SpinLockRelease(&slot->mutex);

	return confirmedFlush != InvalidXLogRecPtr;
}

/*
 * VamanaRecoverFromReplayError
 *
 * Recover from an unrecoverable decoding error and self-heal by rebuilding the
 * index from the heap.  A decode error means the reader cannot advance past the
 * offending record, so retrying the same LSN would only pin WAL and fail again;
 * the heap is authoritative, so we discard the slot and graph and rebuild on
 * first error rather than waiting for an operator (contrast the apply worker's
 * disable_on_error, which stops and waits).
 *
 * Slot release is explicit and precedes the drop inside VamanaForceHeapRebuild:
 * AbortCurrentTransaction does not release replication slots, and the drop
 * no-ops while the slot is still active.  FreeDecodingContext is deliberately
 * not called: the abort reclaims its memory (it lives in a child of the
 * transaction context) and the slot drop rmtrees its spill files, while calling
 * it here would risk a use-after-free of MyReplicationSlot.
 */
static void
VamanaRecoverFromReplayError(Oid indexRelid)
{
	HOLD_INTERRUPTS();
	EmitErrorReport();
	if (MyReplicationSlot != NULL)
		ReplicationSlotRelease();
	AbortOutOfAnyTransaction();
	FlushErrorState();
	RESUME_INTERRUPTS();

	VamanaForceHeapRebuild(indexRelid);

	ereport(LOG,
			(errmsg("vamana replay: unrecoverable decoding error for index %u; "
					"dropped slot and forced rebuild from heap", indexRelid)));
}

/*
 * VamanaReplicationDrainSlot
 *
 * Sole owner of the per-index replay unit: resolves the cache entry, opens and
 * commits the transaction and snapshot the decode requires, and guarantees the
 * eviction-suppression state is restored on every exit path.
 *
 * No-op when the index is not cached or has no slot.  Eviction suppression is
 * saved and restored (not forced off) so the function nests correctly inside
 * callers that hold their own suppressed span.  An unrecoverable decode error
 * is contained here: the slot is dropped and the index rebuilt from the heap,
 * so the error does not propagate and stall the worker.
 */
void
VamanaReplicationDrainSlot(Oid indexRelid)
{
	VamanaIndexCache *cache = VamanaGetCache(indexRelid);
	bool			  prevSuppressed;

	if (cache == NULL || cache->replicationSlot == NULL)
		return;

	prevSuppressed = vamana_eviction_suppressed;
	vamana_eviction_suppressed = true;

	PG_TRY();
	{
		SetCurrentStatementStartTimestamp();
		StartTransactionCommand();
		PushActiveSnapshot(GetTransactionSnapshot());

		VamanaReplayPendingChanges(cache);

		PopActiveSnapshot();
		CommitTransactionCommand();

		vamana_eviction_suppressed = prevSuppressed;
	}
	PG_CATCH();
	{
		vamana_eviction_suppressed = prevSuppressed;

		/*
		 * A shutdown cancel is not a decode failure: re-throw so the drain owner
		 * runs, rather than dropping the slot and forcing a needless rebuild.
		 */
		if (VamanaShutdownCancelPending())
			PG_RE_THROW();

		VamanaRecoverFromReplayError(indexRelid);
	}
	PG_END_TRY();
}

/*
 * Create a persistent logical replication slot for the given index.
 * Drops any existing inactive slot first (handles failed CREATE INDEX cleanup).
 */
void
VamanaReplicationCreate(Oid dboid, Oid indexRelid)
{
	char					slotName[NAMEDATALEN];
	LogicalDecodingContext *initCtx;

	SlotName(dboid, indexRelid, slotName);

	DropSlotIfInactive(slotName);

	ReplicationSlotCreate(slotName,
						  /*db_specific=*/ true,
						  RS_EPHEMERAL,
						  /*two_phase=*/ false,
						  /*failover=*/ false,
						  /*synced=*/ false);

	/* Sets restart_lsn via ReplicationSlotReserveWal() and validates the plugin. */
	initCtx = CreateInitDecodingContext("svs",
										NIL,
										/*need_full_snapshot=*/ false,
										InvalidXLogRecPtr,
										VAMANA_XLOG_ROUTINE,
										NULL, NULL, NULL);
	FreeDecodingContext(initCtx);

	ReplicationSlotPersist();
	ReplicationSlotRelease();

	ereport(DEBUG1,
			(errmsg("vamana: created replication slot \"%s\"", slotName)));
}

/*
 * Scan WAL from restart_lsn until the SnapBuild reaches CONSISTENT, then
 * serialize the snapshot to pg_logical/snapshots/.  Must be called outside
 * any open transaction and after all transactions that were active at slot
 * creation have committed — otherwise DecodingContextFindStartpoint deadlocks
 * waiting for those XIDs.
 *
 * On post-crash replay, CreateDecodingContext restores the serialized snapshot
 * via SnapBuildRestore and reaches CONSISTENT immediately, without requiring
 * additional RUNNING_XACTS records in the WAL scan range.  confirmed_flush is
 * set to the LSN where CONSISTENT was reached, which becomes start_decoding_at
 * in the SnapBuild and bounds which commits are delivered to PluginChange.
 */
void
VamanaReplicationBuildSnapshot(Oid dboid, Oid indexRelid)
{
	char					slotName[NAMEDATALEN];
	LogicalDecodingContext *ctx;

	SlotName(dboid, indexRelid, slotName);

	if (SearchNamedReplicationSlot(slotName, true) == NULL)
		return;

	if (!VamanaTryAcquireSlotNoWait(slotName))
		return;

	PG_TRY();
	{
		ctx = CreateDecodingContext(InvalidXLogRecPtr,
									NIL,
									/*fast_forward=*/ false,
									VAMANA_XLOG_ROUTINE,
									NULL, NULL, NULL);

		/* Waits for a not-yet-replayed xl_running_xacts; positions its own reader. */
		DecodingContextFindStartpoint(ctx);

		VamanaCloseDecoder(ctx);
	}
	PG_CATCH();
	{
		if (MyReplicationSlot != NULL)
			ReplicationSlotRelease();
		PG_RE_THROW();
	}
	PG_END_TRY();
}

/* Per-record callback for VamanaReplicationActivateSlotBounded's decode loop. */
static bool
ActivateSlotRecordCallback(LogicalDecodingContext *ctx, void *arg)
{
	LogicalDecodingProcessRecord(ctx, ctx->reader);
	return DecodingContextReady(ctx);
}

/*
 * Scan WAL from restart_lsn up to role->current_wal_end and stop, whether or
 * not the SnapBuild reaches CONSISTENT.  Unlike VamanaReplicationBuildSnapshot
 * this never waits for a not-yet-replayed xl_running_xacts record, so it is
 * safe to call from the main loop.  A pass that stops short of CONSISTENT
 * discards its progress (the builder is freed with the decoding context; a
 * snapshot is serialized only once CONSISTENT is reached), so the next pass
 * starts over from restart_lsn; convergence needs only that the primary keep
 * emitting xl_running_xacts.
 */
void
VamanaReplicationActivateSlotBounded(Oid dboid, Oid indexRelid)
{
	char					slotName[NAMEDATALEN];
	LogicalDecodingContext *ctx;
	XLogRecPtr				endOfWal;

	SlotName(dboid, indexRelid, slotName);

	if (SearchNamedReplicationSlot(slotName, true) == NULL)
		return;

	if (!VamanaTryAcquireSlotNoWait(slotName))
		return;

	PG_TRY();
	{
		ctx = VamanaOpenDecoder();
		endOfWal = VamanaGetReplayRole()->current_wal_end(NULL);

		VamanaRunDecodeLoop(ctx, endOfWal, "vamana slot activation",
							ActivateSlotRecordCallback, NULL);

		if (DecodingContextReady(ctx))
		{
			SpinLockAcquire(&MyReplicationSlot->mutex);
			MyReplicationSlot->data.confirmed_flush = ctx->reader->EndRecPtr;
			SpinLockRelease(&MyReplicationSlot->mutex);
		}

		VamanaCloseDecoder(ctx);
	}
	PG_CATCH();
	{
		if (MyReplicationSlot != NULL)
			ReplicationSlotRelease();
		PG_RE_THROW();
	}
	PG_END_TRY();
}

/*
 * Bootstrap a slot on a standby: create it, then build its initial snapshot.
 *
 * The drain path opens a decoding context without finding a startpoint, so it
 * needs the serialized snapshot to already exist.  On a standby that snapshot
 * only reaches consistency once an xl_running_xacts record streams from the
 * primary, which requires hot_standby_feedback and a physical slot to keep the
 * standby's catalog_xmin pinned.
 *
 * Must be called outside any transaction.
 */
void
VamanaReplicationCreateOnStandby(Oid dboid, Oid indexRelid)
{
	VamanaReplicationCreate(dboid, indexRelid);
	VamanaReplicationBuildSnapshot(dboid, indexRelid);
}

/*
 * Create the index's slot if this is a standby and none exists yet.  A standby
 * must bootstrap its own slots: its base backup excludes pg_replslot and the
 * primary write path that creates them never runs here.  Idempotent; must be
 * called outside any transaction.
 */
void
VamanaReplicationEnsureSlot(Oid dboid, Oid indexRelid)
{
	VamanaIndexCache *cache;

	if (!VamanaGetReplayRole()->creates_slot_on_load)
		return;

	cache = VamanaGetCache(indexRelid);
	if (cache == NULL || cache->replicationSlot != NULL)
		return;

	VamanaReplicationCreateOnStandby(dboid, indexRelid);
	cache->replicationSlot = VamanaReplicationOpen(dboid, indexRelid);
}

/*
 * Open a lightweight handle referencing the persistent slot.
 * The slot is not acquired; it remains inactive and droppable.
 * Returns NULL if the slot does not exist.
 */
VamanaReplicationSlot *
VamanaReplicationOpen(Oid dboid, Oid indexRelid)
{
	char				   slotName[NAMEDATALEN];
	VamanaReplicationSlot *vslot;
	MemoryContext			oldCtx;

	SlotName(dboid, indexRelid, slotName);

	if (SearchNamedReplicationSlot(slotName, true) == NULL)
		return NULL;

	oldCtx = MemoryContextSwitchTo(TopMemoryContext);
	vslot = palloc0(sizeof(VamanaReplicationSlot));
	strlcpy(vslot->slotName, slotName, NAMEDATALEN);
	MemoryContextSwitchTo(oldCtx);

	ereport(DEBUG1,
			(errmsg("vamana: opened handle for replication slot \"%s\"", slotName)));

	return vslot;
}

/*
 * Advance confirmed_flush_lsn by briefly acquiring the slot.  A persistent
 * non-active slot can be acquired and released in a tight window.  Returns
 * false, advancing nothing, if the slot is busy or gone; the caller decides
 * whether that makes its own checkpoint incomplete.
 */
bool
VamanaSlotAdvance(VamanaReplicationSlot *slot, XLogRecPtr newLsn)
{
	if (slot == NULL)
		return true;

	if (!VamanaTryAcquireSlotNoWait(slot->slotName))
		return false;

	PG_TRY();
	{
		LogicalConfirmReceivedLocation(newLsn);
		ReplicationSlotRelease();
	}
	PG_CATCH();
	{
		if (MyReplicationSlot != NULL)
			ReplicationSlotRelease();
		PG_RE_THROW();
	}
	PG_END_TRY();

	return true;
}

/*
 * Free the handle.  Does not drop the underlying PG slot; the slot persists
 * until VamanaReplicationDropIfExists is called on DROP INDEX.
 */
void
VamanaReplicationClose(VamanaReplicationSlot *slot)
{
	if (slot == NULL)
		return;

	pfree(slot);
}

void
VamanaReplicationDropIfExists(Oid dboid, Oid indexRelid)
{
	char slotName[NAMEDATALEN];

	SlotName(dboid, indexRelid, slotName);
	DropSlotIfInactive(slotName);
}
