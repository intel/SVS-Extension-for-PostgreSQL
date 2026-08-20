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

#include "vamana.h"
#include "vamana_undo.h"
#include "svs_wrapper.h"
#include "vamanaworker.h"

#include "access/genam.h"
#include "catalog/index.h"
#include "miscadmin.h"
#include "utils/rel.h"

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
	Vector	   *vec;
	uint64		externalId;

	if (isnull[0])
		return false;

	VamanaWorkerWaitUntilAvailable(relid, "insert into");

	vec = (Vector *) PG_DETOAST_DATUM_COPY(values[0]);
	VamanaValidateVectorData(vec->x, vec->dim, "insert");

	/* Submit to BGW — blocks until the worker ACKs or errors. */
	VamanaWorkerSubmitInsert(relid, vec->x, vec->dim, heap_tid, &externalId);

	pfree(vec);

	/* Record (relid, externalId) so we can roll back on transaction abort. */
	VamanaUndoAppend(relid, externalId);

	return true;
}
