/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_DATABASES_H
#define VAMANA_DATABASES_H

#include "postgres.h"

/*
 * Per-row entry queued by the vamana_databases row-level trigger, backing
 * the PRE_COMMIT reservation callback in vamana_databases.c.
 */
typedef struct VamanaDatabasesReservationEntry
{
	NameData	datname;
	Oid			dbOid;
	bool		enabled;
	SubTransactionId subxid;
} VamanaDatabasesReservationEntry;

typedef struct VamanaDatabasesReservationList
{
	VamanaDatabasesReservationEntry *entries;
	int			count;
	int			capacity;
} VamanaDatabasesReservationList;

#endif							/* VAMANA_DATABASES_H */
