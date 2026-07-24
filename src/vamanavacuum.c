/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

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
 * Reads tidMappingCapacity from the metapage, then loads the TID map from the
 * on-disk tidmap.bin file.  If the file does not yet exist, vacuum is skipped
 * with a LOG (nothing to delete).
 */
IndexBulkDeleteResult *
vamanabulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
				 IndexBulkDeleteCallback callback, void *callback_state)
{
	Relation	index = info->index;
	Oid			relid = RelationGetRelid(index);
	ItemPointerData *tidMapping = NULL;
	int			tidMappingCapacity = 0;
	size_t	   *deadIds = NULL;
	int			numDead = 0;
	VamanaMetaPageData meta;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	VamanaWorkerAssertDatabase();

	/*
	 * BGW unavailability is transient.  Dead vectors are MVCC-invisible and do
	 * not affect query correctness, so deferring removal is safe.  Blocking
	 * VACUUM entirely would be worse than the temporary search quality
	 * degradation caused by leaving dead vectors in the graph.
	 */
	if (!VamanaWorkerIsAvailable())
	{
		ereport(WARNING,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("vamana index \"%s\": background worker unavailable; dead vector removal skipped",
						RelationGetRelationName(index)),
				 errhint("Dead vectors accumulate in the index graph and may degrade search quality. "
						 "They will be removed when the background worker restarts and vacuum runs again.")));
		return stats;
	}

	VamanaReadMetaPage(index, &meta);
	tidMappingCapacity = (int) meta.tidMappingCapacity;

	if (tidMappingCapacity <= 0)
	{
		ereport(LOG,
				(errmsg("vamana index \"%s\": vacuum skipped -- metapage reports zero TID map capacity",
						RelationGetRelationName(index))));
		return stats;
	}

	tidMapping = palloc0((Size) tidMappingCapacity * sizeof(ItemPointerData));

	if (!VamanaLoadTidMap(relid, tidMapping, tidMappingCapacity))
	{
		pfree(tidMapping);
		ereport(LOG,
				(errmsg("vamana index \"%s\": vacuum skipped -- on-disk TID map not available",
						RelationGetRelationName(index))));
		return stats;
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
						(errmsg("vamana index \"%s\": BGW delete failed during vacuum (batch at offset %d)",
								RelationGetRelationName(index), submitted)));
				break;
			}
			submitted += batch;
		}
	}

	pfree(deadIds);
	pfree(tidMapping);

	stats->tuples_removed = (double) numDead;
	VamanaReadMetaPage(index, &meta);
	stats->num_index_tuples = (double) (meta.numVectors > (uint32) numDead ?
										meta.numVectors - (uint32) numDead : 0);

	return stats;
}

/*
 * vamanavacuumcleanup
 *
 * After bulk-delete: run CONSOLIDATE (always) and optionally COMPACT via the
 * BGW.  Reads numDeleted and numVectors from the metapage.
 */
IndexBulkDeleteResult *
vamanavacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
	Relation	index = info->index;
	Oid			relid = RelationGetRelid(index);
	VamanaMetaPageData meta;

	if (stats == NULL)
		stats = (IndexBulkDeleteResult *) palloc0(sizeof(IndexBulkDeleteResult));

	stats->num_pages = RelationGetNumberOfBlocks(index);

	if (VamanaWorkerIsAvailable())
	{
		VamanaReadMetaPage(index, &meta);

		if (meta.numDeleted > 0)
		{
			if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_CONSOLIDATE))
				ereport(WARNING,
						(errmsg("vamana index \"%s\": BGW consolidate failed during vacuum cleanup",
								RelationGetRelationName(index))));

			if (meta.numVectors > 0 &&
				vamana_compact_threshold_pct < 100 &&
				meta.numDeleted * 100 > meta.numVectors * (uint32) vamana_compact_threshold_pct)
			{
				if (!VamanaWorkerSubmitMaintenance(relid, VAMANA_MAINTENANCE_COMPACT))
					ereport(WARNING,
							(errmsg("vamana index \"%s\": BGW compact failed during vacuum cleanup",
									RelationGetRelationName(index))));
			}
		}
	}

	return stats;
}
