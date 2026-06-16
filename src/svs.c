/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs.c
 *
 * Requires pgvector (CREATE EXTENSION vector) to be installed first.
 * pgvector supplies the vector/halfvec data types and the distance operator
 * classes referenced by the Vamana operator classes.
 */

#include "postgres.h"

#include "fmgr.h"
#include "vamana.h"

#if PG_VERSION_NUM >= 180000
PG_MODULE_MAGIC_EXT(.name = "svs", .version = "0.1.0");
#else
PG_MODULE_MAGIC;
#endif

PGDLLEXPORT void _PG_init(void);
void
_PG_init(void)
{
	VamanaInit();
}
