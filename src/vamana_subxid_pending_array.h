/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_SUBXID_PENDING_ARRAY_H
#define VAMANA_SUBXID_PENDING_ARRAY_H

#include "postgres.h"
#include "access/xact.h"

/*
 * A growable, TopTransactionContext-scoped array of fixed-size elements,
 * each tagged with the subtransaction that appended it.
 *
 * Every caller wants the same append/grow/subxact-prune plumbing but
 * disagrees on what happens at COMMIT (fold-and-apply, batch-and-submit,
 * filter-and-reserve), so this owns storage only; each caller keeps its own
 * drain and its own XactCallback/SubXactCallback registration.
 */
typedef struct VamanaSubxidPendingArray
{
	MemoryContext memContext;
	void	   *entries;
	int			count;
	int			capacity;
	size_t		elemSize;
	size_t		subxidOffset;	/* offsetof(ElemType, subxid) */
} VamanaSubxidPendingArray;

extern VamanaSubxidPendingArray *VamanaSubxidPendingArrayCreate(MemoryContext memContext,
																  size_t elemSize,
																  size_t subxidOffset,
																  int initialCapacity);

/*
 * Grow the array if full, tag the new element with the current
 * subtransaction, and return it for the caller to fill in.
 */
extern void *VamanaSubxidPendingArrayAppend(VamanaSubxidPendingArray *array);

/*
 * Mark every element appended under mySubid as InvalidSubTransactionId, so a
 * later drain skips entries belonging to a rolled-back subtransaction.
 */
extern void VamanaSubxidPendingArrayPruneAbortedSubxact(VamanaSubxidPendingArray *array,
														  SubTransactionId mySubid);

#define VamanaSubxidPendingArrayEntryAt(array, i) \
	((void *) ((char *) (array)->entries + (size_t) (i) * (array)->elemSize))

#define VamanaSubxidPendingArraySubxidAt(array, i) \
	(*(SubTransactionId *) ((char *) VamanaSubxidPendingArrayEntryAt(array, i) + (array)->subxidOffset))

#endif							/* VAMANA_SUBXID_PENDING_ARRAY_H */
