/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * vamana_subxid_pending_array.c
 *
 * Storage for the subxid-tagged, transaction-scoped pending array shared by
 * vamanaworkershmem.c (index-count deltas), vamana_databases.c (slot
 * reservations), and vamana_undo.c (undo entries). Drain semantics differ
 * per caller and stay there; this owns only append, grow, and subxact prune.
 */

#include "postgres.h"

#include <limits.h>

#include "vamana_subxid_pending_array.h"

VamanaSubxidPendingArray *
VamanaSubxidPendingArrayCreate(MemoryContext memContext, size_t elemSize,
								size_t subxidOffset, int initialCapacity)
{
	VamanaSubxidPendingArray *array;
	MemoryContext oldCtx = MemoryContextSwitchTo(memContext);

	array = palloc0(sizeof(VamanaSubxidPendingArray));
	array->memContext = memContext;
	array->elemSize = elemSize;
	array->subxidOffset = subxidOffset;
	array->capacity = initialCapacity;
	array->entries = palloc(elemSize * initialCapacity);

	MemoryContextSwitchTo(oldCtx);

	return array;
}

void *
VamanaSubxidPendingArrayAppend(VamanaSubxidPendingArray *array)
{
	void	   *entry;
	SubTransactionId *subxid;

	if (array->count >= array->capacity)
	{
		MemoryContext oldCtx = MemoryContextSwitchTo(array->memContext);

		if (array->capacity > INT_MAX / 2)
			elog(ERROR, "VamanaSubxidPendingArray: capacity overflow at %d entries",
				 array->capacity);
		array->capacity *= 2;
		array->entries = repalloc(array->entries, array->elemSize * array->capacity);

		MemoryContextSwitchTo(oldCtx);
	}

	entry = VamanaSubxidPendingArrayEntryAt(array, array->count);
	array->count++;

	subxid = (SubTransactionId *) ((char *) entry + array->subxidOffset);
	*subxid = GetCurrentSubTransactionId();

	return entry;
}

static void
ReplaceMatchingSubxid(VamanaSubxidPendingArray *array, SubTransactionId mySubid,
					   SubTransactionId replacement)
{
	for (int i = 0; i < array->count; i++)
	{
		if (VamanaSubxidPendingArraySubxidAt(array, i) == mySubid)
			VamanaSubxidPendingArraySubxidAt(array, i) = replacement;
	}
}

void
VamanaSubxidPendingArrayPruneAbortedSubxact(VamanaSubxidPendingArray *array,
											 SubTransactionId mySubid)
{
	ReplaceMatchingSubxid(array, mySubid, InvalidSubTransactionId);
}

/*
 * A released savepoint's entries must stay findable by an ancestor's later
 * ROLLBACK TO SAVEPOINT, so give them the parent's subxid.
 */
void
VamanaSubxidPendingArrayReparentSubxact(VamanaSubxidPendingArray *array,
										 SubTransactionId mySubid,
										 SubTransactionId parentSubid)
{
	ReplaceMatchingSubxid(array, mySubid, parentSubid);
}
