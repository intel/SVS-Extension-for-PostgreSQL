/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamanainsert.c
 *
 * Insert operations for Vamana index.
 * All writes are routed through the background worker.
 */

#include "postgres.h"

#include "svs_memory.h"
#include "vamana.h"
#include "vamana_replication.h"
#include "vamana_undo.h"
#include "svs_wrapper.h"
#include "vamanaworker.h"

#include "access/genam.h"
#include "catalog/index.h"
#include "miscadmin.h"
#include "utils/rel.h"

/*
 * Conservative upper bound: raw vector storage plus one full neighbor list.
 * elementSize is the stored element width, not the float the datum is widened
 * to, so a halfvec index is not charged twice what it occupies.
 */
static uint64
VamanaEstimateInsertGrowthBytes(int dimensions, Size elementSize, int graphDegree)
{
	return (uint64) dimensions * elementSize +
		(uint64) graphDegree * sizeof(uint32);
}

bool
vamanainsert(Relation index, Datum *values, bool *isnull,
			 ItemPointer heap_tid, Relation heapRelation,
			 IndexUniqueCheck checkUnique,
#if PG_VERSION_NUM >= 140000
			 bool indexUnchanged,
#endif
			 IndexInfo *indexInfo)
{
	Oid			relid = RelationGetRelid(index);
	const		VamanaTypeInfo *typeInfo = VamanaGetTypeInfo(index);
	float	   *floats;
	int			dim;
	uint64		externalId;
	bool		slotCreated;

	if (isnull[0])
		return false;

	VamanaWorkerWaitUntilAvailable(relid, "insert into");

	floats = VamanaDatumToFloats(typeInfo, values[0], &dim, "insert");

	/* Defense-in-depth: PostgreSQL's type system normally prevents this. */
	if (dim != TupleDescAttr(index->rd_att, 0)->atttypmod)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
				 errmsg("vector dimension %d does not match index dimension %d",
						dim, TupleDescAttr(index->rd_att, 0)->atttypmod)));

	{
		uint64		growthBytes = VamanaEstimateInsertGrowthBytes(dim,
																	typeInfo->elementSize,
																	VamanaGetGraphDegree(index));

		if (!SvsMemoryReserveInsert(MyDatabaseId, relid, growthBytes))
			ereport(ERROR,
					(errcode(ERRCODE_OUT_OF_MEMORY),
					 errmsg("insert into index \"%s\" would exceed its database's residency budget",
							RelationGetRelationName(index)),
					 errhint("Raise this database's residency_memory or svs.max_residency_memory.")));

		/* Submit to BGW — blocks until the worker ACKs or errors. */
		PG_TRY();
		{
			VamanaWorkerSubmitInsert(relid, floats, dim, heap_tid,
									 &externalId, &slotCreated);
		}
		PG_CATCH();
		{
			SvsMemoryAbortInsert(MyDatabaseId, relid);
			PG_RE_THROW();
		}
		PG_END_TRY();
	}

	pfree(floats);

	/* Record (relid, externalId) so we can roll back on transaction abort. */
	VamanaUndoAppend(relid, externalId);

	if (slotCreated)
		VamanaReplicationQueueRetireOnAbort(MyDatabaseId, relid);

	return true;
}
