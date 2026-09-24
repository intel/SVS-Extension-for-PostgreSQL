/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#include "postgres.h"

#include "svs_capacity_search.h"

uint64
SvsSearchCapacityHeadroom(SvsCapacityCostFn costFn, void *context,
						   uint64 numVectors, uint64 maxSearchVectors)
{
	uint64		baseline = costFn(context, numVectors);
	uint64		goodDelta = 0;
	uint64		badDelta = maxSearchVectors + 1;

	while (badDelta - goodDelta > 1)
	{
		uint64		midDelta = goodDelta + (badDelta - goodDelta) / 2;

		if (costFn(context, numVectors + midDelta) == baseline)
			goodDelta = midDelta;
		else
			badDelta = midDelta;
	}

	return goodDelta;
}
