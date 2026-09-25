/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_CAPACITY_SEARCH_H
#define SVS_CAPACITY_SEARCH_H

#include "postgres.h"

/*
 * Capacity-based byte cost for exactly numVectors rows. Must be monotonic
 * non-decreasing in numVectors.
 */
typedef uint64 (*SvsCapacityCostFn) (void *context, uint64 numVectors);

/*
 * Number of additional rows that fit above numVectors before costFn's
 * result would grow past its value at numVectors, searched up to
 * numVectors + maxSearchVectors. Returns maxSearchVectors if no growth is
 * found in that range.
 */
extern uint64 SvsSearchCapacityHeadroom(SvsCapacityCostFn costFn, void *context,
										 uint64 numVectors, uint64 maxSearchVectors);

#endif							/* SVS_CAPACITY_SEARCH_H */
