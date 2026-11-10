/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_error_category_test.c
 *
 * SQL-callable driver for VamanaCategorizeSQLState and VamanaSlotErrcode,
 * standalone and with no real worker or shared memory involved: links
 * vamanaworkershmem.c and vamana_subxid_pending_array.c directly rather
 * than the preloaded svs.so, same pattern as svs_meta_counts_test. Uses the
 * real ERRCODE_ and VAMANA_ERR_ symbols directly rather than marshaling them
 * through SQL, since the point is to prove the codec's two directions agree
 * with each other, not to expose the encoding to SQL.
 */

#include "postgres.h"

#include "vamana.h"
#include "vamanaworker.h"

#include "fmgr.h"

PG_MODULE_MAGIC;

/*
 * vamanaworkershmem.c references these elsewhere in the file, in code this
 * module's test functions never reach; stub them so the symbols resolve.
 */
int			max_vamana_databases = 8;

void
SvsMemoryResetDatabaseAccounting(VamanaWorkerShmem *entry)
{
}

PG_FUNCTION_INFO_V1(svs_error_category_test_unsupported_hw_round_trips);
Datum
svs_error_category_test_unsupported_hw_round_trips(PG_FUNCTION_ARGS)
{
	uint8		category = VamanaCategorizeSQLState(ERRCODE_FEATURE_NOT_SUPPORTED);
	int			errcode_back = VamanaSlotErrcode(category);

	PG_RETURN_BOOL(category == VAMANA_ERR_UNSUPPORTED &&
				   errcode_back == ERRCODE_FEATURE_NOT_SUPPORTED);
}

/*
 * Regression guard: adding the new category must not have disturbed the
 * three pre-existing ones.
 */
PG_FUNCTION_INFO_V1(svs_error_category_test_existing_categories_unchanged);
Datum
svs_error_category_test_existing_categories_unchanged(PG_FUNCTION_ARGS)
{
	bool		ok = true;

	ok &= (VamanaCategorizeSQLState(ERRCODE_OUT_OF_MEMORY) == VAMANA_ERR_OOM);
	ok &= (VamanaCategorizeSQLState(ERRCODE_DATA_EXCEPTION) == VAMANA_ERR_DATA);
	ok &= (VamanaCategorizeSQLState(ERRCODE_IO_ERROR) == VAMANA_ERR_IO);
	ok &= (VamanaCategorizeSQLState(ERRCODE_INTERNAL_ERROR) == VAMANA_ERR_INTERNAL);

	ok &= (VamanaSlotErrcode(VAMANA_ERR_OOM) == ERRCODE_OUT_OF_MEMORY);
	ok &= (VamanaSlotErrcode(VAMANA_ERR_DATA) == ERRCODE_DATA_EXCEPTION);
	ok &= (VamanaSlotErrcode(VAMANA_ERR_IO) == ERRCODE_IO_ERROR);
	ok &= (VamanaSlotErrcode(VAMANA_ERR_INTERNAL) == ERRCODE_INTERNAL_ERROR);

	PG_RETURN_BOOL(ok);
}
