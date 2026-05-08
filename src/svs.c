/*
 * svs.c
 *
 * PostgreSQL extension entry point for the standalone SVS Vamana index.
 *
 * This file provides PG_MODULE_MAGIC and _PG_init() for the svs extension.
 * In the patch-based delivery (pgvector-intel-innersource), VamanaInit() is
 * called from pgvector's own _PG_init() in vector.c.  Here it is called from
 * this extension's own _PG_init(), making the extension fully self-contained.
 *
 * The extension requires pgvector (CREATE EXTENSION vector) to be installed
 * first; see svs.control.  pgvector provides:
 *   - the vector / halfvec data types (vector.h is installed as a public header)
 *   - the distance operator classes referenced by the Vamana operator classes
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
