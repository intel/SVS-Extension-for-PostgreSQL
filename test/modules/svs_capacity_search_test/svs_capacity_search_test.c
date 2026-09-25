/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_capacity_search_test.c
 *
 * SQL-callable driver for SvsSearchCapacityHeadroom(), exercised against a
 * fake blocked cost function so this module never needs to link the SVS
 * vendor library.
 */

#include "postgres.h"

#include "svs_capacity_search.h"

#include "fmgr.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC;

typedef struct BlockedCostContext
{
	uint64		blockSizeVectors;
} BlockedCostContext;

static uint64
BlockedCost(void *context, uint64 numVectors)
{
	BlockedCostContext *ctx = (BlockedCostContext *) context;
	uint64		blocks = (numVectors + ctx->blockSizeVectors - 1) / ctx->blockSizeVectors;

	return blocks * ctx->blockSizeVectors;
}

PGDLLEXPORT PG_FUNCTION_INFO_V1(svs_capacity_search_test_headroom);
Datum
svs_capacity_search_test_headroom(PG_FUNCTION_ARGS)
{
	uint64		numVectors = (uint64) PG_GETARG_INT64(0);
	BlockedCostContext ctx;
	uint64		headroom;

	ctx.blockSizeVectors = (uint64) PG_GETARG_INT64(1);

	headroom = SvsSearchCapacityHeadroom(BlockedCost, &ctx, numVectors,
										  (uint64) PG_GETARG_INT64(2));

	PG_RETURN_INT64((int64) headroom);
}
