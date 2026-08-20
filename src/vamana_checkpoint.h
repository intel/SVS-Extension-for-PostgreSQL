/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_CHECKPOINT_H
#define VAMANA_CHECKPOINT_H

#include "vamana.h"

bool	ShouldCheckpoint(VamanaIndexCache *cache);
bool	PerformCheckpoint(VamanaIndexCache *cache);
bool	VamanaCheckpointCachedIndex(VamanaIndexCache *cache);

#endif							/* VAMANA_CHECKPOINT_H */
