/*
 * vamanautils.c
 *
 * Utility functions for Vamana index.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"

#include "access/amapi.h"
#include "access/generic_xlog.h"
#include "access/heapam.h"
#include "access/relscan.h"
#include "access/reloptions.h"
#include "access/tableam.h"
#include "catalog/pg_type_d.h"
#include "commands/progress.h"
#include "miscadmin.h"
#include "port.h"
#include "storage/bufmgr.h"
#include "storage/bufpage.h"
#include "storage/fd.h"
#include "storage/lock.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_class_d.h"
#include "utils/array.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/rel.h"
#include "utils/selfuncs.h"
#include "utils/snapmgr.h"

#include <sys/stat.h>

/*
 * Advisory lock key used to serialize concurrent saves of the same index.
 * Uses the int4-pair advisory lock namespace (field4 = 2) with MyDatabaseId
 * scoping.  The high-order field is the index relid; the low-order field is
 * this magic constant to avoid colliding with application advisory locks on
 * the same integer value.
 */
#define VAMANA_SAVE_LOCK_KEY	((uint32) 0x56414D41U)	/* 'VAMA' */

/*
 * Get type-specific information
 */
const		VamanaTypeInfo *
VamanaGetTypeInfo(Relation index)
{
	static const VamanaTypeInfo vector_info = {
		.maxDimensions = VAMANA_MAX_DIM
	};

	return &vector_info;
}

/*
 * Initialize support functions for the index
 */
void
VamanaInitSupport(VamanaSupport * support, Relation index)
{
	FmgrInfo   *procinfo;

	procinfo = index_getprocinfo(index, 1, VAMANA_DISTANCE_PROC);
	support->procinfo = procinfo;

	support->collation = index->rd_indcollation[0];

	support->normprocinfo = VamanaOptionalProcInfo(index, VAMANA_NORM_PROC);
}

/*
 * Get optional support function
 */
FmgrInfo *
VamanaOptionalProcInfo(Relation index, uint16 procnum)
{
	if (!OidIsValid(index_getprocid(index, 1, procnum)))
		return NULL;

	return index_getprocinfo(index, 1, procnum);
}

/*
 * Allocate a new buffer for the index
 */
Buffer
VamanaNewBuffer(Relation index, ForkNumber forkNum)
{
	Buffer		buf = ReadBufferExtended(index, forkNum, P_NEW, RBM_NORMAL, NULL);

	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);

	return buf;
}

/*
 * Initialize a new page
 */
void
VamanaInitPage(Buffer buf, Page page)
{
	PageInit(page, BufferGetPageSize(buf), sizeof(VamanaPageOpaqueData));
	VamanaPageGetOpaque(page)->nextblkno = InvalidBlockNumber;
	VamanaPageGetOpaque(page)->page_id = VAMANA_PAGE_ID;
}

/*
 * Update the metapage with index information
 */
void
VamanaUpdateMetaPage(Relation index, BlockNumber indexDataBlkno,
					 Size indexDataSize, uint32 numVectors, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->indexDataBlkno = indexDataBlkno;
	metap->indexDataSize = indexDataSize;
	metap->numVectors = numVectors;

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Get metapage information
 */
void
VamanaGetMetaPageInfo(Relation index, int *graph_degree, int *dimensions)
{
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = ReadBuffer(index, VAMANA_METAPAGE_BLKNO);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	metap = VamanaPageGetMeta(page);

	if (graph_degree)
		*graph_degree = metap->graph_degree;
	if (dimensions)
		*dimensions = metap->dimensions;

	UnlockReleaseBuffer(buf);
}

/*
 * Build reloptions for Vamana index
 */
extern relopt_kind vamana_relopt_kind;

bytea *
vamanaoptions(Datum reloptions, bool validate)
{
	static const relopt_parse_elt tab[] = {
		{"graph_degree", RELOPT_TYPE_INT, offsetof(VamanaOptions, graph_degree)},
		{"alpha", RELOPT_TYPE_INT, offsetof(VamanaOptions, alpha)},
		{"build_window_size", RELOPT_TYPE_INT, offsetof(VamanaOptions, build_window_size)},
		{"search_window_size", RELOPT_TYPE_INT, offsetof(VamanaOptions, search_window_size)},
		{"use_search_history", RELOPT_TYPE_BOOL, offsetof(VamanaOptions, use_search_history)},
		{"compression_type", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_type)},
		{"compression_primary", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_primary)},
		{"compression_secondary", RELOPT_TYPE_INT, offsetof(VamanaOptions, compression_secondary)},
		{"leanvec_dims", RELOPT_TYPE_INT, offsetof(VamanaOptions, leanvec_dims)}
	};

	return (bytea *) build_reloptions(reloptions, validate,
									  vamana_relopt_kind,
									  sizeof(VamanaOptions),
									  tab, lengthof(tab));
}

void
vamanacostestimate(PlannerInfo *root, IndexPath *path, double loop_count,
				   Cost *indexStartupCost, Cost *indexTotalCost,
				   Selectivity *indexSelectivity, double *indexCorrelation,
				   double *indexPages)
{
	GenericCosts costs;

	MemSet(&costs, 0, sizeof(costs));
	genericcostestimate(root, path, loop_count, &costs);

	/* Scale down generic cost estimate to reflect ANN index characteristics */
	costs.indexTotalCost *= VAMANA_COST_SCALING_FACTOR;

	*indexStartupCost = costs.indexStartupCost;
	*indexTotalCost = costs.indexTotalCost;
	*indexSelectivity = costs.indexSelectivity;
	*indexCorrelation = costs.indexCorrelation;
	*indexPages = costs.numIndexPages;
}

/*
 * Get readable name for build phase
 */
char *
vamanabuildphasename(int64 phaseNum)
{
	switch (phaseNum)
	{
		case PROGRESS_CREATEIDX_SUBPHASE_INITIALIZE:
			return "initializing";
		case PROGRESS_VAMANA_PHASE_LOAD:
			return "loading tuples";
		default:
			return NULL;
	}
}

/*
 * Validate index definition
 */
bool
vamanavalidate(Oid opclassoid)
{
	return true;
}

/*
 * Distance metric helper
 */

/*
 * Determine the SVS distance metric from the index's operator class.
 * Inspects support function names to distinguish L2 / cosine / inner-product.
 */
SVSDistanceType
VamanaGetDistanceMetric(Relation index)
{
	Oid			opfamilyoid;
	Oid			inputTypeOid;
	Oid			distanceFuncOid;
	char	   *funcName;

	opfamilyoid = index->rd_opfamily[0];
	inputTypeOid = index->rd_opcintype[0];

	distanceFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid, inputTypeOid,
										VAMANA_DISTANCE_PROC);
	if (!OidIsValid(distanceFuncOid))
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("no distance function found for vamana index"),
				 errhint("Ensure you are using vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));

	funcName = get_func_name(distanceFuncOid);
	if (funcName == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("could not determine distance function name")));

	if (strcmp(funcName, "vector_l2_squared_distance") == 0 ||
		strcmp(funcName, "halfvec_l2_squared_distance") == 0)
	{
		pfree(funcName);
		return SVS_DISTANCE_L2;
	}

	if (strcmp(funcName, "vector_negative_inner_product") == 0 ||
		strcmp(funcName, "halfvec_negative_inner_product") == 0)
	{
		/*
		 * Inner-product op class doubles as cosine when a norm function is
		 * registered (support function 2).
		 */
		Oid			normFuncOid = get_opfamily_proc(opfamilyoid, inputTypeOid,
													inputTypeOid,
													VAMANA_NORM_PROC);
		SVSDistanceType result;

		result = OidIsValid(normFuncOid) ? SVS_DISTANCE_COSINE : SVS_DISTANCE_IP;
		pfree(funcName);
		return result;
	}

	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("unsupported distance function for vamana index: %s", funcName),
			 errhint("Use vector_l2_ops, vector_ip_ops, or vector_cosine_ops")));
	return SVS_DISTANCE_L2;		/* unreachable */
}

/*
 * On-disk serialization helpers
 */

/*
 * Construct the save-directory path for a vamana index.
 * Convention: $PGDATA/vamana_indexes/<relid>/
 */
void
VamanaGetIndexSavePath(Oid relid, char *buf, size_t bufsz)
{
	snprintf(buf, bufsz, "%s/vamana_indexes/%u", DataDir, relid);
}

/*
 * Create the directory hierarchy needed to save an index.
 * Creates $PGDATA/vamana_indexes/ and $PGDATA/vamana_indexes/<relid>/.
 */
void
VamanaEnsureSaveDir(Oid relid)
{
	char		parentdir[MAXPGPATH];
	char		indexdir[MAXPGPATH];

	snprintf(parentdir, sizeof(parentdir), "%s/vamana_indexes", DataDir);
	if (MakePGDirectory(parentdir) != 0 && errno != EEXIST)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create directory \"%s\": %m", parentdir)));

	VamanaGetIndexSavePath(relid, indexdir, sizeof(indexdir));
	if (MakePGDirectory(indexdir) != 0 && errno != EEXIST)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create directory \"%s\": %m", indexdir)));
}

/*
 * Remove the on-disk save directory for a vamana index, if it exists.
 * Silently returns if the directory does not exist.
 */
void
VamanaDeleteSaveDir(Oid relid)
{
	char		indexdir[MAXPGPATH];
	struct stat st;

	VamanaGetIndexSavePath(relid, indexdir, sizeof(indexdir));

	if (stat(indexdir, &st) != 0)
		return;

	if (rmtree(indexdir, true) == false)
		ereport(WARNING,
				(errmsg("could not remove vamana index directory \"%s\"", indexdir)));
}

/*
 * Write the TID mapping for a vamana index to a sidecar file inside its
 * save directory.  Uses a write-to-tmp-then-rename pattern so a crash
 * mid-write does not leave a partial file that looks valid.
 *
 * Ereports ERROR on I/O failure; caller's PG_TRY handles cleanup of the
 * entire save directory.
 */
void
VamanaSaveTidMapAtomically(Oid relid, ItemPointerData *tidMapping, int count)
{
	char		tidmappath[MAXPGPATH];
	char		tidmaptmp[MAXPGPATH];
	FILE	   *f;
	size_t		written;

	snprintf(tidmappath, sizeof(tidmappath),
			 "%s/vamana_indexes/%u/tidmap.bin", DataDir, relid);
	snprintf(tidmaptmp, sizeof(tidmaptmp),
			 "%s/vamana_indexes/%u/tidmap.bin.tmp", DataDir, relid);

	f = AllocateFile(tidmaptmp, PG_BINARY_W);
	if (f == NULL)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not create TID map file \"%s\": %m", tidmaptmp)));

	written = fwrite(tidMapping, sizeof(ItemPointerData), count, f);
	if ((int) written != count)
	{
		FreeFile(f);
		unlink(tidmaptmp);
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not write TID map to \"%s\": %m", tidmaptmp)));
	}

	if (FreeFile(f) != 0)
	{
		unlink(tidmaptmp);
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not flush TID map file \"%s\": %m", tidmaptmp)));
	}

	if (rename(tidmaptmp, tidmappath) != 0)
		ereport(ERROR,
				(errcode_for_file_access(),
				 errmsg("could not rename TID map \"%s\" to \"%s\": %m",
						tidmaptmp, tidmappath)));
}

/*
 * Read back the sidecar TID-mapping file for a vamana index.
 *
 * tidMappingCapacity is the number of slots to read (>= numVectors; includes
 * holes for soft-deleted entries).
 *
 * Returns true and fills tidMapping[0..tidMappingCapacity-1] on success.
 * Returns false (triggering caller to rebuild) if the file is absent or
 * has an unexpected size.
 *
 * tidMapping must be pre-allocated with at least tidMappingCapacity elements.
 */
bool
VamanaLoadTidMap(Oid relid, ItemPointerData *tidMapping, int tidMappingCapacity)
{
	char		tidmappath[MAXPGPATH];
	FILE	   *f;
	size_t		nread;

	snprintf(tidmappath, sizeof(tidmappath),
			 "%s/vamana_indexes/%u/tidmap.bin", DataDir, relid);

	f = AllocateFile(tidmappath, PG_BINARY_R);
	if (f == NULL)
	{
		if (errno == ENOENT)
			return false;		/* normal "no saved file" signal */
		ereport(WARNING,
				(errcode_for_file_access(),
				 errmsg("could not open TID map \"%s\": %m", tidmappath)));
		return false;
	}

	nread = fread(tidMapping, sizeof(ItemPointerData), tidMappingCapacity, f);
	FreeFile(f);

	if ((int) nread != tidMappingCapacity)
	{
		ereport(WARNING,
				(errmsg("vamana index %u: TID map \"%s\" has wrong size "
						"(expected %d entries), will rebuild",
						relid, tidmappath, tidMappingCapacity)));
		return false;
	}

	return true;
}

/*
 * Read the full metapage into a caller-supplied struct.
 */
void
VamanaReadMetaPage(Relation index, VamanaMetaPageData * meta)
{
	Buffer		buf;
	Page		page;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, MAIN_FORKNUM, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_SHARE);
	page = BufferGetPage(buf);
	metap = VamanaPageGetMeta(page);
	memcpy(meta, metap, sizeof(VamanaMetaPageData));
	UnlockReleaseBuffer(buf);
}

/*
 * Update only the hasSavedIndex flag on the metapage.
 */
void
VamanaSetHasSavedIndex(Relation index, bool hasSavedIndex, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);
	metap->hasSavedIndex = hasSavedIndex;
	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Atomically record that a valid on-disk copy exists by writing hasSavedIndex,
 * indexDataBlkno, indexDataSize, numVectors, and dynamic fields in a single
 * GenericXLog transaction.
 */
static void
VamanaMarkIndexSaved(Relation index, uint32 numVectors, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;
	Oid			relid = RelationGetRelid(index);
	VamanaIndexCache *cache = VamanaGetCache(relid);

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->hasSavedIndex = true;
	metap->indexDataBlkno = VAMANA_HEAD_BLKNO;
	metap->indexDataSize = 0;
	metap->numVectors = numVectors;

	/* Persist dynamic fields from cache if available */
	if (cache != NULL)
	{
		metap->nextExternalId = cache->nextExternalId;
		metap->numDeleted = (uint32) cache->numDeleted;
		metap->tidMappingCapacity = (uint32) cache->tidMappingCapacity;
	}

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * Save the SVS index for <index> to $PGDATA/vamana_indexes/<oid>/ and update
 * the metapage hasSavedIndex flag.  numVectors is taken from the cache so
 * callers do not need to pass it separately.
 *
 * Best-effort: a save failure emits a WARNING but does not abort the caller.
 * The index remains usable in memory; the next cache miss will attempt a
 * rebuild + re-save.
 */
void
VamanaSaveIndexToDisk(Relation index, SVSIndexHandle svsIndex, ForkNumber forkNum)
{
	char		savepath[MAXPGPATH];
	Oid			relid = RelationGetRelid(index);
	VamanaIndexCache *cache = VamanaGetCache(relid);
	int			numVectors = cache ? cache->numVectors : 0;
	int			tidMappingCapacity = cache ? cache->tidMappingCapacity : numVectors;
	LOCKTAG		locktag;
	LockAcquireResult lockresult;

	/* Temporary indexes are session-private; never serialize them. */
	if (index->rd_rel->relpersistence == RELPERSISTENCE_TEMP)
		return;

	/*
	 * Acquire a non-blocking transaction-scoped advisory lock before writing
	 * to the save directory.  Two backends can race here when they both miss
	 * the cache at the same time (e.g. right after an INSERT invalidates it).
	 * If we cannot get the lock, skip the save: the winner will complete it
	 * and the loser's in-memory index is still usable.
	 */
	SET_LOCKTAG_ADVISORY(locktag, MyDatabaseId,
						 (uint32) relid,
						 (uint32) VAMANA_SAVE_LOCK_KEY,
						 2);
	lockresult = LockAcquire(&locktag, ExclusiveLock,
							 false, /* sessionLock: release at xact end */
							 true); /* dontWait: skip if unavailable */
	if (lockresult == LOCKACQUIRE_NOT_AVAIL)
	{
		ereport(DEBUG1,
				(errmsg("vamana index %u: save skipped, another backend is already saving",
						relid)));
		return;
	}

	PG_TRY();
	{
		VamanaEnsureSaveDir(relid);
		VamanaGetIndexSavePath(relid, savepath, sizeof(savepath));

		ereport(DEBUG1,
				(errmsg("saving vamana index for relation %u to \"%s\"", relid, savepath)));

		SVSSaveIndex(svsIndex, savepath);

		/*
		 * Write the TID mapping sidecar file atomically (temp + rename) so
		 * index restores can recover build-time TIDs without re-scanning the
		 * heap.  Preserving build-time order is essential: a heap re-scan
		 * after VACUUM may visit tuples in a different physical order and
		 * would silently map SVS internal IDs to wrong TIDs.
		 *
		 * If this ereports ERROR it is caught by the PG_CATCH below, which
		 * removes the entire save directory (including any partial tmp file).
		 */
		if (cache != NULL && cache->tidMapping != NULL && tidMappingCapacity > 0)
			VamanaSaveTidMapAtomically(relid, cache->tidMapping, tidMappingCapacity);
	}
	PG_CATCH();
	{
		FlushErrorState();
		/* Remove any partial files so the next save attempt starts clean */
		VamanaDeleteSaveDir(relid);
		ereport(WARNING,
				(errmsg("vamana index %u: could not save to disk, index will be rebuilt on next cold start",
						relid)));
		return;
	}
	PG_END_TRY();

	/*
	 * Record that a valid on-disk copy now exists (single atomic WAL record).
	 *
	 * Note on transactional semantics: the disk files written by SVSSaveIndex
	 * above are outside PostgreSQL's transaction system: they are not rolled
	 * back if the surrounding transaction aborts. VamanaMarkIndexSaved uses
	 * GenericXLogFinish which is also not transactional in the usual sense;
	 * however it only reaches here after SVSSaveIndex succeeded, so the files
	 * and the flag are always in sync. If the transaction aborts after this
	 * point, the flag remains set and the files are valid: no harm done. If
	 * the server crashes after SVSSaveIndex but before VamanaMarkIndexSaved,
	 * the partial directory persists until the index is dropped
	 * (VamanaObjectAccessHook cleans it up) or until the next save attempt,
	 * which will overwrite the stale files.
	 */
	VamanaMarkIndexSaved(index, numVectors, forkNum);	/* also saves
														 * tidMappingCapacity */

	/* Clear deferred-save flag. */
	VamanaCacheSetNeedsSave(relid, false);

	ereport(DEBUG1,
			(errmsg("vamana index for relation %u saved (%d vectors)", relid, numVectors)));
}

/*
 * Write dynamic index fields to the metapage under GenericXLog.
 * Called after a successful SVSAddPoints or SVSDeletePoints to persist
 * nextExternalId, numVectors, numDeleted, and tidMappingCapacity atomically.
 */
void
VamanaWriteMetaPageDynamic(Relation index, uint64 nextExternalId,
						   uint32 numVectors, uint32 numDeleted,
						   uint32 tidMappingCapacity, ForkNumber forkNum)
{
	Buffer		buf;
	Page		page;
	GenericXLogState *state;
	VamanaMetaPage metap;

	buf = ReadBufferExtended(index, forkNum, VAMANA_METAPAGE_BLKNO,
							 RBM_NORMAL, NULL);
	LockBuffer(buf, BUFFER_LOCK_EXCLUSIVE);
	state = GenericXLogStart(index);
	page = GenericXLogRegisterBuffer(state, buf, 0);
	metap = VamanaPageGetMeta(page);

	metap->nextExternalId = nextExternalId;
	metap->numVectors = numVectors;
	metap->numDeleted = numDeleted;
	metap->tidMappingCapacity = tidMappingCapacity;

	GenericXLogFinish(state);
	UnlockReleaseBuffer(buf);
}

/*
 * In-Memory Index Cache Management
 *
 * Per-process cache: up to VAMANA_MAX_CACHED_INDEXES SVS index handles.
 * Regular backends typically cache one index at a time; the background worker
 * may cache several (one per Vamana index in the database).
 *
 * Eviction policy: FIFO by insertion order.  When all slots are full and a
 * new index arrives, the oldest slot (vamanaCacheNext % max) is evicted.
 */

/* Array of per-process cache entries */
static VamanaIndexCache * vamanaCacheSlots[VAMANA_MAX_CACHED_INDEXES];
static int	vamanaCacheUsed = 0;	/* how many slots are allocated */
static int	vamanaCacheNext = 0;	/* next slot to evict (FIFO) */

/*
 * Find a cache slot by indexRelid.  Returns pointer to the slot, or NULL.
 */
static VamanaIndexCache *
VamanaFindCacheSlot(Oid indexRelid)
{
	for (int i = 0; i < vamanaCacheUsed; i++)
	{
		if (vamanaCacheSlots[i] != NULL &&
			vamanaCacheSlots[i]->isValid &&
			vamanaCacheSlots[i]->indexRelid == indexRelid)
			return vamanaCacheSlots[i];
	}
	return NULL;
}

/*
 * Allocate or evict a cache slot.  Returns a pointer to an empty (or
 * freshly cleared) VamanaIndexCache that the caller should fill.
 */
static VamanaIndexCache *
VamanaAllocCacheSlot(Oid indexRelid)
{
	int			slot;
	VamanaIndexCache *entry;
	MemoryContext oldCtx;

	/* Fast path: existing slot for this relid */
	for (int i = 0; i < vamanaCacheUsed; i++)
	{
		if (vamanaCacheSlots[i] != NULL &&
			vamanaCacheSlots[i]->indexRelid == indexRelid)
		{
			entry = vamanaCacheSlots[i];
			if (entry->isValid && entry->svsIndex)
			{
				SVSFreeIndex(entry->svsIndex);
				entry->svsIndex = NULL;
			}
			if (entry->tidMapping)
			{
				pfree(entry->tidMapping);
				entry->tidMapping = NULL;
			}
			entry->isValid = false;
			entry->needsSave = false;
			return entry;
		}
	}

	if (vamanaCacheUsed < VAMANA_MAX_CACHED_INDEXES)
	{
		slot = vamanaCacheUsed;
		oldCtx = MemoryContextSwitchTo(TopMemoryContext);
		entry = palloc0(sizeof(VamanaIndexCache));
		entry->memCtx = AllocSetContextCreate(TopMemoryContext,
											  "Vamana index cache",
											  ALLOCSET_DEFAULT_SIZES);
		MemoryContextSwitchTo(oldCtx);
		vamanaCacheSlots[slot] = entry;
		vamanaCacheUsed++;
		return entry;
	}

	/* Evict the oldest slot (FIFO) */
	slot = vamanaCacheNext % VAMANA_MAX_CACHED_INDEXES;
	vamanaCacheNext++;
	entry = vamanaCacheSlots[slot];

	if (entry->isValid && entry->svsIndex)
	{
		ereport(DEBUG1,
				(errmsg("vamana cache: evicting index %u to make room for %u",
						entry->indexRelid, indexRelid)));
		SVSFreeIndex(entry->svsIndex);
		entry->svsIndex = NULL;
	}
	if (entry->tidMapping)
	{
		pfree(entry->tidMapping);
		entry->tidMapping = NULL;
	}
	entry->isValid = false;
	entry->needsSave = false;
	return entry;
}

/*
 * Cache the in-memory SVS index for this backend.
 * tidMappingCapacity is the number of slots to allocate (>= numVectors).
 */
void
VamanaCacheIndex(Oid indexRelid, SVSIndexHandle svsIndex, int dimensions,
				 int graph_degree, float alpha, ItemPointerData *tidMapping,
				 int numVectors, int tidMappingCapacity,
				 uint64 nextExternalId, int numDeleted)
{
	VamanaIndexCache *entry;
	MemoryContext oldCtx;
	int			capacity = (tidMappingCapacity > numVectors) ? tidMappingCapacity : numVectors;

	entry = VamanaAllocCacheSlot(indexRelid);

	if (tidMapping != NULL && capacity > 0)
	{
		Size		tidMappingSize = (Size) capacity * sizeof(ItemPointerData);

		oldCtx = MemoryContextSwitchTo(TopMemoryContext);
		entry->tidMapping = palloc(tidMappingSize);
		memcpy(entry->tidMapping, tidMapping, tidMappingSize);
		MemoryContextSwitchTo(oldCtx);
	}
	else
		entry->tidMapping = NULL;

	/* Store index handle and metadata */
	entry->svsIndex = svsIndex;
	entry->indexRelid = indexRelid;
	entry->dimensions = dimensions;
	entry->graph_degree = graph_degree;
	entry->alpha = alpha;
	entry->numVectors = numVectors;
	entry->tidMappingCapacity = capacity;
	entry->nextExternalId = nextExternalId;
	entry->numDeleted = numDeleted;
	entry->isValid = true;

	ereport(DEBUG1,
			(errmsg("cached vamana index for relation %u (%d dimensions, degree %d)",
					indexRelid, dimensions, graph_degree)));
}

/*
 * Get cached SVS index, returns NULL if not cached or invalid.
 * Sets *needsRebuild = true if the index must be loaded/built.
 */
SVSIndexHandle
VamanaGetCachedIndex(Oid indexRelid, bool *needsRebuild)
{
	VamanaIndexCache *entry = VamanaFindCacheSlot(indexRelid);

	if (entry != NULL)
	{
		*needsRebuild = false;
		ereport(DEBUG2,
				(errmsg("using cached vamana index for relation %u", indexRelid)));
		return entry->svsIndex;
	}

	*needsRebuild = true;
	ereport(DEBUG1,
			(errmsg("vamana index for relation %u not in cache, rebuild required",
					indexRelid)));
	return NULL;
}

/*
 * Get the cache structure (for internal use by svs_wrapper.c).
 */
VamanaIndexCache *
VamanaGetCache(Oid indexRelid)
{
	return VamanaFindCacheSlot(indexRelid);
}

/*
 * Set or clear the deferred-save flag on a cached index.
 */
void
VamanaCacheSetNeedsSave(Oid indexRelid, bool flag)
{
	VamanaIndexCache *entry = VamanaFindCacheSlot(indexRelid);

	if (entry != NULL)
		entry->needsSave = flag;
}

/*
 * Check whether a cached index needs to be saved to disk.
 */
bool
VamanaCacheGetNeedsSave(Oid indexRelid)
{
	VamanaIndexCache *entry = VamanaFindCacheSlot(indexRelid);

	return (entry != NULL && entry->needsSave);
}

/*
 * Invalidate cached index (called on data modifications).
 */
void
VamanaInvalidateCache(Oid indexRelid)
{
	VamanaIndexCache *entry = VamanaFindCacheSlot(indexRelid);

	if (entry != NULL)
	{
		ereport(DEBUG1,
				(errmsg("invalidating cached vamana index for relation %u",
						indexRelid)));
		if (entry->svsIndex)
		{
			SVSFreeIndex(entry->svsIndex);
			entry->svsIndex = NULL;
		}
		if (entry->tidMapping)
		{
			pfree(entry->tidMapping);
			entry->tidMapping = NULL;
		}
		entry->isValid = false;
		entry->needsSave = false;
	}

	/*
	 * Remove the on-disk saved copy so the next cache-miss does not load
	 * stale data.  Best-effort: warn rather than error if the directory is
	 * already gone.
	 */
	VamanaDeleteSaveDir(indexRelid);

	/*
	 * Signal the BGW to evict its in-memory copy.  The save directory was
	 * deleted above, so the BGW will rebuild from the (now empty) table and
	 * cache a fresh entry.
	 */
	if (!AmBackgroundWorkerProcess() && VamanaWorkerIsAvailable())
		VamanaWorkerSignalReload(indexRelid);

	/*
	 * Note: clearing the metapage hasSavedIndex flag requires an open
	 * relation.  The flag will be corrected on the next LoadIndexFromPages
	 * call that discovers the directory is absent.
	 */
}

/*
 * VamanaEvictAllCacheEntries - evict every in-process cache entry.
 *
 * Called by the background worker when the reload queue overflows and it
 * needs to force a full reload.  Like VamanaEvictCacheEntry(), this does
 * NOT delete on-disk saved copies or signal the worker.
 */
void
VamanaEvictAllCacheEntries(void)
{
	for (int i = 0; i < vamanaCacheUsed; i++)
	{
		VamanaIndexCache *entry = vamanaCacheSlots[i];

		if (entry == NULL || !entry->isValid)
			continue;

		ereport(DEBUG1,
				(errmsg("evicting vamana cache entry for relation %u (full eviction)",
						entry->indexRelid)));

		if (entry->svsIndex)
		{
			SVSFreeIndex(entry->svsIndex);
			entry->svsIndex = NULL;
		}
		if (entry->tidMapping)
		{
			pfree(entry->tidMapping);
			entry->tidMapping = NULL;
		}
		entry->isValid = false;
		entry->needsSave = false;
	}
}

/*
 * VamanaEvictCacheEntry - worker-safe cache eviction.
 *
 * Frees the in-process SVS handle and TID mapping for the given index and
 * marks the slot invalid.  Unlike VamanaInvalidateCache(), this function does
 * NOT delete the on-disk saved copy (so the caller can still load from disk)
 * and does NOT signal the background worker (avoiding reload loops when called
 * from within the worker process itself).
 */
void
VamanaEvictCacheEntry(Oid indexRelid)
{
	VamanaIndexCache *entry = VamanaFindCacheSlot(indexRelid);

	if (entry == NULL)
		return;

	ereport(DEBUG1,
			(errmsg("evicting vamana cache entry for relation %u", indexRelid)));

	if (entry->svsIndex)
	{
		SVSFreeIndex(entry->svsIndex);
		entry->svsIndex = NULL;
	}
	if (entry->tidMapping)
	{
		pfree(entry->tidMapping);
		entry->tidMapping = NULL;
	}
	entry->isValid = false;
	entry->needsSave = false;
}

/* Previous hook in the chain (NULL if none installed before us) */
static object_access_hook_type prev_vamana_object_access_hook = NULL;

/*
 * Object-access hook: fires on every DDL object event.  We only act on
 * OAT_DROP for relations: this is the correct hook for DROP INDEX / DROP
 * TABLE, unlike a relcache callback which fires on every invalidation
 * (including CREATE INDEX) and would delete the directory prematurely.
 */
static void
VamanaObjectAccessHook(ObjectAccessType access, Oid classId, Oid objectId,
					   int subId, void *arg)
{
	/* Chain to any previously-installed hook */
	if (prev_vamana_object_access_hook)
		(*prev_vamana_object_access_hook) (access, classId, objectId, subId, arg);

	/* On relation drop, remove the corresponding vamana save directory. */
	if (access == OAT_DROP && classId == RelationRelationId)
	{
		VamanaDeleteSaveDir(objectId);
		VamanaReleaseIndexLock(objectId);
	}
}

/*
 * Install the object-access hook.  Called once from VamanaInit().
 */
void
VamanaInstallObjectAccessHook(void)
{
	prev_vamana_object_access_hook = object_access_hook;
	object_access_hook = VamanaObjectAccessHook;
}

/*
 * Rebuild SVS index from table data
 * This is called when the index is not cached (e.g., after server restart)
 */
SVSIndexHandle
VamanaRebuildFromTable(Relation index)
{
	Relation	heap;
	TableScanDesc heapScan;
	HeapTuple	tuple;
	TupleDesc	tupdesc;
	SVSIndexHandle svsIndex;
	SVSAlgorithmHandle algorithm;
	SVSBuilderHandle builder;
	SVSStorageHandle storage;
	VamanaOptions *opts;
	int			dimensions;
	int			graph_degree;
	int			alpha;
	int			buildWindow;
	int			searchWindow;
	bool		useSearchHistory;
	SVSDistanceType distanceType;
	int			compression_type;
	int			compression_primary;
	int			compression_secondary;
	int			leanvec_dims;
	Snapshot	snapshot;
	float	  **vectorBuffer = NULL;
	ItemPointerData *tidMapping = NULL;
	int			numVectors = 0;
	int			bufferCapacity = VAMANA_INITIAL_BUFFER_CAPACITY;
	int			errorCode = 0;

	ereport(LOG,
			(errmsg("rebuilding vamana index from table data")));

	opts = (VamanaOptions *) index->rd_options;
	dimensions = TupleDescAttr(index->rd_att, 0)->atttypmod;
	graph_degree = opts ? opts->graph_degree : VAMANA_DEFAULT_GRAPH_DEGREE;
	alpha = opts ? opts->alpha : VAMANA_DEFAULT_ALPHA;
	buildWindow = (opts && opts->build_window_size > 0) ?
		opts->build_window_size : VAMANA_BUILD_WINDOW_FROM_DEGREE(graph_degree);
	searchWindow = opts ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW;
	useSearchHistory = opts ? opts->use_search_history : VAMANA_DEFAULT_USE_SEARCH_HISTORY;
	compression_type = opts ? opts->compression_type : VAMANA_DEFAULT_COMPRESSION_TYPE;
	compression_primary = opts ? opts->compression_primary : VAMANA_DEFAULT_LEANVEC_PRIMARY;
	compression_secondary = opts ? opts->compression_secondary : VAMANA_DEFAULT_LEANVEC_SECONDARY;
	leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	distanceType = VamanaGetDistanceMetric(index);

	vectorBuffer = palloc(bufferCapacity * sizeof(float *));
	tidMapping = palloc(bufferCapacity * sizeof(ItemPointerData));

	heap = table_open(index->rd_index->indrelid, AccessShareLock);
	tupdesc = RelationGetDescr(heap);

	/*
	 * Scan table to collect vectors - use an MVCC snapshot to exclude dead
	 * tuples
	 */
	snapshot = RegisterSnapshot(GetTransactionSnapshot());
	heapScan = table_beginscan(heap, snapshot, 0, NULL);

	while ((tuple = heap_getnext(heapScan, ForwardScanDirection)) != NULL)
	{
		Datum	   *values;
		bool	   *isnull;
		Vector	   *vec;
		int			natts = tupdesc->natts;
		int			vectorAttNum;

		values = (Datum *) palloc(natts * sizeof(Datum));
		isnull = (bool *) palloc(natts * sizeof(bool));

		heap_deform_tuple(tuple, tupdesc, values, isnull);

		/* Find which attribute is the indexed vector column */
		vectorAttNum = index->rd_index->indkey.values[0] - 1;	/* Attribute numbers are
																 * 1-based */

		if (!isnull[vectorAttNum])
		{
			if (numVectors >= bufferCapacity)
			{
				bufferCapacity *= 2;
				vectorBuffer = repalloc(vectorBuffer,
										bufferCapacity * sizeof(float *));
				tidMapping = repalloc(tidMapping,
									  bufferCapacity * sizeof(ItemPointerData));
			}

			/* Store heap TID for mapping */
			ItemPointerCopy(&tuple->t_self, &tidMapping[numVectors]);

			/*
			 * Extract vector using _COPY to avoid reading past page-buffer
			 * boundary.  PG_DETOAST_DATUM for untoasted vectors returns a
			 * pointer directly into the 8192-byte heap page; memcpy's
			 * internal 8-byte reads can overshoot the palloc block end.
			 */
			vec = (Vector *) PG_DETOAST_DATUM_COPY(values[vectorAttNum]);
			if (vec->dim != dimensions)
			{
				pfree(vec);
				pfree(values);
				pfree(isnull);
				ereport(ERROR,
						(errcode(ERRCODE_DATA_EXCEPTION),
						 errmsg("vector dimension mismatch: expected %d, got %d", dimensions, vec->dim)));
			}
			vectorBuffer[numVectors] = palloc(dimensions * sizeof(float));
			memcpy(vectorBuffer[numVectors], vec->x, dimensions * sizeof(float));
			pfree(vec);			/* free the _COPY allocation */
			numVectors++;

			/*
			 * Emit progress LOG at regular intervals to surface progress during
			 * long-running rebuilds.
			 */
			if (numVectors % VAMANA_PROGRESS_INTERVAL == 0)
				ereport(LOG,
						(errmsg("vamana index %u: scanning table, %d vectors collected",
								RelationGetRelid(index), numVectors)));
		}

		pfree(values);
		pfree(isnull);

		CHECK_FOR_INTERRUPTS();
	}

	table_endscan(heapScan);
	UnregisterSnapshot(snapshot);
	table_close(heap, AccessShareLock);

	if (numVectors == 0)
	{
		ereport(WARNING,
				(errmsg("no vectors found in table for index rebuild")));
		pfree(tidMapping);
		pfree(vectorBuffer);
		return NULL;
	}

	ereport(NOTICE,
			(errmsg("collected %d vectors, building SVS index...", numVectors)));

	if (compression_type == VAMANA_COMPRESSION_LEANVEC &&
		numVectors < 100000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LeanVec index with only %d vectors; "
						"recall may be poor (recommend >= 100000, minimum 10000)",
						numVectors)));
	}
	else if (compression_type == VAMANA_COMPRESSION_LVQ &&
			 numVectors < 10000)
	{
		ereport(WARNING,
				(errmsg("rebuilding LVQ index with only %d vectors; "
						"recall may be poor (recommend >= 10000)",
						numVectors)));
	}

	/* Flatten vector data for SVS */
	Size		dataSize = (Size) numVectors * dimensions * sizeof(float);
	float	   *flatData = MemoryContextAllocHuge(CurrentMemoryContext, dataSize);

	for (int i = 0; i < numVectors; i++)
	{
		memcpy(flatData + (i * dimensions),
			   vectorBuffer[i],
			   dimensions * sizeof(float));
	}

	algorithm = SVSCreateAlgorithm(graph_degree, buildWindow, searchWindow, alpha, useSearchHistory);

	if (compression_type == VAMANA_COMPRESSION_LEANVEC)
		storage = SVSCreateLeanVecStorage(dimensions, leanvec_dims,
										  compression_primary, compression_secondary);
	else
		storage = SVSCreateSimpleStorage(SVS_DTYPE_FLOAT32);

	builder = SVSCreateBuilder(distanceType, dimensions, algorithm);
	SVSBuilderSetStorage(builder, storage);
	SVSBuilderSetThreadpool(builder, SVSDefaultBuildThreads());

	/* Generate sequential external IDs: ids[i] = i */
	{
		size_t	   *ids = palloc((size_t) numVectors * sizeof(size_t));

		for (int i = 0; i < numVectors; i++)
			ids[i] = (size_t) i;

		svsIndex = SVSBuildDynamicIndex(builder, flatData, ids, numVectors, &errorCode);
		pfree(ids);
	}

	if (svsIndex == NULL || errorCode != 0)
	{
		SVSFreeBuilder(builder);
		SVSFreeStorage(storage);
		SVSFreeAlgorithm(algorithm);

		for (int i = 0; i < numVectors; i++)
			pfree(vectorBuffer[i]);
		pfree(vectorBuffer);
		pfree(flatData);

		ereport(ERROR,
				(errcode(ERRCODE_INTERNAL_ERROR),
				 errmsg("failed to rebuild vamana index from table"),
				 errdetail("SVS build failed with error code %d", errorCode)));
	}

	/* Cleanup vector buffers and flatData (but keep tidMapping for cache) */
	SVSFreeBuilder(builder);
	SVSFreeStorage(storage);
	SVSFreeAlgorithm(algorithm);

	for (int i = 0; i < numVectors; i++)
		pfree(vectorBuffer[i]);
	pfree(vectorBuffer);
	pfree(flatData);

	ereport(NOTICE,
			(errmsg("successfully rebuilt vamana index with %d vectors", numVectors)));

	/* Cache the rebuilt index with TID mapping and dynamic fields */
	VamanaCacheIndex(RelationGetRelid(index), svsIndex, dimensions,
					 graph_degree, VAMANA_ALPHA_TO_FLOAT(alpha), tidMapping, numVectors,
					 numVectors,	/* tidMappingCapacity (fresh rebuild, no
									 * holes) */
					 (uint64) numVectors,	/* nextExternalId */
					 0);		/* numDeleted */

	return svsIndex;
}
