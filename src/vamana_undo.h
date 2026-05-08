#ifndef VAMANA_UNDO_H
#define VAMANA_UNDO_H

#include "postgres.h"
#include "utils/relcache.h"

/*
 * Public API for the per-transaction undo log.
 *
 * On INSERT: call VamanaUndoAppend(relid, externalId) immediately after the
 * BGW confirms the insert.
 *
 * On transaction ABORT: the registered XactCallback submits BGW DELETEs for
 * every entry in the log, rolling back the in-memory graph state.
 *
 * On transaction COMMIT: the log is discarded.
 *
 * Subtransactions: VamanaUndoAppendSub() tags the entry with the current
 * subxid so VamanaSubXactCallback can roll back only the aborting sub.
 */

void	VamanaUndoAppend(Oid indexRelid, uint64 externalId);

#endif							/* VAMANA_UNDO_H */
