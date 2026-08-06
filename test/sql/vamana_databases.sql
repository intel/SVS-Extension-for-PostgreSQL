-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- Table shape, including both triggers' declared firing conditions

\d vamana_databases

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
UPDATE vamana_databases SET enabled = false
	WHERE datname IN ('template1', 'postgres', 'vamana_databases_test_dbc');
DELETE FROM vamana_databases WHERE datname = 'template1';

-- Placeholder columns accept NULL and non-NULL values

INSERT INTO vamana_databases (datname) VALUES ('vamana_databases_test_dbd');
INSERT INTO vamana_databases (datname, graph_memory_mb, total_memory_mb, search_num_threads)
	VALUES ('vamana_databases_test_dbe', 512, 4096, 8);
SELECT datname, graph_memory_mb, total_memory_mb, search_num_threads
	FROM vamana_databases ORDER BY datname;

-- TRUNCATE is revoked from PUBLIC; the table owner retains it

CREATE ROLE vamana_databases_test_nonowner NOLOGIN;
SET ROLE vamana_databases_test_nonowner;
TRUNCATE vamana_databases;
RESET ROLE;
DROP ROLE vamana_databases_test_nonowner;

TRUNCATE vamana_databases;
SELECT count(*) FROM vamana_databases;

DROP DATABASE vamana_databases_test_dbc;
DROP DATABASE vamana_databases_test_dbd;
DROP DATABASE vamana_databases_test_dbe;

-- Enable this database for the remaining regression files, which share this
-- one contrib_regression database and build vamana indexes.  The launcher
-- reserves the slot at COMMIT and spawns the worker; the first search then
-- waits for it via VamanaWorkerWaitUntilAvailable.
INSERT INTO vamana_databases (datname, enabled) VALUES ('contrib_regression', true);

-- Live-index counter is commit-accurate.  The BEFORE DELETE guard reads
-- indexCount as a hard gate, so it must equal committed catalog truth and
-- must not reflect a rolled-back CREATE/DROP INDEX.  index_count is uniform
-- across a database's slots, so SELECT DISTINCT yields one row.

CREATE TABLE vamana_counter_t (id serial PRIMARY KEY, val vector(3));
INSERT INTO vamana_counter_t (val) VALUES ('[0,0,0]'), ('[1,1,1]');
SET client_min_messages = error;

-- Counter tracks a committed CREATE then DROP.
CREATE INDEX vamana_counter_i ON vamana_counter_t USING vamana (val vector_l2_ops);
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;
DROP INDEX vamana_counter_i;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;

-- Aborted DROP does not under-count: the index is back, the count still reflects it.
CREATE INDEX vamana_counter_i ON vamana_counter_t USING vamana (val vector_l2_ops);
BEGIN;
DROP INDEX vamana_counter_i;
ROLLBACK;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;

-- Aborted CREATE does not over-count.
BEGIN;
CREATE INDEX vamana_counter_i2 ON vamana_counter_t USING vamana (val vector_l2_ops);
ROLLBACK;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;

-- ROLLBACK TO SAVEPOINT discards only that subtransaction's delta.
BEGIN;
SAVEPOINT sp;
DROP INDEX vamana_counter_i;
ROLLBACK TO SAVEPOINT sp;
COMMIT;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;

-- A released savepoint's delta commits exactly once.
BEGIN;
SAVEPOINT sp;
DROP INDEX vamana_counter_i;
RELEASE SAVEPOINT sp;
COMMIT;
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;

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
SELECT DISTINCT index_count FROM pg_stat_vamana_worker;
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
