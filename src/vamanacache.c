/*
 * vamanacache.c
 *
 * Per-process in-memory index cache for Vamana indexes, and the
 * object-access hook that evicts cache entries on DROP.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "catalog/objectaccess.h"
#include "catalog/pg_class_d.h"
#include "miscadmin.h"
#include "utils/memutils.h"

/*
 * In-Memory Index Cache Management
 *
 * Per-process cache: up to VAMANA_MAX_CACHED_INDEXES SVS index handles
 * (background worker only).
 *
 * Eviction policy: FIFO by insertion order.  When all slots are full and a
 * new index arrives, the oldest slot (vamanaCacheNext % max) is evicted.
 */

/* Array of per-process cache entries */
static VamanaIndexCache *vamanaCacheSlots[VAMANA_MAX_CACHED_INDEXES];
static int	vamanaCacheUsed = 0;	/* how many slots are allocated */
static int	vamanaCacheNext = 0;	/* next slot to evict (FIFO) */

/*
 * Free resources held by a cache entry and mark it invalid.
 */
static void
VamanaClearCacheEntry(VamanaIndexCache *entry)
{
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
			VamanaClearCacheEntry(entry);
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
		ereport(DEBUG1,
				(errmsg("vamana cache: evicting index %u to make room for %u",
						entry->indexRelid, indexRelid)));
	VamanaClearCacheEntry(entry);
	return entry;
}

/*
 * Cache the in-memory SVS index in the background worker's per-process cache.
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
		VamanaClearCacheEntry(entry);
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

		VamanaClearCacheEntry(entry);
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

	VamanaClearCacheEntry(entry);
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
