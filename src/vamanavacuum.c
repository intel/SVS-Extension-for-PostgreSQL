/*
 * vamanavacuum.c
 *
 * Vacuum and cleanup operations for Vamana index.
 * All SVS mutations are routed through the background worker.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/genam.h"
#include "commands/vacuum.h"
#include "storage/bufmgr.h"
#include "utils/rel.h"

/*
 * vamanabulkdelete
 *
 * For each live TID in the index's tidMapping, ask the PG dead-tuple callback
 * whether it is dead.  Collect dead external IDs and submit BGW DELETE
 * requests in batches of VAMANA_MAX_DELETE_IDS.
 *
 * Warm-cache path: uses the backend's in-memory TID map directly.
 *
 * Cold-cache path (e.g. autovacuum): reads tidMappingCapacity from the
 * metapage, then loads the TID map from the on-disk tidmap.bin file.  If the
 * file does not yet exist, vacuum is skipped with a LOG (nothing to delete).
 */
IndexBulkDeleteResult *
vamanabulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
				 IndexBulkDeleteCallback callback, void *callback_state)
{
	Relation	index = info->index;
	Oid			relid = RelationGetRelid(index);
	VamanaIndexCache *cache;
	ItemPointerData *tidMapping = NULL;
	int			tidMappingCapacity = 0;
	bool		usingTempMap = false;
	size_t	   *deadIds = NULL;
	int			numDead = 0;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	if (!VamanaWorkerIsAvailable())
	{
		ereport(WARNING,
				(errmsg("vamana index %u: vacuum skipped -- background worker unavailable",
						relid),
				 errhint("Set vamana.worker_enabled = on and restart PostgreSQL.")));
		return stats;
	}

	cache = VamanaGetCache(relid);

	if (cache != NULL && cache->isValid && cache->svsIndex != NULL)
	{
		/* Warm cache: use the backend's in-memory TID map. */
		tidMapping = cache->tidMapping;
		tidMappingCapacity = cache->tidMappingCapacity;
	}
	else
	{
		/* Cold cache: load TID map from disk. */
		VamanaMetaPageData meta;

		VamanaReadMetaPage(index, &meta);
		tidMappingCapacity = (int) meta.tidMappingCapacity;

		if (tidMappingCapacity <= 0)
		{
			ereport(LOG,
					(errmsg("vamana index %u: vacuum skipped -- metapage reports zero TID map capacity",
							relid)));
			return stats;
		}

		tidMapping = palloc0((Size) tidMappingCapacity * sizeof(ItemPointerData));
		usingTempMap = true;

		if (!VamanaLoadTidMap(relid, tidMapping, tidMappingCapacity))
		{
			pfree(tidMapping);
			ereport(LOG,
					(errmsg("vamana index %u: vacuum skipped -- on-disk TID map not available",
							relid)));
			return stats;
		}
	}

	/* Enumerate dead TIDs. */
	deadIds = palloc((Size) tidMappingCapacity * sizeof(size_t));

	for (int i = 0; i < tidMappingCapacity; i++)
	{
		ItemPointerData *tip = &tidMapping[i];

		if (!ItemPointerIsValid(tip))
			continue;

		if (callback(tip, callback_state))
		{
			deadIds[numDead++] = (size_t) i;
			ItemPointerSetInvalid(tip);
		}
	}

	if (numDead > 0)
	{
		int			submitted = 0;

		while (submitted < numDead)
		{
			int			batch = numDead - submitted;

			if (batch > (int) VAMANA_MAX_DELETE_IDS)
				batch = (int) VAMANA_MAX_DELETE_IDS;

			if (!VamanaWorkerSubmitDelete(relid, deadIds + submitted, batch))
			{
				ereport(WARNING,
						(errmsg("vamana index %u: BGW delete failed during vacuum (batch at offset %d)",
								relid, submitted)));
				break;
			}
			submitted += batch;
		}
	}

	pfree(deadIds);
	if (usingTempMap)
		pfree(tidMapping);

	stats->tuples_removed = (double) numDead;
	if (cache != NULL && cache->isValid)
		stats->num_index_tuples = (double) (cache->numVectors > numDead ?
											cache->numVectors - numDead : 0);
	else
	{
		VamanaMetaPageData meta;

		VamanaReadMetaPage(index, &meta);
		stats->num_index_tuples = (double) (meta.numVectors > (uint32) numDead ?
											meta.numVectors - (uint32) numDead : 0);
	}

	return stats;
}

/*
 * vamanavacuumcleanup
 *
 * After bulk-delete: run CONSOLIDATE (always) and optionally COMPACT via the
 * BGW.  The threshold check is performed locally using the cache counters;
 * only the actual SVS calls go through the worker.
 *
 * Cold-cache path: reads numDeleted and numVectors from the metapage so that
 * autovacuum (which never queries the index) still triggers maintenance when
 * deletes are pending.
 */
IndexBulkDeleteResult *
vamanavacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	Relation	index = info->index;
	Oid			relid = RelationGetRelid(index);
	VamanaIndexCache *cache;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	stats->num_pages = RelationGetNumberOfBlocks(index);

	if (VamanaWorkerIsAvailable())
	{
		cache = VamanaGetCache(relid);

		if (cache != NULL && cache->isValid && cache->svsIndex != NULL)
		{
			/* Warm cache: use in-memory counters. */
			if (cache->numDeleted > 0)
			{
				if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_CONSOLIDATE))
					ereport(WARNING,
							(errmsg("vamana index %u: BGW consolidate failed during vacuum cleanup",
									relid)));

				if (cache->numVectors > 0 &&
					vamana_compact_threshold_pct < 100 &&
					cache->numDeleted * 100 > cache->numVectors * vamana_compact_threshold_pct)
				{
					if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_COMPACT))
						ereport(WARNING,
								(errmsg("vamana index %u: BGW compact failed during vacuum cleanup",
										relid)));
				}
			}
		}
		else
		{
			/* Cold cache: read counters from metapage. */
			VamanaMetaPageData meta;

			VamanaReadMetaPage(index, &meta);

			if (meta.numDeleted > 0)
			{
				if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_CONSOLIDATE))
					ereport(WARNING,
							(errmsg("vamana index %u: BGW consolidate failed during vacuum cleanup",
									relid)));

				if (meta.numVectors > 0 &&
					vamana_compact_threshold_pct < 100 &&
					meta.numDeleted * 100 > meta.numVectors * (uint32) vamana_compact_threshold_pct)
				{
					if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_COMPACT))
						ereport(WARNING,
								(errmsg("vamana index %u: BGW compact failed during vacuum cleanup",
										relid)));
				}
			}
		}
	}

	/*
	 * Safety net for direct mode (worker off): if a freshly rebuilt index was
	 * never saved to disk (vamanaendscan's deferred save failed), persist it
	 * now.  needsSave lives in the per-process cache, so this only fires when
	 * INSERT, SELECT, and VACUUM share the same backend.
	 */
	if (!VamanaWorkerIsAvailable() && VamanaCacheGetNeedsSave(relid))
	{
		cache = VamanaGetCache(relid);

		if (cache != NULL && cache->svsIndex != NULL)
		{
			PG_TRY();
			{
				VamanaSaveIndexToDisk(index, cache->svsIndex, MAIN_FORKNUM);
			}
			PG_CATCH();
			{
				FlushErrorState();
				ereport(WARNING,
						(errmsg("vamana index %u: vacuum save to disk failed",
								relid)));
			}
			PG_END_TRY();
		}
	}

	return stats;
}
