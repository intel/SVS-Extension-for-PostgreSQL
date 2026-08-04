/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_DATABASES_H
#define VAMANA_DATABASES_H

#include "postgres.h"

/*
 * Public API for the vamana_databases row-level trigger.
 *
 * vamana_databases_queue_reservation() appends (datname, enabled) for each
 * affected row into a backend-local, TopTransactionContext-scoped list.
 * It does not reserve any shmem slot and does not call
 * RegisterXactCallback() itself; a future PRE_COMMIT callback registered
 * elsewhere drains this list via VamanaDatabasesReservationQueue().
 */

typedef struct VamanaDatabasesReservationEntry
{
	NameData	datname;
	bool		enabled;
} VamanaDatabasesReservationEntry;

typedef struct VamanaDatabasesReservationList
{
	VamanaDatabasesReservationEntry *entries;
	int			count;
	int			capacity;
} VamanaDatabasesReservationList;

/*
 * Returns the current transaction's queued reservation entries, or NULL if
 * none have been queued yet. The list and its contents live in
 * TopTransactionContext and are reclaimed automatically at end-of-transaction.
 */
VamanaDatabasesReservationList *VamanaDatabasesReservationQueue(void);

#endif							/* VAMANA_DATABASES_H */
