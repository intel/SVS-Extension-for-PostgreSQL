/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_residency_reconcile_test.c
 *
 * SQL-callable driver for SvsIndexResidencyReconcileOrphans, exercising the
 * real function against the real svs_index_residency table -- no fake
 * shmem, since the function under test never touches shared memory. The
 * two symbols it references from outside svs_index_residency.c are stubbed
 * below rather than pulling in vamana_databases.c or vamanaworker.c: this
 * module has nothing to do with the worker or the wider database-lifecycle
 * machinery those files own.
 */

#include "postgres.h"

#include "svs_index_residency.h"
#include "vamana_databases.h"
#include "vamanaworker.h"

#include "catalog/pg_type.h"
#include "commands/extension.h"
#include "fmgr.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"

PG_MODULE_MAGIC;

/* Mirrors the real definition in vamana_databases.c without its dependencies. */
char *
SvsExtensionQualifiedRelationName(const char *relname)
{
	Oid			extOid = get_extension_oid("svs", true);
	Oid			nspOid;

	if (!OidIsValid(extOid))
		return NULL;

	nspOid = get_extension_schema(extOid);
	if (!OidIsValid(get_relname_relid(relname, nspOid)))
		return NULL;

	return psprintf("%s.%s", quote_identifier(get_namespace_name(nspOid)),
					quote_identifier(relname));
}

/* Only reached from SvsIndexResidencyDurableFloor, which this module does not call. */
bool
VamanaWorkerEntryIsLive(VamanaWorkerShmem *entry)
{
	return false;
}

PG_FUNCTION_INFO_V1(svs_residency_reconcile_test_call);

Datum
svs_residency_reconcile_test_call(PG_FUNCTION_ARGS)
{
	Oid			dbOid = PG_GETARG_OID(0);
	ArrayType  *liveArray = PG_GETARG_ARRAYTYPE_P(1);
	Datum	   *elems;
	bool	   *nulls;
	int			nelems;
	Oid		   *liveRelids;

	deconstruct_array(liveArray, OIDOID, sizeof(Oid), true, TYPALIGN_INT,
					   &elems, &nulls, &nelems);

	liveRelids = (Oid *) palloc(sizeof(Oid) * (nelems > 0 ? nelems : 1));
	for (int i = 0; i < nelems; i++)
		liveRelids[i] = DatumGetObjectId(elems[i]);

	SvsIndexResidencyReconcileOrphans(dbOid, liveRelids, nelems);

	PG_RETURN_VOID();
}
