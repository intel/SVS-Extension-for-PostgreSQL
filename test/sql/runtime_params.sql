-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

-- Enable this database and wait for its worker before any index work, so this
-- file runs standalone.  Enrollment reserves the slot synchronously (the gate
-- then passes), but the worker spawns asynchronously; the first INSERT would
-- otherwise race its cold start and time out.  Idempotent and a no-op in the
-- full suite, where vamana_databases.sql (ordered first) has already warmed it.
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

SET enable_seqscan = off;

SHOW svs.search_window_size;

-- compression invalid parameters

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_type = 3);
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_primary = 16);

DROP TABLE t;

-- search_window_size forwarding to SVS
-- Verify that the GUC value is actually forwarded to svs_index_search() at query
-- time.  Build a dataset large enough that search_window_size has a
-- meaningful effect, then query with the minimum and a large value and confirm
-- both return the expected nearest neighbors.

CREATE TABLE t (id int, val vector(3));
INSERT INTO t SELECT i, array_fill(i, ARRAY[3])::vector(3)
    FROM generate_series(1, 50) i;
CREATE INDEX ON t USING vamana (val vector_l2_ops);

-- Both should return non-empty results; COUNT must equal k.
SET svs.search_window_size = 10;
SELECT COUNT(*) FROM (SELECT id FROM t ORDER BY val <-> '[25,25,25]' LIMIT 5) sub;

SET svs.search_window_size = 500;
SELECT COUNT(*) FROM (SELECT id FROM t ORDER BY val <-> '[25,25,25]' LIMIT 5) sub;

-- Nearest neighbor should be id=25 at both extremes.
SET svs.search_window_size = 10;
SELECT id FROM t ORDER BY val <-> '[25,25,25]' LIMIT 1;

SET svs.search_window_size = 500;
SELECT id FROM t ORDER BY val <-> '[25,25,25]' LIMIT 1;

RESET svs.search_window_size;
DROP TABLE t;

-- max_parallel_maintenance_workers does not limit search
-- The build thread count (governed by this GUC) must be decoupled from the
-- search thread count.  Setting it to 1 must not prevent correct search results.
SET max_parallel_maintenance_workers = 1;
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;
RESET max_parallel_maintenance_workers;

-- svs.search_num_threads GUC controls search thread count
-- 0 = auto (nproc-1); explicit value overrides auto.
-- Correctness must be preserved regardless of thread count.
SET svs.search_num_threads = 1;
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
RESET svs.search_num_threads;
DROP TABLE t;

-- svs.search_window_size GUC bounds: [10, 10000]

-- Exact minimum is accepted
SET svs.search_window_size = 10;
SHOW svs.search_window_size;
RESET svs.search_window_size;

-- Exact maximum is accepted
SET svs.search_window_size = 10000;
SHOW svs.search_window_size;
RESET svs.search_window_size;

-- One below minimum is rejected
SET svs.search_window_size = 9;

-- One above maximum is rejected
SET svs.search_window_size = 10001;

-- svs.search_num_threads GUC bounds: [0, 1024]

-- Exact minimum is accepted
SET svs.search_num_threads = 0;
SHOW svs.search_num_threads;
RESET svs.search_num_threads;

-- Exact maximum is accepted
SET svs.search_num_threads = 1024;
SHOW svs.search_num_threads;
RESET svs.search_num_threads;

-- One above maximum is rejected
SET svs.search_num_threads = 1025;

-- One below minimum is rejected
SET svs.search_num_threads = -1;

-- Checkpoint GUCs are PGC_SIGHUP: SET always errors "cannot be changed now",
-- so bounds are exercised via ALTER SYSTEM instead.

-- svs.checkpoint_debounce_window: [0, 86400] s

-- Out-of-range: rejected at ALTER SYSTEM time
ALTER SYSTEM SET svs.checkpoint_debounce_window = -1;
ALTER SYSTEM SET svs.checkpoint_debounce_window = 86401;

-- Valid lower boundary
ALTER SYSTEM SET svs.checkpoint_debounce_window = 0;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_debounce_window;
ALTER SYSTEM RESET svs.checkpoint_debounce_window;
SELECT pg_reload_conf();

-- Valid upper boundary
ALTER SYSTEM SET svs.checkpoint_debounce_window = 86400;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_debounce_window;
ALTER SYSTEM RESET svs.checkpoint_debounce_window;
SELECT pg_reload_conf();

-- svs.checkpoint_max_interval: [1, 86400] s

-- Out-of-range
ALTER SYSTEM SET svs.checkpoint_max_interval = 0;
ALTER SYSTEM SET svs.checkpoint_max_interval = 86401;

-- Valid lower boundary
ALTER SYSTEM SET svs.checkpoint_max_interval = 1;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_max_interval;
ALTER SYSTEM RESET svs.checkpoint_max_interval;
SELECT pg_reload_conf();

-- Valid upper boundary
ALTER SYSTEM SET svs.checkpoint_max_interval = 86400;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_max_interval;
ALTER SYSTEM RESET svs.checkpoint_max_interval;
SELECT pg_reload_conf();

-- svs.checkpoint_min_ops: [0, INT_MAX]

-- Out-of-range (below min)
ALTER SYSTEM SET svs.checkpoint_min_ops = -1;

-- Valid lower boundary
ALTER SYSTEM SET svs.checkpoint_min_ops = 0;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_min_ops;
ALTER SYSTEM RESET svs.checkpoint_min_ops;
SELECT pg_reload_conf();

-- Valid upper boundary
ALTER SYSTEM SET svs.checkpoint_min_ops = 2147483647;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_min_ops;
ALTER SYSTEM RESET svs.checkpoint_min_ops;
SELECT pg_reload_conf();

-- svs.max_slot_wal_size: [64, MAX_KILOBYTES] MB

-- Out-of-range (below min)
ALTER SYSTEM SET svs.max_slot_wal_size = '63MB';

-- Valid lower boundary
ALTER SYSTEM SET svs.max_slot_wal_size = '64MB';
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.max_slot_wal_size;
ALTER SYSTEM RESET svs.max_slot_wal_size;
SELECT pg_reload_conf();

-- svs.checkpoint_operations: [-1, INT_MAX]

-- Out-of-range (below min)
ALTER SYSTEM SET svs.checkpoint_operations = -2;

-- Valid lower boundary
ALTER SYSTEM SET svs.checkpoint_operations = -1;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_operations;
ALTER SYSTEM RESET svs.checkpoint_operations;
SELECT pg_reload_conf();

-- Valid mid-range
ALTER SYSTEM SET svs.checkpoint_operations = 0;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_operations;
ALTER SYSTEM RESET svs.checkpoint_operations;
SELECT pg_reload_conf();

-- svs.checkpoint_interval: [-1, 86400] s

-- Out-of-range
ALTER SYSTEM SET svs.checkpoint_interval = -2;
ALTER SYSTEM SET svs.checkpoint_interval = 86401;

-- Valid lower boundary
ALTER SYSTEM SET svs.checkpoint_interval = -1;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_interval;
ALTER SYSTEM RESET svs.checkpoint_interval;
SELECT pg_reload_conf();

-- Valid upper boundary
ALTER SYSTEM SET svs.checkpoint_interval = 86400;
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.checkpoint_interval;
ALTER SYSTEM RESET svs.checkpoint_interval;
SELECT pg_reload_conf();
