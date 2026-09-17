/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_DATABASES_H
#define VAMANA_DATABASES_H

#include "postgres.h"

/*
 * Per-row entry queued by the vamana_databases row-level trigger, backing
 * the PRE_COMMIT reservation callback in vamana_databases.c.
 *
 * residencyMemoryMbOverride/searchWorkMemMbOverride mirror the shmem
 * override fields they get materialized into (VamanaWorkerSetMemoryOverrides):
 * 0 means "column was NULL, use the GUC default".
 *
 * durableResidencyFloorBytes is computed here in the trigger, which still
 * has the active snapshot a catalog read needs, rather than in the
 * PRE_COMMIT callback that drains this queue, which does not (see
 * svs_index_residency.h).
 */
typedef struct VamanaDatabasesReservationEntry
{
	NameData	datname;
	Oid			dbOid;
	bool		enabled;
	int64		restart_generation;
	int			residencyMemoryMbOverride;
	int			searchWorkMemMbOverride;
	uint64		durableResidencyFloorBytes;
	SubTransactionId subxid;
} VamanaDatabasesReservationEntry;

/*
 * Schema-qualified relname, resolved via the svs extension's own namespace
 * rather than search_path.  NULL if the extension (and therefore relname)
 * doesn't exist yet in this database.
 */
extern char *SvsExtensionQualifiedRelationName(const char *relname);

/* Schema-qualified "vamana_databases". Equivalent to the call above for that one relation. */
extern char *SvsDatabasesQualifiedName(void);

/* NULL means "follow the GUC default"; the calculator's sentinel for that is -1. */
extern int32 SvsResolveNullableThreadCount(bool isNull, int32 value);

/*
 * This database's own maintenance_num_threads, or -1 if NULL, no row, or the
 * table doesn't exist yet.  For a build backend resolving its own request
 * count; the launcher's bulk scan (ReadDatabaseRows) does not use this.
 */
extern int32 SvsDatabasesGetMyMaintenanceNumThreads(void);

#endif							/* VAMANA_DATABASES_H */
