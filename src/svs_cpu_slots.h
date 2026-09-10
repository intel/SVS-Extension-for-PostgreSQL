/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

#ifndef SVS_CPU_SLOTS_H
#define SVS_CPU_SLOTS_H

#include "postgres.h"
#include "postmaster/bgworker.h"

#include "svs_slot_naming.h"

/*
 * A set of parked parallel-class slots: background workers that do nothing but
 * hold one max_parallel_workers unit each, so PostgreSQL's own counter accounts
 * for SVS threads that are otherwise invisible.
 *
 * Unlike svs_parallel_build.c's ParallelContext-based pool, a slot set is
 * registered with raw RegisterDynamicBackgroundWorker and
 * BGWORKER_CLASS_PARALLEL: no DSM segment, no shm_mq, no ParallelContext.
 * That is deliberate.  A build's parked workers are scoped to one backend's
 * statement and torn down with it; a search slot set must survive across many
 * statements and transactions for as long as its owning process decides to
 * hold capacity, which a ParallelContext's per-statement resource-owner
 * lifetime cannot do.
 */
typedef struct SvsSlotSet SvsSlotSet;

/*
 * ctx must outlive the set.  libraryName names the .so holding
 * SvsParkedSlotMain, since that differs between the extension and a test module.
 *
 * Search-only for now: every slot this module registers reports itself with
 * SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH) and SvsFormatSearchSlotAppName.
 * SvsSlotKind has a BUILD member, but nothing here builds or tests a
 * BUILD-kind set, so there is deliberately no parameter to request one; a
 * caller that needs build-slot self-description should extend
 * SvsParkedSlotMain to branch on kind when that caller exists, not before.
 */
extern SvsSlotSet *SvsSlotSetCreate(MemoryContext ctx, const char *libraryName,
									 const char *datname);

/*
 * Converge on `target` live slots.  Returns the count actually held, which may be
 * less than target when the pool or the slot array is exhausted.  Never registers
 * past target; never terminates below it.
 *
 * Policy seam: this module only converges to whatever target it is given, and
 * has no opinion on when that target changes.  A later task decides whether
 * slots are held for a grant's lifetime (call SvsSlotSetResize once per grant
 * change, holding steady between calls) or acquired per search dispatch (call
 * it around each search, releasing immediately after).  Switching between
 * those policies is a change of when the caller calls this function, not a
 * change to this module.
 */
extern int	SvsSlotSetResize(SvsSlotSet *set, int target);

/* Terminate every slot.  Idempotent.  Safe on an exit path. */
extern void SvsSlotSetReleaseAll(SvsSlotSet *set);

/* Slots believed live, after reaping any that exited on their own. */
extern int	SvsSlotSetCount(SvsSlotSet *set);

/*
 * Looked up by name in the shared library at runtime (RegisterDynamicBackgroundWorker
 * records only the library and function name); default visibility is required
 * for that lookup to succeed under -fvisibility=hidden.  Mirrors the same
 * requirement documented on SvsParkedBuildWorkerMain in svs_parallel_build.h.
 */
extern PGDLLEXPORT void SvsParkedSlotMain(Datum main_arg);

#endif							/* SVS_CPU_SLOTS_H */
