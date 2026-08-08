/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_SUBXACT_GUARD_H
#define VAMANA_SUBXACT_GUARD_H

#include "postgres.h"
#include "utils/elog.h"

/*
 * Runs one unit of work in its own subtransaction so a failure there does
 * not abort the caller's transaction: the "catch, log/capture, skip,
 * continue" pattern used to make a batch operation resilient to one bad
 * member (a corrupt WAL record, an undroppable index, an unloadable index).
 *
 * On success, edata is NULL and the subtransaction is released. On a caught
 * error, edata is the copied error (the caller owns it and must
 * FreeErrorData it) and the subtransaction has been rolled back and
 * released; only the disposition of that error is left to the caller.
 */
typedef struct VamanaSubXactResult
{
	bool		succeeded;
	ErrorData  *edata;
} VamanaSubXactResult;

typedef void (*VamanaSubXactBody) (void *arg);

/*
 * Returning true tells VamanaRunInSubXact that the caught error is not
 * this unit's to swallow (e.g. a shutdown cancel): the subtransaction is
 * still rolled back and released, but the error is re-thrown instead of
 * being returned. Pass NULL to always swallow.
 */
typedef bool (*VamanaSubXactShouldPropagate) (void);

extern VamanaSubXactResult VamanaRunInSubXact(VamanaSubXactBody body, void *arg,
											   VamanaSubXactShouldPropagate shouldPropagate);

#endif							/* VAMANA_SUBXACT_GUARD_H */
