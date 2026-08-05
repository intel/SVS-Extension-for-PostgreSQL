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
