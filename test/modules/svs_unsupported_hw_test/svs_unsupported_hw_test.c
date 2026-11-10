/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_unsupported_hw_test.c
 *
 * SQL-callable driver for SVSReportUnsupportedHardware, standalone and with
 * no real SVS error handle involved: links svs_wrapper.c directly rather
 * than the preloaded svs.so, same pattern as svs_meta_counts_test. The
 * function under test takes plain strings, not an svs_error_h, specifically
 * so it can be driven this way without needing a real unsupported-hardware
 * failure from SVS itself.
 */

#include "postgres.h"

#include "svs_capacity_search.h"
#include "vamana.h"
#include "svs_wrapper.h"

#include "fmgr.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC;

/*
 * svs_wrapper.c calls these elsewhere in the file, in code paths this
 * module's one test function never reaches; stub them so the symbols
 * resolve, same convention svs_meta_counts_test.c uses for the one function
 * it has to stub.
 */
uint64
SvsSearchCapacityHeadroom(SvsCapacityCostFn costFn, void *context,
						  uint64 numVectors, uint64 maxSearchVectors)
{
	return 0;
}

VamanaIndexCache *
VamanaGetCache(Oid indexRelid)
{
	return NULL;
}

PG_FUNCTION_INFO_V1(svs_unsupported_hw_test_report);
Datum
svs_unsupported_hw_test_report(PG_FUNCTION_ARGS)
{
	char	   *message = text_to_cstring(PG_GETARG_TEXT_PP(0));
	char	   *compressionName = text_to_cstring(PG_GETARG_TEXT_PP(1));

	SVSReportUnsupportedHardware(message, compressionName);	/* never returns */

	PG_RETURN_VOID();
}
