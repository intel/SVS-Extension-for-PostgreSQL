/*
 * Copyright (C) 2026 Intel Corporation
 * SPDX-License-Identifier: PostgreSQL
 */

/*
 * svs_cpu_slots_test.c
 *
 * SQL-callable driver for svs_cpu_slots.c, exercised standalone in
 * test/sql/svs_cpu_slots_test.sql with no launcher or svs extension
 * involved.
 *
 * Unlike svs_parallel_build_test's launch/verify/stop-in-one-call pattern,
 * a slot set here is deliberately kept alive in TopMemoryContext across
 * statements and transactions within one backend: that is the entire
 * property under test.  A single lazily created set is reused by every call
 * in a session, so svs_slot_resize() run from one test.sql statement and
 * again from a later one converges the same live pool rather than starting a
 * fresh one each time.
 */

#include "postgres.h"

#include "svs_cpu_slots.h"

#include "commands/dbcommands.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "storage/ipc.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

PG_MODULE_MAGIC;

static SvsSlotSet *TestSlotSet = NULL;

/*
 * SvsSlotSetReleaseAll() is documented as "safe on an exit path," but
 * svs_cpu_slots.c does not hook itself to any exit path on its own -- that
 * is a caller decision, not something this module can assume for every
 * caller.  A caller that means to hold slots for a whole session, as this
 * test harness does, has to register its own release-on-exit so a clean
 * backend shutdown (SIGTERM, or any other ordinary proc_exit) does not
 * strand its slots the way an unclean crash necessarily does.  Without this,
 * every psql -c invocation that resized and disconnected without an explicit
 * svs_slot_release_all() call would leak its parked slots for the life of
 * the cluster; that leak was, in fact, first found in exactly that way while
 * manually driving this module before this hook was added.
 */
static void
ReleaseTestSlotSetOnExit(int code, Datum arg)
{
	if (TestSlotSet != NULL)
		SvsSlotSetReleaseAll(TestSlotSet);
}

/*
 * Created once per backend, in TopMemoryContext so it survives past the
 * calling statement and transaction; that persistence is what this whole
 * test module exists to exercise.
 */
static SvsSlotSet *
GetTestSlotSet(void)
{
	if (TestSlotSet == NULL)
	{
		TestSlotSet = SvsSlotSetCreate(TopMemoryContext,
										"svs_cpu_slots_test",
										SVS_SLOT_KIND_SEARCH,
										get_database_name(MyDatabaseId));
		before_shmem_exit(ReleaseTestSlotSetOnExit, 0);
	}
	return TestSlotSet;
}

PG_FUNCTION_INFO_V1(svs_slot_resize);

Datum
svs_slot_resize(PG_FUNCTION_ARGS)
{
	int32		target = PG_GETARG_INT32(0);
	int			held = SvsSlotSetResize(GetTestSlotSet(), target);

	PG_RETURN_INT32(held);
}

PG_FUNCTION_INFO_V1(svs_slot_count);

Datum
svs_slot_count(PG_FUNCTION_ARGS)
{
	PG_RETURN_INT32(SvsSlotSetCount(GetTestSlotSet()));
}

PG_FUNCTION_INFO_V1(svs_slot_release_all);

Datum
svs_slot_release_all(PG_FUNCTION_ARGS)
{
	SvsSlotSetReleaseAll(GetTestSlotSet());
	PG_RETURN_VOID();
}

/*
 * So test.sql can assert against pg_stat_activity.backend_type without
 * hardcoding the literal string svs_slot_naming.c happens to use today.
 */
PG_FUNCTION_INFO_V1(svs_slot_bgw_type);

Datum
svs_slot_bgw_type(PG_FUNCTION_ARGS)
{
	PG_RETURN_TEXT_P(cstring_to_text(SvsSlotKindBgwType(SVS_SLOT_KIND_SEARCH)));
}
