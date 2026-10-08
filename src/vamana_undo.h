/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef VAMANA_UNDO_H
#define VAMANA_UNDO_H

#include "postgres.h"
#include "utils/relcache.h"

/*
 * Public API for the per-transaction undo log.
 *
 * On INSERT: call VamanaUndoAppend(relid, externalId, growthBytes,
 * generation) immediately after the BGW confirms the insert. growthBytes
 * and generation are SvsMemoryReanchorInsert's own outputs from that same
 * apply, carried here so an abort can credit exactly this insert's growth
 * back as reclaimable (SvsMemoryCreditAbortedInserts) instead of leaving it
 * stranded against the residency budget.
 *
 * On transaction ABORT: the registered XactCallback submits BGW DELETEs for
 * every entry in the log, rolling back the in-memory graph state, and
 * credits each successfully deleted batch's growth back once the delete is
 * confirmed.
 *
 * On transaction COMMIT: the log is discarded, and the growth these entries
 * recorded stays charged -- it is real, committed residency.
 *
 * Subtransactions: each entry recorded by VamanaUndoAppend() carries the
 * current subxid so VamanaSubXactCallback can roll back only the aborting
 * subtransaction's entries.
 */

void	VamanaUndoAppend(Oid indexRelid, uint64 externalId,
						 uint64 growthBytes, uint32 generation);

#endif							/* VAMANA_UNDO_H */
