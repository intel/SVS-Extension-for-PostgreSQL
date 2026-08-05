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

-- -----------------------------------------------------------------------
-- graph_degree: [16, 256]
-- Enforced by add_int_reloption() in src/vamana.c
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
-- Enforced by add_int_reloption() in src/vamana.c
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
-- Enforced by add_int_reloption() in src/vamana.c
-- -----------------------------------------------------------------------

-- Exact minimum (-1 sentinel for 2 * graph_degree) is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (build_window_size = -1);
DROP TABLE t;

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
-- Enforced by add_int_reloption() in src/vamana.c
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
-- Enforced by add_int_reloption() in src/vamana.c
-- -----------------------------------------------------------------------

-- Exact minimum (-1 sentinel for SVS default) is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (leanvec_dims = -1);
DROP TABLE t;

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

-- One below minimum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (leanvec_dims = -2);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- build_window_size: below-minimum symmetry (same enforcement: add_int_reloption() in src/vamana.c)
-- -----------------------------------------------------------------------

-- One below minimum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (build_window_size = -2);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- compression_type: [0, 2]
-- Enforced by add_int_reloption() in src/vamana.c
-- -----------------------------------------------------------------------

-- Valid lower boundary (0 = none) is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_type = 0);
DROP TABLE t;

-- Valid upper boundary (2 = lvq) is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_type = 2);
DROP TABLE t;

-- One below minimum is rejected at reloption layer
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_type = -1);
DROP TABLE t;

-- One above maximum is rejected at reloption layer
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (compression_type = 3);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- compression_primary / compression_secondary valid set {+/-4, +/-8}
-- All cases set compression_type = 1 (LEANVEC) so ValidateCompressionParam runs.
-- Enforced by ValidateCompressionParam() in src/vamanabuild.c,
-- called inside the compression_type == LEANVEC gate in VamanaBuildIndex().
-- -----------------------------------------------------------------------

-- Invalid: value inside [-8,8] but not in {+-4,+-8} rejected (primary = 5)
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 5, compression_secondary = 8);
DROP TABLE t;

-- Invalid: secondary = 5, primary = 4 (valid) isolates the secondary failure
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 5);
DROP TABLE t;

-- Valid: each member of {+-4, +-8} accepted as equal-bit primary/secondary
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 4);
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -4, compression_secondary = -4);
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -8, compression_secondary = -8);
DROP TABLE t;

-- -----------------------------------------------------------------------
-- compression_primary precision > compression_secondary cross-check
-- (8-bit primary with 4-bit secondary must be rejected)
-- Enforced by primary_bits > secondary_bits check in ValidateCompressionParam() in src/vamanabuild.c
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
-- Enforced by DefineCustomIntVariable() in src/vamana.c
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
-- Enforced by DefineCustomIntVariable() in src/vamana.c
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

-- One below minimum is rejected
SET svs.search_num_threads = -1;

-- -----------------------------------------------------------------------
-- PGC_SIGHUP checkpoint GUCs (PR #143)
-- Session SET always returns "cannot be changed now" regardless of value,
-- so it never exercises range validation.  Use ALTER SYSTEM which validates
-- bounds at write time.
-- Enforced by DefineCustomIntVariable() in src/vamana.c
-- -----------------------------------------------------------------------

-- svs.checkpoint_debounce_window: [0, 86400] s -- DefineCustomIntVariable() in src/vamana.c

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

-- svs.checkpoint_max_interval: [1, 86400] s -- DefineCustomIntVariable() in src/vamana.c

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

-- svs.checkpoint_min_ops: [0, INT_MAX] -- DefineCustomIntVariable() in src/vamana.c

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

-- svs.max_slot_wal_size: [64, MAX_KILOBYTES] MB -- DefineCustomIntVariable() in src/vamana.c

-- Out-of-range (below min)
ALTER SYSTEM SET svs.max_slot_wal_size = '63MB';

-- Valid lower boundary
ALTER SYSTEM SET svs.max_slot_wal_size = '64MB';
SELECT pg_reload_conf();
SELECT pg_sleep(0.1);
SHOW svs.max_slot_wal_size;
ALTER SYSTEM RESET svs.max_slot_wal_size;
SELECT pg_reload_conf();

-- svs.checkpoint_operations: [-1, INT_MAX] -- DefineCustomIntVariable() in src/vamana.c

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

-- svs.checkpoint_interval: [-1, 86400] s -- DefineCustomIntVariable() in src/vamana.c

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
