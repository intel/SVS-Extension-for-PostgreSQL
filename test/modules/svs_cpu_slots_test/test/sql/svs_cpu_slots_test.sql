CREATE EXTENSION svs_cpu_slots_test;

-- Case 1: launch and park.  Four slots register with raw
-- RegisterDynamicBackgroundWorker, attach, and are independently visible in
-- pg_stat_activity under this module's bgw_type -- all verified from a
-- second query in the same session, not from inside the registering call.
--
-- WaitForBackgroundWorkerStartup(), which svs_slot_resize() already blocks
-- on internally, only confirms the postmaster has forked the process and
-- assigned it a pid; it says nothing about whether that process has yet
-- reached its own pgstat_beinit()/pgstat_bestart_final() calls and become
-- visible in pg_stat_activity, so the pg_sleep() below gives that a moment
-- to happen before checking.  It has to be a separate top-level statement,
-- not a poll loop inside one PL/pgSQL call: pg_stat_get_activity() snapshots
-- backend status once per transaction and reuses that snapshot for the rest
-- of it, so pg_sleep()-and-recheck inside a single function call (a single
-- transaction) sees the same stale count every time no matter how long it
-- sleeps.  A fresh top-level statement gets a fresh transaction and a fresh
-- snapshot.
SELECT svs_slot_resize(4) AS held;

SELECT pg_sleep(1);

SELECT count(*) = 4 AS four_slots_visible
FROM pg_stat_activity
WHERE backend_type = svs_slot_bgw_type();

-- A parked slot has no BGWORKER_BACKEND_DATABASE_CONNECTION, so it never
-- calls InitPostgres and is never added to ProcArray.  pg_stat_activity's
-- wait_event columns are read from PGPROC via BackendPidGetProc(), so they
-- are always NULL for a slot like this -- unpopulated, not populated-and-
-- changing.  "Stable" here can only be checked as stably NULL across two
-- samples; that is a limitation of skipping InitPostgres, not evidence the
-- park loop is spinning instead of blocked in WaitLatch.
SELECT bool_and(wait_event_type IS NULL AND wait_event IS NULL) AS wait_event_unavailable_sample_1
FROM pg_stat_activity
WHERE backend_type = svs_slot_bgw_type();

SELECT pg_sleep(0.2);

SELECT bool_and(wait_event_type IS NULL AND wait_event IS NULL) AS wait_event_unavailable_sample_2
FROM pg_stat_activity
WHERE backend_type = svs_slot_bgw_type();

-- Case 1b: resizing to the already-held count is a no-op -- it must not
-- terminate and re-register the whole set just to land on the same total.
CREATE TEMP TABLE svs_slot_pids_before AS
SELECT pid FROM pg_stat_activity WHERE backend_type = svs_slot_bgw_type();

SELECT svs_slot_resize(4) AS held_at_same_target;

SELECT (SELECT array_agg(pid ORDER BY pid) FROM svs_slot_pids_before)
     = (SELECT array_agg(pid ORDER BY pid) FROM pg_stat_activity
        WHERE backend_type = svs_slot_bgw_type())
  AS pids_unchanged_on_noop_resize;

DROP TABLE svs_slot_pids_before;

-- Case 2: pool enforcement.  max_parallel_workers is PGC_USERSET, so this
-- session can clamp the pool without a restart.
SET max_parallel_workers = 4;

-- Already holding 4 of a 4-worker pool; requesting 8 more must still hold
-- only 4, not register past the pool.
SELECT svs_slot_resize(8) AS held_when_over_pool;

-- A concurrent core parallel query getting zero workers proves these slots
-- occupy the same shared parallel_register_count/parallel_terminate_count
-- pool a real Gather uses, not some private counter of this module's own.
CREATE TABLE svs_slot_probe AS SELECT g FROM generate_series(1, 200000) g;
ANALYZE svs_slot_probe;

SET min_parallel_table_scan_size = 0;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET max_parallel_workers_per_gather = 2;

-- Runs the query for real and pulls "Workers Launched: N" out of the EXPLAIN
-- ANALYZE plan, so the test result is a plain integer rather than a whole
-- plan's worth of non-deterministic timing and buffer-usage text.
CREATE FUNCTION svs_slot_probe_workers_launched() RETURNS int AS $$
DECLARE
	plan_line text;
	launched int := 0;
BEGIN
	FOR plan_line IN EXPLAIN (ANALYZE, TIMING OFF, COSTS OFF, SUMMARY OFF)
		SELECT count(*) FROM svs_slot_probe
	LOOP
		IF plan_line LIKE '%Workers Launched:%' THEN
			launched := substring(plan_line FROM 'Workers Launched: (\d+)')::int;
		END IF;
	END LOOP;
	RETURN launched;
END;
$$ LANGUAGE plpgsql;

SELECT svs_slot_probe_workers_launched() AS workers_launched_while_pool_full;

-- Case 3: slot return.  Releasing all slots must free the pool units back
-- to the same counter, or a concurrent parallel query would stay starved
-- forever; this is the parallel_terminate_count decrement source reading
-- alone cannot prove.
SELECT svs_slot_release_all();

SELECT svs_slot_count() AS held_after_release;

SELECT svs_slot_probe_workers_launched() > 0 AS regains_workers_after_release;

DROP FUNCTION svs_slot_probe_workers_launched();
DROP TABLE svs_slot_probe;
DROP EXTENSION svs_cpu_slots_test;
