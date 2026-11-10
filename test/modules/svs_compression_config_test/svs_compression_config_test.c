/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_compression_config_test.c
 *
 * SQL-callable driver for VamanaCompressionConfigIsValid, standalone and
 * with no build, worker, or real index involved: links
 * vamana_compression_rules.c directly rather than the preloaded svs.so,
 * same pattern as svs_meta_counts_test. That file has no dependencies
 * beyond libc, so no stub symbols are needed here.
 */

#include "postgres.h"

#include "vamana.h"

#include "fmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(svs_compression_config_test_is_valid);
Datum
svs_compression_config_test_is_valid(PG_FUNCTION_ARGS)
{
	int32		compression_type = PG_GETARG_INT32(0);
	int32		compression_primary = PG_GETARG_INT32(1);
	int32		compression_secondary = PG_GETARG_INT32(2);

	PG_RETURN_BOOL(VamanaCompressionConfigIsValid(compression_type,
												  compression_primary,
												  compression_secondary));
}
