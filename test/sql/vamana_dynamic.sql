-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL

SET enable_seqscan = off;

-- Incremental INSERT: new rows are searchable without REINDEX or rebuild.
-- After CREATE INDEX the cache is warm and dynamic, so INSERT uses SVSAddPoints
-- and the subsequent SELECT finds the new rows without any rebuild NOTICEs.

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);

-- Insert a single row and verify it appears in results (no rebuild expected)
INSERT INTO t (val) VALUES ('[3,3,3]');
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id LIMIT 3;

-- Insert multiple rows and verify all are searchable
INSERT INTO t (val) VALUES ('[4,4,4]'), ('[5,5,5]');
SELECT * FROM t ORDER BY val <-> '[5,5,5]', id LIMIT 3;

DROP TABLE t;

-- Incremental INSERT with inner product distance
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[1,0,0]'), ('[0,1,0]'), ('[0,0,1]');
CREATE INDEX ON t USING vamana (val vector_ip_ops);

INSERT INTO t (val) VALUES ('[1,1,1]');
SELECT * FROM t ORDER BY val <#> '[1,1,1]', id LIMIT 2;

DROP TABLE t;

-- Incremental INSERT with cosine distance
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[1,0,0]'), ('[0,1,0]'), ('[0,0,1]');
CREATE INDEX ON t USING vamana (val vector_cosine_ops);

INSERT INTO t (val) VALUES ('[1,1,0]');
SELECT * FROM t ORDER BY val <=> '[1,1,0]', id LIMIT 2;

DROP TABLE t;

-- DELETE + VACUUM: deleted rows removed from dynamic index via SVSDeletePoints
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]'), ('[4,4,4]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);

-- Warm the cache with a query
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id LIMIT 1;

-- Delete two rows and vacuum
DELETE FROM t WHERE id IN (2, 4);
VACUUM t;

-- Deleted rows should not appear in results
SELECT * FROM t ORDER BY val <-> '[1,1,1]', id;

DROP TABLE t;

-- Mixed incremental INSERT + DELETE + VACUUM cycle
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);

-- Incremental insert
INSERT INTO t (val) VALUES ('[3,3,3]'), ('[4,4,4]');

-- Verify new rows present
SELECT * FROM t ORDER BY val <-> '[4,4,4]', id LIMIT 3;

-- Delete some rows and vacuum
DELETE FROM t WHERE id IN (1, 3);
VACUUM t;

-- Verify only surviving rows returned
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;

DROP TABLE t;

-- REINDEX after incremental inserts produces a fresh dynamic index
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]');
CREATE INDEX idx_reindex ON t USING vamana (val vector_l2_ops);

INSERT INTO t (val) VALUES ('[2,2,2]'), ('[3,3,3]');
REINDEX INDEX idx_reindex;
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id LIMIT 2;

DROP TABLE t;

-- svs.compact_threshold_pct: compact on every VACUUM with pending deletes
SET svs.compact_threshold_pct = 0;
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]'), ('[4,4,4]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id LIMIT 1;
DELETE FROM t WHERE id = 3;
VACUUM t;
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id LIMIT 3;
DROP TABLE t;
RESET svs.compact_threshold_pct;

-- svs.compact_threshold_pct: 100 disables compact (consolidate still runs)
SET svs.compact_threshold_pct = 100;
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]'), ('[4,4,4]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id LIMIT 1;
DELETE FROM t WHERE id IN (2, 3, 4);
VACUUM t;
SELECT * FROM t ORDER BY val <-> '[0,0,0]', id;
DROP TABLE t;
RESET svs.compact_threshold_pct;

-- svs.compact_threshold_pct: out-of-range values rejected
SET svs.compact_threshold_pct = -1;
SET svs.compact_threshold_pct = 101;
SHOW svs.compact_threshold_pct;

-- -------------------------------------------------------------------------
-- Transactional rollback (undo-on-abort)
-- -------------------------------------------------------------------------

-- INSERT + ROLLBACK: rolled-back vector must not appear in search results.
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
BEGIN;
INSERT INTO t (val) VALUES ('[9,9,9]');
ROLLBACK;
-- [9,9,9] must not appear; only the original 3 rows
SELECT * FROM t ORDER BY val <-> '[9,9,9]', id LIMIT 3;
DROP TABLE t;

-- INSERT + COMMIT: committed vector must appear in search results.
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
BEGIN;
INSERT INTO t (val) VALUES ('[9,9,9]');
COMMIT;
-- [9,9,9] must appear
SELECT * FROM t ORDER BY val <-> '[9,9,9]', id LIMIT 2;
DROP TABLE t;

-- SAVEPOINT: only the sub-transaction's insert is undone on ROLLBACK TO.
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val vector_l2_ops);
BEGIN;
INSERT INTO t (val) VALUES ('[5,5,5]');
SAVEPOINT sp1;
INSERT INTO t (val) VALUES ('[9,9,9]');
ROLLBACK TO sp1;
COMMIT;
-- [5,5,5] must appear, [9,9,9] must not
SELECT * FROM t ORDER BY val <-> '[9,9,9]', id LIMIT 3;
DROP TABLE t;

-- -------------------------------------------------------------------------
-- Test A: Large DELETE batch (>1000 rows) exercises VAMANA_MAX_DELETE_IDS
-- batching loop in vamanabulkdelete.
-- -------------------------------------------------------------------------
CREATE TABLE t_large (id serial PRIMARY KEY, val vector(3));
INSERT INTO t_large (val) SELECT ARRAY[random(), random(), random()]::vector(3)
    FROM generate_series(1, 1500);
CREATE INDEX ON t_large USING vamana (val vector_l2_ops);

-- Warm the cache
SELECT count(*) FROM (SELECT * FROM t_large ORDER BY val <-> '[0.5,0.5,0.5]' LIMIT 1) sub;

-- Delete more than 1000 rows to force multiple batches
DELETE FROM t_large WHERE id <= 1200;
VACUUM t_large;

-- Only 300 rows should remain
SELECT count(*) FROM (SELECT * FROM t_large ORDER BY val <-> '[0.5,0.5,0.5]' LIMIT 1500) sub;
DROP TABLE t_large;

-- -------------------------------------------------------------------------
-- Test B: Large ROLLBACK (>1000 inserts) exercises batched undo path.
-- -------------------------------------------------------------------------
CREATE TABLE t_undo (id serial PRIMARY KEY, val vector(3));
INSERT INTO t_undo (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t_undo USING vamana (val vector_l2_ops);

BEGIN;
INSERT INTO t_undo (val) SELECT ARRAY[random(), random(), random()]::vector(3)
    FROM generate_series(1, 1500);
ROLLBACK;

-- Only the original 3 rows should be searchable
SELECT count(*) FROM (SELECT * FROM t_undo ORDER BY val <-> '[0,0,0]' LIMIT 2000) sub;
DROP TABLE t_undo;

-- -------------------------------------------------------------------------
-- #92: TRUNCATE must not leave stale cache — post-TRUNCATE query returns empty.
-- -------------------------------------------------------------------------
CREATE TABLE t_trunc (id serial PRIMARY KEY, val vector(3));
INSERT INTO t_trunc (val) VALUES ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t_trunc USING vamana (val vector_l2_ops);

-- Warm the cache
SELECT count(*) FROM (SELECT * FROM t_trunc ORDER BY val <-> '[1,1,1]' LIMIT 10) sub;

TRUNCATE t_trunc;

-- After TRUNCATE the index is empty; query must return 0 rows.
SELECT count(*) FROM (SELECT * FROM t_trunc ORDER BY val <-> '[1,1,1]' LIMIT 10) sub;

DROP TABLE t_trunc;

-- -------------------------------------------------------------------------
-- #42: SVSLoadDynamicIndex build-window fallback must match build-time logic.
-- When build_window_size is unset (0) and search_window_size is non-zero,
-- the load path must use graph_degree*2, not search_window_size.
-- -------------------------------------------------------------------------
CREATE TABLE t_loadwin (id serial PRIMARY KEY, val vector(3));
INSERT INTO t_loadwin (val) VALUES ('[1,0,0]'), ('[0,1,0]'), ('[0,0,1]'), ('[1,1,0]'), ('[0,1,1]');
CREATE INDEX ON t_loadwin USING vamana (val vector_l2_ops) WITH (search_window_size = 20);

-- Warm cache and verify initial results.
SELECT count(*) FROM (SELECT * FROM t_loadwin ORDER BY val <-> '[1,0,0]' LIMIT 5) sub;

-- REINDEX forces a cold reload through SVSLoadDynamicIndex.
REINDEX INDEX CONCURRENTLY t_loadwin_val_idx;

-- Results must be unchanged after reload.
SELECT count(*) FROM (SELECT * FROM t_loadwin ORDER BY val <-> '[1,0,0]' LIMIT 5) sub;

DROP TABLE t_loadwin;
