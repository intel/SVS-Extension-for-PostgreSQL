-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- Table shape, including both triggers' declared firing conditions

\d vamana_databases

-- INSERT/UPDATE/DELETE succeed; the row-level trigger is declared AFTER
-- INSERT OR UPDATE only, so DELETE below cannot invoke it.

INSERT INTO vamana_databases (datname) VALUES ('dbA'), ('dbB'), ('dbC');
UPDATE vamana_databases SET enabled = false WHERE datname IN ('dbA', 'dbB', 'dbC');
DELETE FROM vamana_databases WHERE datname = 'dbA';

-- Placeholder columns accept NULL and non-NULL values

INSERT INTO vamana_databases (datname) VALUES ('dbD');
INSERT INTO vamana_databases (datname, graph_memory_mb, total_memory_mb, search_num_threads)
	VALUES ('dbE', 512, 4096, 8);
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
