-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- Table shape, including both triggers' declared firing conditions

\d vamana_databases
\d svs_index_residency

-- The row-level trigger resolves datname against pg_database, so every row
-- here must name a database that actually exists.
CREATE DATABASE vamana_databases_test_dbc;
CREATE DATABASE vamana_databases_test_dbd;
CREATE DATABASE vamana_databases_test_dbe;

-- A nonexistent database is rejected outright, before any row is queued.
INSERT INTO vamana_databases (datname) VALUES ('vamana_databases_test_missing');

-- INSERT/UPDATE/DELETE succeed; the row-level trigger is declared AFTER
-- INSERT OR UPDATE only, so DELETE below cannot invoke it.

INSERT INTO vamana_databases (datname)
	VALUES ('template1'), ('postgres'), ('vamana_databases_test_dbc');

-- Each of the three rows just inserted has residency_memory NULL, so each
-- resolves independently against svs.default_residency_memory (Group 1
-- item 3's synchronous admission already ran, in the same transaction as
-- the INSERT above). The default is not a single shared allowance one
-- database's admission consumes for the others: every one of the three is
-- admitted at the same, full default-derived budget.
SELECT count(DISTINCT residency_memory_limit) = 1 AS all_three_resolve_to_the_same_default,
       count(*) = 3 AS all_three_admitted
  FROM pg_stat_vamana_worker w
  JOIN pg_database d ON d.oid = w.db_oid
 WHERE d.datname IN ('template1', 'postgres', 'vamana_databases_test_dbc');

-- vamana_databases_test_dbc was CREATE DATABASE'd fresh at the top of this
-- file and nothing else in the suite can have touched it, so unlike
-- contrib_regression (the shared database every other regression file also
-- builds real indexes in) it is safe to assert the exact value here rather
-- than just NULL-vs-not: newly admitted, nothing loaded or built yet, so
-- committed/build/drift are all exactly zero, not merely non-NULL.
SELECT residency_bytes_committed = 0 AS committed_is_zero,
       build_bytes_committed = 0 AS build_is_zero,
       residency_drift = 0 AS drift_is_zero
  FROM pg_stat_vamana_worker
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'vamana_databases_test_dbc');

UPDATE vamana_databases SET enabled = false
	WHERE datname IN ('template1', 'postgres', 'vamana_databases_test_dbc');
DELETE FROM vamana_databases WHERE datname = 'template1';

-- Placeholder columns accept NULL and non-NULL values

INSERT INTO vamana_databases (datname) VALUES ('vamana_databases_test_dbd');
INSERT INTO vamana_databases (datname, graph_memory_mb, residency_memory, search_work_mem, search_num_threads)
	VALUES ('vamana_databases_test_dbe', 512, 4096, 2048, 8);
-- Scoped to the rows this test created: other regression files may have
-- already self-enrolled their own database (e.g. contrib_regression) by the
-- time this file runs, and this assertion must not depend on run order.
SELECT datname, graph_memory_mb, residency_memory, search_work_mem, search_num_threads
	FROM vamana_databases
	WHERE datname IN ('postgres', 'vamana_databases_test_dbc',
					   'vamana_databases_test_dbd', 'vamana_databases_test_dbe')
	ORDER BY datname;

-- residency_memory and search_work_mem each reject zero and negative values,
-- symmetric with every other placeholder column's CHECK (> 0).
INSERT INTO vamana_databases (datname, residency_memory) VALUES ('vamana_databases_test_dbd', 0);
INSERT INTO vamana_databases (datname, residency_memory) VALUES ('vamana_databases_test_dbd', -1);
INSERT INTO vamana_databases (datname, search_work_mem) VALUES ('vamana_databases_test_dbd', 0);
INSERT INTO vamana_databases (datname, search_work_mem) VALUES ('vamana_databases_test_dbd', -1);

-- A residency_memory override that alone exceeds svs.max_residency_memory is
-- rejected in the enrolling transaction itself (Group 1 item 3), not at some
-- later load: the INSERT never commits, so the row never exists to load
-- against. 2 TB is larger than any sane cluster-wide ceiling, so this holds
-- regardless of how the ceiling GUC happens to be tuned in this environment.
-- template1 rather than dbd: dbd already has a row (above), and this must
-- be a fresh enrollment, not an UPDATE on an existing one; template1's own
-- earlier row was deleted, but the database itself still exists.
--
-- The error's DETAIL line names the live global committed sum, which
-- depends on whatever else this regression run has already admitted
-- elsewhere in the suite -- terse verbosity keeps this assertion
-- deterministic by dropping that line, leaving only the primary message
-- (fixed: template1's OID and this statement's own 2 TB request never
-- change).
\set VERBOSITY terse
INSERT INTO vamana_databases (datname, residency_memory)
	VALUES ('template1', 2 * 1024 * 1024);
\set VERBOSITY default
SELECT count(*) = 0 AS oversized_override_never_committed
	FROM vamana_databases WHERE datname = 'template1';

-- total_memory_mb no longer exists: the residency/build axis split (design
-- doc Section 5.3) dissolved the combined cap.
SELECT total_memory_mb FROM vamana_databases LIMIT 0;

-- INSERT/UPDATE/DELETE/TRUNCATE are all revoked from PUBLIC; the table owner
-- retains them

CREATE ROLE vamana_databases_test_nonowner NOLOGIN;
SET ROLE vamana_databases_test_nonowner;
INSERT INTO vamana_databases (datname) VALUES ('postgres');
UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';
DELETE FROM vamana_databases WHERE datname = 'postgres';
TRUNCATE vamana_databases;
RESET ROLE;
DROP ROLE vamana_databases_test_nonowner;

TRUNCATE vamana_databases;
SELECT count(*) FROM vamana_databases;

DROP DATABASE vamana_databases_test_dbc;
DROP DATABASE vamana_databases_test_dbd;
DROP DATABASE vamana_databases_test_dbe;

-- Enabling a database from a savepoint that is released into its parent,
-- then discarded by rolling back that parent, must reserve no worker slot.
-- The reservation happens at PRE_COMMIT of the whole transaction, so a
-- leaked entry would show up immediately, before COMMIT returns.
CREATE DATABASE vamana_databases_test_leak;
BEGIN;
SAVEPOINT outer_sp;
SAVEPOINT inner_sp;
INSERT INTO vamana_databases (datname, enabled) VALUES ('vamana_databases_test_leak', true);
RELEASE SAVEPOINT inner_sp;
ROLLBACK TO SAVEPOINT outer_sp;
COMMIT;
SELECT count(*) FROM vamana_databases WHERE datname = 'vamana_databases_test_leak';
SELECT count(*) FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'vamana_databases_test_leak');
DROP DATABASE vamana_databases_test_leak;

-- Enable this database for the remaining regression files, which share this
-- one contrib_regression database and build vamana indexes.  The launcher
-- reserves the slot at COMMIT and spawns the worker; the first search then
-- waits for it via VamanaWorkerWaitUntilAvailable.
INSERT INTO vamana_databases (datname, enabled) VALUES ('contrib_regression', true);

-- New memory-accounting stats columns: shape, zero-vs-NULL, and visibility.
-- The enrolling INSERT above already admitted this database into the
-- accounting module synchronously, in the same transaction (Group 1 item
-- 3), so residency_bytes_committed/build_bytes_committed read 0, not NULL
-- -- nothing has loaded into *this admission* yet, but "admitted at zero"
-- and "never admitted" are different states. (The exact-zero case,
-- including residency_drift, is proven above against
-- vamana_databases_test_dbc, a database nothing else in the suite can have
-- touched; contrib_regression is the one database every other regression
-- file also builds real indexes in, so residency_drift here can be
-- nonzero if this file runs after them in the same regression run -- it
-- reflects a durable row not yet reconciled by a fresh reload, not a bug.)
SELECT residency_bytes_committed = 0 AS committed_is_zero,
       build_bytes_committed = 0 AS build_is_zero,
       residency_drift IS NOT NULL AS drift_is_not_null,
       search_scratch_bytes_in_flight
  FROM pg_stat_vamana_worker
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- The slot-grain column exists and reads NULL until something computes it.
SELECT DISTINCT search_scratch_bytes_per_query IS NULL AS unset_before_any_search
  FROM pg_stat_vamana_worker_slot
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- An unprivileged role reads these columns for its own row only, the same
-- visibility rule as every other pg_stat_vamana_worker column. Enabling a
-- second database gives a real foreign row to check the unprivileged role
-- cannot see, not just a NULL one indistinguishable from "nothing admitted".
--
-- postgres's row from the earlier INSERT/UPDATE/TRUNCATE dance above is
-- long gone (TRUNCATE emptied the whole table), but the worker slot that
-- enrollment reserved is released only on the launcher's own async
-- reconcile, not synchronously with the TRUNCATE. Wait for that stale slot
-- to actually clear first, so the row this block finds below is the fresh
-- one it creates here, never a leftover from before -- otherwise this
-- check's result depends on how much wall-clock time happened to pass
-- since the TRUNCATE, not on anything this block itself does.
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		EXIT WHEN NOT FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

INSERT INTO vamana_databases (datname, enabled) VALUES ('postgres', true);
DO $$
BEGIN
	FOR i IN 1 .. 300 LOOP
		PERFORM 1 FROM pg_stat_vamana_worker
			WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
		EXIT WHEN FOUND;
		PERFORM pg_sleep(0.1);
	END LOOP;
END $$;

-- Confirm the foreign row actually exists as superuser first, so the
-- unprivileged role's zero-row result below proves visibility is denied
-- rather than proving the row never showed up.
SELECT count(*) = 1 AS foreign_row_exists_for_superuser
  FROM pg_stat_vamana_worker
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');

-- residency_drift as a boolean, not a raw value, for the same reason as the
-- earlier check on this same database: contrib_regression's drift can be
-- nonzero depending on what the rest of the suite already built here.
CREATE ROLE vamana_databases_test_stats_reader NOLOGIN;
SET ROLE vamana_databases_test_stats_reader;
SELECT residency_bytes_committed, build_bytes_committed,
       residency_drift IS NOT NULL AS drift_is_not_null,
       search_scratch_bytes_in_flight
  FROM pg_stat_vamana_worker
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
SELECT count(*) = 0 AS foreign_row_not_visible
  FROM pg_stat_vamana_worker
 WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = 'postgres');
RESET ROLE;
DROP ROLE vamana_databases_test_stats_reader;

UPDATE vamana_databases SET enabled = false WHERE datname = 'postgres';

-- Live-index counter is commit-accurate.  The BEFORE DELETE guard reads
-- indexCount as a hard gate, so it must equal committed catalog truth and
-- must not reflect a rolled-back CREATE/DROP INDEX.  pg_stat_vamana_worker is
-- cross-database, so each query filters to this database's slot; index_count is
-- uniform across a database's slots, so SELECT DISTINCT then yields one row.

CREATE TABLE vamana_counter_t (id serial PRIMARY KEY, val vector(3));
INSERT INTO vamana_counter_t (val) VALUES ('[0,0,0]'), ('[1,1,1]');
SET client_min_messages = error;

-- Counter tracks a committed CREATE then DROP.
CREATE INDEX vamana_counter_i ON vamana_counter_t USING vamana (val vector_l2_ops);
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
DROP INDEX vamana_counter_i;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Aborted DROP does not under-count: the index is back, the count still reflects it.
CREATE INDEX vamana_counter_i ON vamana_counter_t USING vamana (val vector_l2_ops);
BEGIN;
DROP INDEX vamana_counter_i;
ROLLBACK;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Aborted CREATE does not over-count.
BEGIN;
CREATE INDEX vamana_counter_i2 ON vamana_counter_t USING vamana (val vector_l2_ops);
ROLLBACK;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- ROLLBACK TO SAVEPOINT discards only that subtransaction's delta.
BEGIN;
SAVEPOINT sp;
DROP INDEX vamana_counter_i;
ROLLBACK TO SAVEPOINT sp;
COMMIT;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- A released savepoint's delta commits exactly once.
BEGIN;
SAVEPOINT sp;
DROP INDEX vamana_counter_i;
RELEASE SAVEPOINT sp;
COMMIT;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- A savepoint released into its parent, then discarded by a rollback to an
-- earlier ancestor, must not commit its delta. Nothing new exists after
-- COMMIT, so the count must stay at 0.
BEGIN;
SAVEPOINT outer_sp;
SAVEPOINT inner_sp;
CREATE INDEX vamana_counter_nested ON vamana_counter_t USING vamana (val vector_l2_ops);
RELEASE SAVEPOINT inner_sp;
ROLLBACK TO SAVEPOINT outer_sp;
COMMIT;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

-- Counter moves only on CREATE/DROP, never on a bare rebuild.  REINDEX and
-- TRUNCATE both re-run the build with no create or drop, and REINDEX
-- CONCURRENTLY builds a transient index then drops the old one; none may shift
-- the count.  It must equal committed catalog truth for the BEFORE DELETE guard.
CREATE INDEX vamana_counter_i ON vamana_counter_t USING vamana (val vector_l2_ops);
REINDEX INDEX vamana_counter_i;
TRUNCATE vamana_counter_t;
REINDEX INDEX CONCURRENTLY vamana_counter_i;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
DROP INDEX vamana_counter_i;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());

RESET client_min_messages;
DROP TABLE vamana_counter_t;

-- svs_teardown_database() drops every vamana index the caller owns, reporting
-- one row per index.  A count of live vamana indexes in this database, so the
-- teardown cases can assert against "nothing left" without ordering assumptions.
CREATE VIEW vamana_live_indexes AS
	SELECT count(*) AS n
	FROM pg_class c JOIN pg_am a ON a.oid = c.relam
	WHERE a.amname = 'vamana' AND c.relkind = 'i';

CREATE TABLE vamana_td_a (id int, val vector(3));
CREATE TABLE vamana_td_b (id int, val vector(3));
INSERT INTO vamana_td_a VALUES (1, '[1,1,1]');
INSERT INTO vamana_td_b VALUES (1, '[1,1,1]');
SET client_min_messages = error;
CREATE INDEX vamana_td_ia ON vamana_td_a USING vamana (val vector_l2_ops);
CREATE INDEX vamana_td_ib ON vamana_td_b USING vamana (val vector_l2_ops);
RESET client_min_messages;

-- All indexes owned by the caller: each dropped, no reason, nothing left.
SELECT index_name, dropped, reason FROM svs_teardown_database() ORDER BY index_name;
SELECT n FROM vamana_live_indexes;

-- Mixed ownership: the caller owns only some indexes.  Owned indexes drop;
-- unowned ones report dropped=false with the ownership error, and the call
-- continues rather than aborting on the first failure — which also proves the
-- function is not SECURITY DEFINER (drops run with the caller's privileges).
-- The caller owns one of the two indexes, so a caught error and a successful
-- drop both occur in one call: the surviving-unowned + dropped-owned result
-- proves the loop recovered memory context and resource owner after the
-- subtransaction rollback and continued.
CREATE ROLE vamana_td_other;
CREATE ROLE vamana_td_caller;
CREATE TABLE vamana_td_c (id int, val vector(3));
CREATE TABLE vamana_td_d (id int, val vector(3));
INSERT INTO vamana_td_c VALUES (1, '[1,1,1]');
INSERT INTO vamana_td_d VALUES (1, '[1,1,1]');
SET client_min_messages = error;
CREATE INDEX vamana_td_ic ON vamana_td_c USING vamana (val vector_l2_ops);
CREATE INDEX vamana_td_id ON vamana_td_d USING vamana (val vector_l2_ops);
RESET client_min_messages;
ALTER TABLE vamana_td_c OWNER TO vamana_td_other;
ALTER TABLE vamana_td_d OWNER TO vamana_td_caller;

SET ROLE vamana_td_caller;
SELECT index_name, dropped, reason FROM svs_teardown_database() ORDER BY index_name;
RESET ROLE;

-- The owned index is gone; the unowned one survives.
SELECT n FROM vamana_live_indexes;
DROP TABLE vamana_td_c;			-- removes the surviving unowned index
DROP TABLE vamana_td_a, vamana_td_b, vamana_td_d;
DROP ROLE vamana_td_other, vamana_td_caller;

-- Already-clean database: teardown returns zero rows without error.
SELECT * FROM svs_teardown_database();

-- svs_warmup_index/svs_warmup_database gate on SELECT on the index's table
-- (same policy as pg_prewarm): warming only makes the index resident, no more
-- sensitive than reading it.  Contrast svs_teardown_database above, which gates
-- on ownership because it drops.
CREATE ROLE vamana_warm_reader;
CREATE TABLE vamana_warm_a (id int, val vector(3));
CREATE TABLE vamana_warm_b (id int, val vector(3));
INSERT INTO vamana_warm_a VALUES (1, '[1,1,1]');
INSERT INTO vamana_warm_b VALUES (1, '[1,1,1]');
SET client_min_messages = error;
CREATE INDEX vamana_warm_ia ON vamana_warm_a USING vamana (val vector_l2_ops);
CREATE INDEX vamana_warm_ib ON vamana_warm_b USING vamana (val vector_l2_ops);
RESET client_min_messages;

-- The table owner may warm its index.
SELECT svs_warmup_index('vamana_warm_ia');

-- A role is granted SELECT on vamana_warm_a only: it may warm that index, but
-- warming vamana_warm_ib is denied, not silently skipped.
GRANT SELECT ON vamana_warm_a TO vamana_warm_reader;
SET ROLE vamana_warm_reader;
SELECT svs_warmup_index('vamana_warm_ia');
SELECT svs_warmup_index('vamana_warm_ib');
RESET ROLE;

-- svs_warmup_database warms exactly the vamana indexes the caller may read and
-- skips the rest silently, so the count equals the caller's readable count
-- however many exist: vamana_warm_reader reads vamana_warm_a but not _b.
SET ROLE vamana_warm_reader;
SELECT svs_warmup_database() =
	(SELECT count(*) FROM pg_index i
	   JOIN pg_class ic ON ic.oid = i.indexrelid
	   JOIN pg_am am ON am.oid = ic.relam
	  WHERE am.amname = 'vamana'
	    AND has_table_privilege(i.indrelid, 'SELECT')) AS warms_only_readable;
RESET ROLE;

DROP TABLE vamana_warm_a, vamana_warm_b;
DROP ROLE vamana_warm_reader;

-- BEFORE DELETE guard: a row cannot be removed while vamana indexes still
-- exist in its database, reading the committed index count from shmem.

CREATE TABLE vamana_gate_t (id int, val vector(3));
INSERT INTO vamana_gate_t VALUES (1, '[1,1,1]');
SET client_min_messages = error;
CREATE INDEX vamana_gate_i ON vamana_gate_t USING vamana (val vector_l2_ops);
RESET client_min_messages;

-- Rejected while the index exists; the row is untouched.
DELETE FROM vamana_databases WHERE datname = current_database();
SELECT count(*) FROM vamana_databases WHERE datname = current_database();

-- After teardown the count is zero, so the same DELETE is allowed.  Rolled
-- back to keep this database enabled for the remaining regression files.
SELECT dropped FROM svs_teardown_database();
SELECT DISTINCT index_count FROM pg_stat_vamana_worker
	WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
BEGIN;
DELETE FROM vamana_databases WHERE datname = current_database();
ROLLBACK;
DROP TABLE vamana_gate_t;

-- A row whose database was dropped without cleanup is deletable: the guard
-- tolerates the missing database and allows the DELETE.
CREATE DATABASE vamana_gate_gone;
INSERT INTO vamana_databases (datname, enabled) VALUES ('vamana_gate_gone', false);
DROP DATABASE vamana_gate_gone;
DELETE FROM vamana_databases WHERE datname = 'vamana_gate_gone';

DROP VIEW vamana_live_indexes;
