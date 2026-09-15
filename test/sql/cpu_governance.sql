-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- CPU grant observability: pg_stat_vamana_worker's search_threads_desired,
-- search_threads_granted, search_threads_reserved, and
-- max_search_threads_per_db columns.  These only read values PublishCpuGrants
-- (src/vamanalauncher.c) already computes and writes on every reconcile;
-- nothing here changes how a grant is computed, published, or applied.

-- Enable this database and wait for its worker before any index work, so
-- this file runs standalone.  Idempotent and a no-op in the full suite,
-- where vamana_databases.sql (ordered first) has already warmed it.
INSERT INTO vamana_databases (datname, enabled) VALUES (current_database(), true)
	ON CONFLICT (datname) DO NOTHING;
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND worker_state = 'running';
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- Unconfigured default: search_num_threads NULL and svs.search_num_threads at
-- its compiled default (0 = auto) must resolve desired to 1, not
-- nproc-1/max_parallel_workers.  The regression config pins
-- svs.search_num_threads away from its compiled default for other tests, so
-- force it back to 0 here rather than trust whatever the harness configured,
-- then restore it once this assertion is taken.
ALTER SYSTEM SET svs.search_num_threads = 0;
SELECT pg_reload_conf();

UPDATE vamana_databases SET search_num_threads = NULL, search_threads_reserved = 0
	WHERE datname = current_database();

DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND search_threads_desired = 1;
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- ResolveOrFallback(searchNumThreadsDefault, 1) is the calculator's fallback
-- (src/svs_cpu_budget.c); this pins that behavior rather than nproc-1, which
-- is what an uninitialized or copy-pasted-from-elsewhere ceiling would look
-- like.
SELECT search_threads_desired, search_threads_reserved FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Restore the cluster default the regression config expects for every other
-- test file in this suite.
ALTER SYSTEM SET svs.search_num_threads = 8;
SELECT pg_reload_conf();

-- Columns reflect configuration: a per-database UPDATE, driven through
-- catalog DML so the vamana_databases_changed NOTIFY wakes the launcher
-- promptly rather than waiting out its three-minute naptime.
UPDATE vamana_databases SET search_num_threads = 6, search_threads_reserved = 2
	WHERE datname = current_database();

DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND search_threads_desired = 6;
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- desired and reserved are written unconditionally every reconcile, so they
-- are asserted exactly once desired has caught up to the new catalog value.
-- granted is only rewritten when it changes and is otherwise contention-
-- dependent, so it is asserted by shape, not by a racy literal: it can never
-- exceed the ask and, uncontended, can never fall below the honored floor.
SELECT search_threads_desired = 6 AS desired_ok,
	   search_threads_reserved = 2 AS reserved_ok,
	   search_threads_granted <= search_threads_desired AS granted_le_desired,
	   search_threads_granted >= search_threads_reserved AS granted_ge_reserved
	FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- search_slots_registered: the count of parked slots the worker actually
-- holds after SvsSlotSetResize(target = search_threads_granted).  With an
-- ample pool (the default here) registration always meets the grant, which
-- is the invariant a DBA reads this column for in the steady state. granted
-- is contention-dependent and may still be converging toward 6 (see the
-- comment above), so wait for it to settle before comparing registered
-- against it.
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND search_threads_granted = 6
			  AND search_slots_registered = 6;
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

SELECT search_slots_registered = search_threads_granted AS registered_matches_granted_steady_state
	FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Zero when not live, matching the grant columns' convention: a freshly
-- reserved database reports desired/granted/registered as 0, not NULL,
-- before its worker's first heartbeat has run. This is a narrow window (the
-- launcher has not yet reconciled the new row and the worker has not yet
-- started), so the row is read immediately after INSERT with no wait.
--
-- Cleanup must wait for the worker to actually reach 'running' and be torn
-- down with svs_teardown_database() before the row is deleted: a database
-- disabled or dropped while its reservation is still in 'starting' never
-- releases its shmem slot (confirmed by hand against a scratch cluster,
-- reproducible with or without this column and therefore pre-existing, not
-- introduced here), and svs.max_databases is a small fixed pool shared by
-- every regression file in this run.
-- The extension is created (and the database left with it installed but
-- unreserved) before the enabling INSERT below, not after: creating it
-- concurrently with the worker's own startup, in the same target database,
-- gave an intermittent leaked reservation by hand against a scratch
-- cluster. Extension setup and reservation are kept as two clearly
-- sequential phases instead.
SELECT current_database() AS this_db \gset

CREATE DATABASE cpu_governance_not_live;
\c cpu_governance_not_live
CREATE EXTENSION vector;
CREATE EXTENSION svs;
\c :this_db

INSERT INTO vamana_databases (datname, enabled) VALUES ('cpu_governance_not_live', true);
SELECT worker_state,
	   search_threads_desired,
	   search_threads_granted,
	   search_slots_registered
	FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'cpu_governance_not_live');

DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'cpu_governance_not_live')
			  AND worker_state = 'running';
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

\c cpu_governance_not_live
SELECT svs_teardown_database();
\c :this_db

DELETE FROM vamana_databases WHERE datname = 'cpu_governance_not_live';

DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'cpu_governance_not_live');
		EXIT WHEN NOT FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

DROP DATABASE cpu_governance_not_live;

-- A shortfall must be visible: search_slots_registered can fall below
-- search_threads_granted, and search_threads_granted must keep reporting the
-- launcher's number rather than being silently pulled down to match.
--
-- max_parallel_workers is PGC_USERSET and can be raised past the fixed-size
-- max_worker_processes slot array without a restart (max_worker_processes is
-- PGC_POSTMASTER). Raising max_parallel_workers here lets the launcher grant
-- a number of search threads that the shared slot array can never register
-- in full, since every background worker on the instance -- parallel or
-- not -- comes out of that same fixed array. This is a stable, permanent
-- shortfall (bounded by the fixed array), not a transient one that would
-- resolve itself given enough time to poll for.
--
-- No new database is created for this: the shortfall is driven entirely by
-- GUCs and this database's own search_num_threads, so there is no row to
-- leak if a DELETE ever raced a 'starting' worker.
SELECT (setting::int + 20) AS mwp_plus_20, (setting::int + 10) AS mwp_plus_10
	FROM pg_settings WHERE name = 'max_worker_processes' \gset

ALTER SYSTEM SET max_parallel_workers = :mwp_plus_20;
ALTER SYSTEM SET svs.max_search_threads_per_db = :mwp_plus_20;
SELECT pg_reload_conf();

UPDATE vamana_databases SET search_num_threads = :mwp_plus_10
	WHERE datname = current_database();

-- The target ask is stashed in a temp table rather than a psql variable:
-- psql does not interpolate :variables inside a dollar-quoted DO body, and
-- the poll loop below needs the value there.
CREATE TEMP TABLE cpu_governance_shortfall_target AS
	SELECT :mwp_plus_10 AS shortfall_target;

DO $$
DECLARE
	target int;
BEGIN
	SELECT shortfall_target INTO target FROM cpu_governance_shortfall_target;
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND search_threads_granted = target;
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

DROP TABLE cpu_governance_shortfall_target;

-- The grant is settled, but registration against it is not necessarily
-- done: the worker converges once per heartbeat (~1s) and each parked slot
-- it registers is a real background worker the postmaster must start, which
-- takes longer than that. Poll until search_slots_registered stops moving
-- between consecutive reads, rather than assuming a fixed number of
-- heartbeats is enough -- registering many slots for an oversized ask can
-- still be in flight seconds later.
DO $$
DECLARE
	prev int := -1;
	cur int;
BEGIN
	FOR i IN 1 .. 300 LOOP
		SELECT search_slots_registered INTO cur FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
		EXIT WHEN cur = prev;
		prev := cur;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

SELECT search_threads_desired = search_threads_granted AS grant_meets_the_oversized_ask,
	   search_slots_registered < search_threads_granted AS registration_falls_short_of_the_grant
	FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

ALTER SYSTEM RESET max_parallel_workers;
ALTER SYSTEM RESET svs.max_search_threads_per_db;
SELECT pg_reload_conf();
UPDATE vamana_databases SET search_num_threads = 6 WHERE datname = current_database();

-- Wait for the worker to fully unwind the oversized slot set it registered
-- above before moving on: SvsSlotSetResize tears down one parked slot at a
-- time, and letting later tests run while that teardown is still in flight
-- would contend with them for the same shared max_worker_processes array.
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())
			  AND search_threads_granted = 6
			  AND search_slots_registered = 6;
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- max_search_threads_per_db reports the resolved ceiling (it follows
-- max_parallel_workers when svs.max_search_threads_per_db is left at its
-- 0 = "follow" default), not the raw GUC value, since 0 the raw value would
-- tell a DBA nothing to compare a grant against.
SELECT (SELECT max_search_threads_per_db FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database()))
	   = (SELECT setting::int FROM pg_settings WHERE name = 'max_parallel_workers') AS ceiling_follows_max_parallel_workers;

-- The explicit override path: svs.max_search_threads_per_db is read directly
-- by the querying backend (vamanaworkerstats.c), not through the launcher, so
-- a session-level SET takes effect immediately with no reload needed, unlike
-- svs.search_num_threads above.
SET svs.max_search_threads_per_db = 4;
SELECT max_search_threads_per_db = 4 AS ceiling_reports_configured_value
	FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
RESET svs.max_search_threads_per_db;

-- Visibility gate: an unprivileged caller sees only its own database's row;
-- a pg_read_all_stats member sees every reserved database.  Reuses the
-- permanent 'postgres' database as the second live row instead of creating
-- and tearing down a throwaway database, since disabling a database's worker
-- releases its shmem slot asynchronously (a launcher reconcile, not this
-- UPDATE's commit) and this test has no need to wait on that.
INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true)
	ON CONFLICT (datname) DO UPDATE SET enabled = true;

DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- Two distinct databases now have a reserved row.
SELECT count(DISTINCT db_oid) >= 2 AS at_least_two_rows_exist FROM pg_stat_vamana_worker;

CREATE ROLE cpu_governance_unpriv NOLOGIN;
CREATE ROLE cpu_governance_privileged NOLOGIN;
GRANT pg_read_all_stats TO cpu_governance_privileged;

-- Unprivileged: sees exactly its own database's row, never the other one.
-- search_slots_registered is a column on that same row, so it inherits the
-- gate for free; read it here to confirm the added column carries no gate
-- of its own.
SET ROLE cpu_governance_unpriv;
SELECT count(DISTINCT db_oid) AS visible_rows,
	   bool_and(db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())) AS only_self,
	   bool_and(search_slots_registered IS NOT NULL) AS registered_readable
	FROM pg_stat_vamana_worker;
RESET ROLE;

-- pg_read_all_stats member: sees both.
SET ROLE cpu_governance_privileged;
SELECT count(DISTINCT db_oid) >= 2 AS sees_all_rows,
	   bool_and(search_slots_registered IS NOT NULL) AS registered_readable
	FROM pg_stat_vamana_worker;
RESET ROLE;

DROP ROLE cpu_governance_unpriv;
DROP ROLE cpu_governance_privileged;

-- Remove the 'postgres' row entirely: this file may run before
-- vamana_databases.sql (regression file order is alphabetical, not
-- suite-defined), and that file inserts its own fresh 'postgres' row,
-- which would collide with one left behind here.  The BEFORE DELETE guard
-- only rejects a database with live vamana indexes (none exist in
-- 'postgres'), so this succeeds regardless of whether the launcher has
-- released the shmem slot yet.
DELETE FROM vamana_databases WHERE datname = 'postgres';

-- Wait for the release to actually land before this file finishes: the
-- shortfall case above makes this file run visibly longer than it used to,
-- and vamana_databases.sql (which runs later in this suite) inserts its own
-- fresh 'postgres' row and expects a clean slate rather than a still-
-- releasing one from here.
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		EXIT WHEN NOT FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- Restore this database's own row to its pre-test configuration, so later
-- regression files that share contrib_regression don't inherit this file's
-- thread governance settings.
UPDATE vamana_databases SET search_num_threads = NULL, search_threads_reserved = 0
	WHERE datname = current_database();
