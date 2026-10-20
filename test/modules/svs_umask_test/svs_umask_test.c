/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_umask_test.c
 *
 * SQL-callable umask() wrapper so a TAP test can widen the backend's own
 * umask before issuing CREATE INDEX, to distinguish directory modes set
 * explicitly from those that only happen to land correctly via umask.
 * Not part of the svs extension; never installed alongside it.
 */

#include "postgres.h"

#include "fmgr.h"

#include <sys/stat.h>
#include <sys/types.h>

PG_MODULE_MAGIC;

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_test_set_umask);
Datum
svs_test_set_umask(PG_FUNCTION_ARGS)
{
	int32		newMask = PG_GETARG_INT32(0);

	PG_RETURN_INT32((int32) umask((mode_t) newMask));
}
