/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_meta_counts_test.c
 *
 * SQL-callable driver for VamanaValidateMetaCounts, standalone and with no
 * launcher, worker, or real index involved: links vamanautils.c directly
 * rather than the preloaded svs.so, same pattern as svs_cache_load_test.
 * Only exercises the type-ceiling and internal-consistency checks
 * (checkResidencyBudget = false); the residency-anchor check needs a real
 * admitted database and is covered end to end by the on-disk tampering TAP
 * test instead.
 */

#include "postgres.h"

#include "vamana.h"

#include "access/reloptions.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

/*
 * vamanaoptions() in the linked vamanautils.c references this; never called
 * from this module.
 */
relopt_kind vamana_relopt_kind;

/*
 * VamanaValidateMetaCounts's residency-anchor check calls this when
 * checkResidencyBudget is true; this module only drives it with false, but
 * the symbol must still resolve for the extension's library to load.
 */
extern uint64 SvsMemoryResidencyBudget(Oid dbOid);

uint64
SvsMemoryResidencyBudget(Oid dbOid)
{
	return 0;
}

PG_FUNCTION_INFO_V1(svs_meta_counts_test_validate);
Datum
svs_meta_counts_test_validate(PG_FUNCTION_ARGS)
{
	Oid			relid = PG_GETARG_OID(0);
	int64		tidMappingCapacity = PG_GETARG_INT64(1);
	int64		numVectors = PG_GETARG_INT64(2);
	int64		numDeleted = PG_GETARG_INT64(3);
	int64		nextExternalId = PG_GETARG_INT64(4);

	VamanaValidateMetaCounts(relid,
							 (uint32) tidMappingCapacity,
							 (uint32) numVectors,
							 (uint32) numDeleted,
							 (uint64) nextExternalId,
							 false);

	PG_RETURN_BOOL(true);
}
