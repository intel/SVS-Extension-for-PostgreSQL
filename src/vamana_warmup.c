/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_warmup.c
 *
 * SQL-callable warm-up: force vamana indexes resident in the worker's cache
 * on demand, so the load cost lands here rather than on first-query latency.
 *
 * svs_warmup_index(regclass) warms one index and fails loudly.
 * svs_warmup_database() warms every vamana index in the current database
 * best-effort, returning the count warmed.  Both delegate the per-index work
 * to warmup_one() so an index is resolved and opened exactly once.
 *
 * These run inside the caller's transaction and must not open one: the worker
 * owns the transaction for the actual load (VamanaWorkerProcessWarmupSlot).
 */

#include "postgres.h"

#include "vamana_subxact_guard.h"
#include "vamanaworker.h"

#include "access/relation.h"
#include "catalog/pg_class.h"
#include "commands/defrem.h"
#include "fmgr.h"
#include "nodes/pg_list.h"
#include "utils/lsyscache.h"
#include "utils/rel.h"

/*
 * Submit a warm-up for one index in the ambient transaction, returning whether
 * the worker confirmed it resident.  Verifies the relation is a vamana index
 * against the opened, visible relcache entry: a plain relam comparison, not the
 * SnapshotSelf path VamanaRelationIsVamanaIndex uses for not-yet-visible tuples
 * mid-DDL.  Throws on a non-vamana target; callers choosing best-effort must
 * isolate the call in a subtransaction.
 */
static bool
warmup_one(Oid relid)
{
	Relation	rel = relation_open(relid, AccessShareLock);
	Oid			vamanaAm = get_index_am_oid("vamana", false);
	bool		warmed;

	if (rel->rd_rel->relkind != RELKIND_INDEX ||
		rel->rd_rel->relam != vamanaAm)
	{
		char	   *name = pstrdup(RelationGetRelationName(rel));

		relation_close(rel, AccessShareLock);
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("\"%s\" is not a vamana index", name)));
	}

	warmed = VamanaWorkerSubmitWarmup(relid);

	relation_close(rel, AccessShareLock);
	return warmed;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_warmup_index);
Datum
svs_warmup_index(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);

	VamanaWorkerWaitUntilAvailable(relid, "warm up");

	if (!warmup_one(relid))
		ereport(ERROR,
				(errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
				 errmsg("could not warm up vamana index %u", relid)));

	PG_RETURN_VOID();
}

/* Arguments/result for WarmupOneBody, bundled for VamanaRunInSubXact. */
typedef struct WarmupOneArgs
{
	Oid		relid;
	bool	warmed;
} WarmupOneArgs;

static void
WarmupOneBody(void *arg)
{
	WarmupOneArgs *args = (WarmupOneArgs *) arg;

	args->warmed = warmup_one(args->relid);
}

/*
 * Warm one index under an internal subtransaction so a failure is confined to
 * that index and the batch continues.  Returns true if the index was warmed.
 */
static bool
warmup_one_guarded(Oid relid)
{
	WarmupOneArgs		args = {relid, false};
	VamanaSubXactResult	result;

	result = VamanaRunInSubXact(WarmupOneBody, &args, NULL);

	if (!result.succeeded)
	{
		ereport(WARNING,
				(errmsg("could not warm up vamana index %u: %s",
						relid, result.edata->message)));
		FreeErrorData(result.edata);
		return false;
	}

	return args.warmed;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_warmup_database);
Datum
svs_warmup_database(PG_FUNCTION_ARGS)
{
	List	   *relids = VamanaWorkerEnumerateIndexes();
	int			warmed = 0;

	if (relids == NIL)
		PG_RETURN_INT32(0);

	VamanaWorkerWaitUntilAvailable(linitial_oid(relids), "warm up");

	foreach_oid(relid, relids)
	{
		if (warmup_one_guarded(relid))
			warmed++;
	}

	PG_RETURN_INT32(warmed);
}
