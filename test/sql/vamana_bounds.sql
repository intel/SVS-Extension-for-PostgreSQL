-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL
--
-- TC-01: GUC and reloption bounds regression tests
--
-- Asserts that every reloption and GUC enforces its declared bounds at the
-- compiled-in min/max values.  Each case tests either the exact boundary
-- (valid) or one step outside it (invalid).  These are the bounds from
-- vamana.h (VAMANA_MIN_*/VAMANA_MAX_*) and the DefineCustomIntVariable calls
-- in vamana.c.
--
-- Note: svs.search_num_threads non-superuser SET test lives in WI-155 (after
-- the GUC context is changed to PGC_SIGHUP; see O4 in the dev plan).

SET enable_seqscan = off;

-- -----------------------------------------------------------------------
-- graph_degree: [16, 256]
-- -----------------------------------------------------------------------

-- Exact minimum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 16);
DROP TABLE t;

-- Exact maximum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 256);
DROP TABLE t;

-- One below minimum is rejected (already tested in vamana_vector.sql, repeated
-- here for completeness of the TC-01 boundary suite)
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 15);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 257);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- alpha: [-1, 200]
-- -----------------------------------------------------------------------

-- -1 is the sentinel "use SVS default" and must be accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (alpha = -1);
DROP TABLE t;

-- Exact maximum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (alpha = 200);
DROP TABLE t;

-- One below minimum (-2) is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (alpha = -2);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (alpha = 201);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- build_window_size: [-1, 1000]
-- (-1 is the sentinel for 2 * graph_degree; 0 is accepted by the reloption
-- layer since min=-1, but the application treats it the same as -1)
-- -----------------------------------------------------------------------

-- Exact maximum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (build_window_size = 1000);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (build_window_size = 1001);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- search_window_size (reloption): [10, 10000]
-- -----------------------------------------------------------------------

-- Exact minimum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (search_window_size = 10);
DROP TABLE t;

-- Exact maximum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (search_window_size = 10000);
DROP TABLE t;

-- One below minimum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (search_window_size = 9);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (search_window_size = 10001);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- leanvec_dims: [-1, 2000]
-- -----------------------------------------------------------------------

-- Exact maximum is accepted (requires sufficient dimension; use dim=2000)
CREATE TABLE t (id serial PRIMARY KEY, val vector(2000));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, leanvec_dims = 2000);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(2000));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, leanvec_dims = 2001);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- compression_primary precision > compression_secondary cross-check
-- (8-bit primary with 4-bit secondary must be rejected)
-- -----------------------------------------------------------------------

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 4);
DROP TABLE t;

-- Valid: 4-bit primary with 8-bit secondary is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- svs.search_window_size GUC: [10, 10000]
-- -----------------------------------------------------------------------

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

-- -----------------------------------------------------------------------
-- svs.search_num_threads GUC: [0, 1024]
-- -----------------------------------------------------------------------

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

-- -----------------------------------------------------------------------
-- PGC_SIGHUP checkpoint GUCs (PR #143)
-- These are SIGHUP-only so session SET is always rejected; we verify that
-- the error message confirms the "requires restart or reload" semantics.
-- -----------------------------------------------------------------------

-- svs.checkpoint_debounce_window: [0, 86400] s
SET svs.checkpoint_debounce_window = 0;
SET svs.checkpoint_debounce_window = 86400;
SET svs.checkpoint_debounce_window = 86401;

-- svs.checkpoint_max_interval: [1, 86400] s
SET svs.checkpoint_max_interval = 1;
SET svs.checkpoint_max_interval = 86400;
SET svs.checkpoint_max_interval = 0;
SET svs.checkpoint_max_interval = 86401;

-- svs.checkpoint_min_ops: [0, INT_MAX]
SET svs.checkpoint_min_ops = 0;
SET svs.checkpoint_min_ops = 2147483647;
SET svs.checkpoint_min_ops = -1;

-- svs.max_slot_wal_size: [64, MAX_KILOBYTES] MB
SET svs.max_slot_wal_size = '64MB';
SET svs.max_slot_wal_size = '63MB';

-- svs.checkpoint_operations: [-1, INT_MAX]
SET svs.checkpoint_operations = -1;
SET svs.checkpoint_operations = 0;
SET svs.checkpoint_operations = 2147483647;
SET svs.checkpoint_operations = -2;

-- svs.checkpoint_interval: [-1, 86400] s
SET svs.checkpoint_interval = -1;
SET svs.checkpoint_interval = 86400;
SET svs.checkpoint_interval = -2;
SET svs.checkpoint_interval = 86401;
