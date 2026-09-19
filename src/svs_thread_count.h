/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * Shared between the search governor (svs_cpu_budget.c) and the build
 * thread request path (svs_wrapper.c, svs_build_thread_grant.c), which
 * otherwise share no code.
 */

#ifndef SVS_THREAD_COUNT_H
#define SVS_THREAD_COUNT_H

#include "postgres.h"

static inline int32
SvsAtLeastOneThread(int32 threads)
{
	return Max(threads, 1);
}

#endif							/* SVS_THREAD_COUNT_H */
