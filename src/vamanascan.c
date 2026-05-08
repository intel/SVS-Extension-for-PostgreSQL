/*
 * vamanascan.c
 *
 * Query execution for Vamana index using SVS library.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"
#include "svs_wrapper.h"

#include "access/relscan.h"
#include "pgstat.h"
#include "utils/memutils.h"
#include "utils/rel.h"

#include <sys/stat.h>

/*
 * Load SVS index from a previously saved on-disk directory.
 *
 * Reads the metapage to check hasSavedIndex and reconstruct SVSBuildConfig,
 * then calls SVSLoadDynamicIndex.  Returns the loaded handle on success or NULL:
 *  - if no saved file exists (hasSavedIndex == false, or directory absent)
 *  - if loading fails (logs a WARNING and returns NULL so caller can fall back)
 *
 * On success the index is registered in the backend cache via VamanaCacheIndex.
 */
SVSIndexHandle
LoadIndexFromPages(Relation index)
{
	VamanaMetaPageData meta;
	SVSBuildConfig config;
	SVSIndexHandle svsIndex;
	char		savepath[MAXPGPATH];
	Oid			relid = RelationGetRelid(index);
	VamanaOptions *opts;
	ItemPointerData *tidMapping = NULL;
	struct stat st;
	uint32		tidMappingCapacity;
	uint64		nextExternalId;
	uint32		numDeleted;

	VamanaReadMetaPage(index, &meta);

	if (!meta.hasSavedIndex)
	{
		ereport(DEBUG1,
				(errmsg("vamana index %u: no saved copy on disk, will rebuild", relid)));
		return NULL;
	}

	VamanaGetIndexSavePath(relid, savepath, sizeof(savepath));

	/*
	 * hasSavedIndex may be stale if VamanaInvalidateCache deleted the
	 * directory but could not update the metapage flag (no open relation).
	 * Verify the directory actually exists before attempting a load.
	 */
	if (stat(savepath, &st) != 0 || !S_ISDIR(st.st_mode))
	{
		/*
		 * Clear stale flag so future reads skip the check.  Two backends
		 * could both observe hasSavedIndex=true, both find the directory
		 * absent, and both call VamanaSetHasSavedIndex(false).  The double
		 * write is idempotent and harmless. MAIN_FORKNUM is safe here: temp
		 * relations are never serialized to vamana_indexes/, so this recovery
		 * path is unreachable for temp indexes.
		 */
		VamanaSetHasSavedIndex(index, false, MAIN_FORKNUM);
		ereport(DEBUG1,
				(errmsg("vamana index %u: saved directory absent, will rebuild", relid)));
		return NULL;
	}

	tidMappingCapacity = meta.tidMappingCapacity;
	nextExternalId = meta.nextExternalId;
	numDeleted = meta.numDeleted;

	/* Reconstruct SVSBuildConfig from metapage + index options */
	opts = (VamanaOptions *) index->rd_options;
	config.graph_degree = meta.graph_degree;
	config.alpha = meta.alpha;
	config.search_window_size = opts ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW;
	config.build_window_size = (opts && opts->build_window_size > 0) ?
		opts->build_window_size : 0;
	config.compression_type = meta.compression_type;
	config.compression_primary = meta.compression_primary;
	config.compression_secondary = meta.compression_secondary;
	config.distance_type = VamanaGetDistanceMetric(index);
	config.data_type = SVS_DTYPE_FLOAT32;
	config.dimensions = (int) meta.dimensions;
	config.leanvec_dims = opts ? opts->leanvec_dims : VAMANA_DEFAULT_LEANVEC_DIMS;

	ereport(LOG,
			(errmsg("loading vamana index %u from \"%s\"",
					relid, savepath)));

	/*
	 * Attempt the load.  Wrap in PG_TRY to convert a load failure into a
	 * WARNING + NULL return so the caller can fall back to rebuilding.
	 */
	PG_TRY();
	{
		svsIndex = SVSLoadDynamicIndex(savepath, &config);
	}
	PG_CATCH();
	{
		FlushErrorState();
		ereport(WARNING,
				(errmsg("vamana index %u: failed to load from \"%s\", will rebuild from table",
						relid, savepath)));

		VamanaDeleteSaveDir(relid);
		return NULL;
	}
	PG_END_TRY();

	if (svsIndex == NULL)
		return NULL;

	/*
	 * Restore the TID mapping from the sidecar file written at save time. The
	 * capacity includes holes for soft-deleted entries.
	 */
	if (tidMappingCapacity > 0)
	{
		tidMapping = (ItemPointerData *) palloc(
												(Size) tidMappingCapacity * sizeof(ItemPointerData));

		ereport(LOG,
				(errmsg("vamana index %u: loading TID map for %u vectors (%u slots total)",
						relid, meta.numVectors, tidMappingCapacity)));

		if (!VamanaLoadTidMap(relid, tidMapping, (int) tidMappingCapacity))
		{
			ereport(WARNING,
					(errmsg("vamana index %u: TID map missing or corrupt, rebuilding",
							relid)));
			SVSFreeIndex(svsIndex);
			pfree(tidMapping);
			VamanaDeleteSaveDir(relid);
			return NULL;
		}

		ereport(LOG,
				(errmsg("vamana index %u: TID map loaded", relid)));
	}

	VamanaCacheIndex(relid, svsIndex,
					 meta.dimensions, meta.graph_degree,
					 VAMANA_ALPHA_TO_FLOAT(meta.alpha),
					 tidMapping, meta.numVectors,
					 (int) tidMappingCapacity,
					 nextExternalId, (int) numDeleted);

	if (tidMapping)
		pfree(tidMapping);

	ereport(LOG,
			(errmsg("vamana index %u loaded from disk (%u vectors, capacity %u)",
					relid, meta.numVectors, tidMappingCapacity)));

	return svsIndex;
}

/*
 * Begin scan
 */
IndexScanDesc
vamanabeginscan(Relation index, int nkeys, int norderbys)
{
	IndexScanDesc scan;
	VamanaScanOpaque so;
	VamanaOptions *opts;
	int			searchWindowSize;

	scan = RelationGetIndexScan(index, nkeys, norderbys);

	so = (VamanaScanOpaque) palloc0(sizeof(VamanaScanOpaqueData));
	so->typeInfo = VamanaGetTypeInfo(index);
	so->indexRelid = RelationGetRelid(index);	/* Store for cache lookup */
	so->currentResult = 0;
	so->numResults = 0;
	so->results = NULL;
	so->distances = NULL;

	/*
	 * Determine search window size: 1) GUC vamana.search_window_size 2) index
	 * reloption search_window_size
	 */
	opts = (VamanaOptions *) index->rd_options;
	searchWindowSize = vamana_search_window_size;
	if (searchWindowSize <= 0)
		searchWindowSize = (opts != NULL) ? opts->search_window_size : VAMANA_DEFAULT_SEARCH_WINDOW;
	if (searchWindowSize <= 0)
		searchWindowSize = VAMANA_DEFAULT_SEARCH_WINDOW;

	so->searchWindowSize = searchWindowSize;
	/* Return at least search window size candidates instead of hard-capped 10 */
	so->k = searchWindowSize;

	VamanaInitSupport(&so->support, index);

	if (vamana_worker_enabled && VamanaWorkerIsAvailable())
	{
		/*
		 * Worker mode: the background worker holds the canonical index
		 * handle. Set a non-NULL sentinel so the `if (so->svsIndex)` guard in
		 * vamanarescan() passes; the actual search goes through IPC.
		 */
		so->svsIndex = VAMANA_WORKER_HANDLE_SENTINEL;
	}
	else
	{
		/* Direct mode: load or rebuild the index in this process */
		bool		needsRebuild;

		so->svsIndex = VamanaGetCachedIndex(RelationGetRelid(index), &needsRebuild);

		if (needsRebuild)
		{
			so->svsIndex = LoadIndexFromPages(index);

			if (so->svsIndex == NULL)
			{
				ereport(LOG,
						(errmsg("vamana index not in memory, rebuilding from table")));

				so->svsIndex = VamanaRebuildFromTable(index);

				if (so->svsIndex != NULL)
					VamanaCacheSetNeedsSave(RelationGetRelid(index), true);
			}
		}
	}

	scan->opaque = so;

	return scan;
}

/*
 * Rescan - prepare for new scan
 */
void
vamanarescan(IndexScanDesc scan, ScanKey keys, int nkeys,
			 ScanKey orderbys, int norderbys)
{
	VamanaScanOpaque so = (VamanaScanOpaque) scan->opaque;

	/* Extract query vector from orderbys */
	if (norderbys > 0 && so->svsIndex)
	{
		Vector	   *queryVec;
		int			k = Max(so->k, 1);

		so->queryValue = orderbys[0].sk_argument;

		if (DatumGetPointer(so->queryValue) == NULL)
		{
			/* NULL query - return no results */
			so->numResults = 0;
			so->currentResult = 0;
			return;
		}

		/*
		 * Use _COPY to ensure queryVec->x is in its own palloc allocation.
		 * SVS reads the query vector in aligned chunks; without _COPY, an
		 * untoasted datum points into the heap page buffer and SVS could read
		 * past the palloc block boundary.
		 */
		queryVec = (Vector *) PG_DETOAST_DATUM_COPY(so->queryValue);

		if (so->results)
			pfree(so->results);
		if (so->distances)
			pfree(so->distances);

		so->results = palloc(k * sizeof(ItemPointerData));
		so->distances = palloc(k * sizeof(float));

		if (so->svsIndex == VAMANA_WORKER_HANDLE_SENTINEL)
		{
			/*
			 * Worker mode: submit the search request to the background worker
			 * via shared-memory IPC and wait for results.
			 */
			so->numResults = VamanaWorkerSubmitSearch(
													  so->indexRelid,
													  queryVec->x,
													  queryVec->dim,
													  k,
													  so->searchWindowSize,
													  so->results,
													  so->distances);

			if (so->numResults < 0)
			{
				/*
				 * Worker failed or timed out.  Fall back to loading the index
				 * directly into this backend: expensive but correct.
				 */
				ereport(WARNING,
						(errmsg("vamana worker unavailable, falling back to direct load for index %u",
								so->indexRelid)));

				so->svsIndex = VamanaWorkerFallbackLoad(scan->indexRelation);

				if (so->svsIndex != NULL)
					so->numResults = SVSSearch(so->indexRelid, so->svsIndex,
											   queryVec->x, queryVec->dim, k,
											   so->searchWindowSize,
											   so->results, so->distances);
				else
				{
					ereport(WARNING,
							(errmsg("vamana index %u: worker unavailable and fallback load failed; "
									"returning empty result set", so->indexRelid),
							 errhint("Run REINDEX on the index to rebuild it.")));
					so->numResults = 0;
				}
			}
		}
		else
		{
			/* Direct mode: search using the in-process SVS handle */
			so->numResults = SVSSearch(
									   so->indexRelid,
									   so->svsIndex,
									   queryVec->x,
									   queryVec->dim,
									   k,
									   so->searchWindowSize,
									   so->results,
									   so->distances
				);
		}

		if (so->numResults < 0)
		{
			pfree(queryVec);
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("SVS search failed with result %d", so->numResults)));
		}
		pfree(queryVec);		/* free the _COPY allocation */

		so->currentResult = 0;
	}
	else if (!so->svsIndex)
	{
		/* No index loaded - return empty results */
		ereport(WARNING,
				(errmsg("no SVS index available for scan"),
				 errhint("Index may need to be rebuilt with REINDEX")));
		so->numResults = 0;
		so->currentResult = 0;
	}
}

/*
 * Get next tuple from scan
 */
bool
vamanagettuple(IndexScanDesc scan, ScanDirection dir)
{
	VamanaScanOpaque so = (VamanaScanOpaque) scan->opaque;

	/* Handle backward scan (not supported) */
	if (ScanDirectionIsBackward(dir))
		elog(ERROR, "vamana index does not support backward scan");

	if (so->currentResult >= so->numResults)
		return false;

	scan->xs_heaptid = so->results[so->currentResult];
	scan->xs_recheck = false;	/* no heap tuple recheck needed */
	scan->xs_recheckorderby = false;

	/*
	 * Note: We do NOT set xs_orderbyvals - PostgreSQL's executor handles
	 * distance calculation automatically for ORDER BY with distance
	 * operators. This is the same pattern used by HNSW and IVFFlat indexes.
	 */

	so->currentResult++;

	return true;
}

/*
 * End scan
 */
void
vamanaendscan(IndexScanDesc scan)
{
	VamanaScanOpaque so = (VamanaScanOpaque) scan->opaque;

	/*
	 * Deferred save (Issue #40): persist a freshly rebuilt index to disk
	 * after all query results have been returned.  Skip worker-mode handles
	 * (the worker saves independently).
	 */
	if (so->svsIndex != NULL &&
		so->svsIndex != VAMANA_WORKER_HANDLE_SENTINEL &&
		VamanaCacheGetNeedsSave(so->indexRelid))
	{
		PG_TRY();
		{
			VamanaSaveIndexToDisk(scan->indexRelation, so->svsIndex,
								  MAIN_FORKNUM);
		}
		PG_CATCH();
		{
			FlushErrorState();
			ereport(WARNING,
					(errmsg("vamana index %u: could not save to disk",
							so->indexRelid)));
		}
		PG_END_TRY();
	}

	if (so->results)
	{
		pfree(so->results);
		so->results = NULL;
	}
	if (so->distances)
	{
		pfree(so->distances);
		so->distances = NULL;
	}

	pfree(so);
}
