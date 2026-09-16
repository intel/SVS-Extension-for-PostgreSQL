-- Copyright (C) 2026 Intel Corporation
-- SPDX-License-Identifier: PostgreSQL
--
-- Reloption bounds regression tests: every vamana index reloption enforces
-- its declared min/max, at the exact boundary and one step outside it.
-- GUC bounds live in runtime_params.sql.

-- graph_degree: [16, 256]

-- Exact minimum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 16);
DROP TABLE t;

-- Exact maximum is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 256);
DROP TABLE t;

-- One below minimum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 15);
DROP TABLE t;

-- One above maximum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (graph_degree = 257);
DROP TABLE t;

-- alpha: [-1, 200]

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

-- build_window_size: [-1, 1000]
-- -1 is the sentinel for 2 * graph_degree; 0 is accepted by the reloption
-- layer since min=-1, but the application treats it the same as -1.

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

-- One below minimum is rejected
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops) WITH (build_window_size = -2);
DROP TABLE t;

-- search_window_size (reloption): [10, 10000]

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

-- leanvec_dims: [-1, 2000]

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

-- compression_type: [0, 2]

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

-- compression_primary / compression_secondary valid set {+/-4, +/-8}
-- All cases set compression_type = 1 (LEANVEC) so the cross-check runs.

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

-- compression_primary precision > compression_secondary cross-check
-- (8-bit primary with 4-bit secondary must be rejected)

CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 4);
DROP TABLE t;

-- Valid: 4-bit primary with 8-bit secondary is accepted
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
DROP TABLE t;

-- compression_primary / compression_secondary reloption-layer boundary
-- Values outside [-8, 8] are rejected before the cross-check runs.

-- Invalid: outside reloption range (primary = 9)
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 9, compression_secondary = 8);
DROP TABLE t;

-- Invalid: outside reloption range (secondary = -9)
CREATE TABLE t (id serial PRIMARY KEY, val vector(3));
CREATE INDEX ON t USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = -9);
DROP TABLE t;

-- Compression combination matrix: every (compression_type, compression_primary,
-- compression_secondary) triple the reloption layer lets through, at every sign.
--
-- Validation runs in InitBuildState, ahead of the heap scan, so an empty table
-- exercises every combination: an accepted triple costs two NOTICEs and builds
-- nothing, a rejected one costs a single ERROR.  Each index is named after its
-- triple (pn8 = primary -8, s0 = secondary 0) so a failing diff names the
-- combination rather than an anonymous cmatrix_val_idx.  DROP INDEX IF EXISTS
-- runs after every case, so the "does not exist, skipping" NOTICE is itself
-- confirmation that the CREATE was rejected.

CREATE TABLE cmatrix (id serial PRIMARY KEY, val vector(3));

-- compression_type = 1 (LeanVec): {+-4, +-8} squared.  Accepted unless the
-- primary carries more precision than the secondary.  SVS discards the sign, but
-- validation does not, so both signs are exercised at both magnitudes.
CREATE INDEX leanvec_p4_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 4);
DROP INDEX IF EXISTS leanvec_p4_s4;
CREATE INDEX leanvec_p4_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = -4);
DROP INDEX IF EXISTS leanvec_p4_sn4;
CREATE INDEX leanvec_p4_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
DROP INDEX IF EXISTS leanvec_p4_s8;
CREATE INDEX leanvec_p4_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = -8);
DROP INDEX IF EXISTS leanvec_p4_sn8;
CREATE INDEX leanvec_pn4_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -4, compression_secondary = 4);
DROP INDEX IF EXISTS leanvec_pn4_s4;
CREATE INDEX leanvec_pn4_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -4, compression_secondary = -4);
DROP INDEX IF EXISTS leanvec_pn4_sn4;
CREATE INDEX leanvec_pn4_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -4, compression_secondary = 8);
DROP INDEX IF EXISTS leanvec_pn4_s8;
CREATE INDEX leanvec_pn4_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -4, compression_secondary = -8);
DROP INDEX IF EXISTS leanvec_pn4_sn8;
CREATE INDEX leanvec_p8_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 4);
DROP INDEX IF EXISTS leanvec_p8_s4;
CREATE INDEX leanvec_p8_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = -4);
DROP INDEX IF EXISTS leanvec_p8_sn4;
CREATE INDEX leanvec_p8_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
DROP INDEX IF EXISTS leanvec_p8_s8;
CREATE INDEX leanvec_p8_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = -8);
DROP INDEX IF EXISTS leanvec_p8_sn8;
CREATE INDEX leanvec_pn8_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -8, compression_secondary = 4);
DROP INDEX IF EXISTS leanvec_pn8_s4;
CREATE INDEX leanvec_pn8_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -8, compression_secondary = -4);
DROP INDEX IF EXISTS leanvec_pn8_sn4;
CREATE INDEX leanvec_pn8_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -8, compression_secondary = 8);
DROP INDEX IF EXISTS leanvec_pn8_s8;
CREATE INDEX leanvec_pn8_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = -8, compression_secondary = -8);
DROP INDEX IF EXISTS leanvec_pn8_sn8;

-- compression_secondary = 0 means "no residual", which only LVQ has; LeanVec
-- must reject it as an out-of-set value rather than treating it as a combination
-- failure.
CREATE INDEX leanvec_p4_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 0);
DROP INDEX IF EXISTS leanvec_p4_s0;
CREATE INDEX leanvec_p8_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 0);
DROP INDEX IF EXISTS leanvec_p8_s0;

-- compression_type = 2 (LVQ): {+-4, +-8} x {0, +-4, +-8}.  SVS compiles
-- specializations for (4,0), (8,0), (4,4) and (4,8) only, so an 8-bit primary
-- takes no residual and every other pair is rejected as a combination.
CREATE INDEX lvq_p4_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = 0);
DROP INDEX IF EXISTS lvq_p4_s0;
CREATE INDEX lvq_p4_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = 4);
DROP INDEX IF EXISTS lvq_p4_s4;
CREATE INDEX lvq_p4_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = -4);
DROP INDEX IF EXISTS lvq_p4_sn4;
CREATE INDEX lvq_p4_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);
DROP INDEX IF EXISTS lvq_p4_s8;
CREATE INDEX lvq_p4_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = -8);
DROP INDEX IF EXISTS lvq_p4_sn8;
CREATE INDEX lvq_pn4_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -4, compression_secondary = 0);
DROP INDEX IF EXISTS lvq_pn4_s0;
CREATE INDEX lvq_pn4_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -4, compression_secondary = 4);
DROP INDEX IF EXISTS lvq_pn4_s4;
CREATE INDEX lvq_pn4_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -4, compression_secondary = -4);
DROP INDEX IF EXISTS lvq_pn4_sn4;
CREATE INDEX lvq_pn4_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -4, compression_secondary = 8);
DROP INDEX IF EXISTS lvq_pn4_s8;
CREATE INDEX lvq_pn4_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -4, compression_secondary = -8);
DROP INDEX IF EXISTS lvq_pn4_sn8;
CREATE INDEX lvq_p8_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 8, compression_secondary = 0);
DROP INDEX IF EXISTS lvq_p8_s0;
CREATE INDEX lvq_p8_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 8, compression_secondary = 4);
DROP INDEX IF EXISTS lvq_p8_s4;
CREATE INDEX lvq_p8_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 8, compression_secondary = -4);
DROP INDEX IF EXISTS lvq_p8_sn4;
CREATE INDEX lvq_p8_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 8, compression_secondary = 8);
DROP INDEX IF EXISTS lvq_p8_s8;
CREATE INDEX lvq_p8_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 8, compression_secondary = -8);
DROP INDEX IF EXISTS lvq_p8_sn8;
CREATE INDEX lvq_pn8_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -8, compression_secondary = 0);
DROP INDEX IF EXISTS lvq_pn8_s0;
CREATE INDEX lvq_pn8_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -8, compression_secondary = 4);
DROP INDEX IF EXISTS lvq_pn8_s4;
CREATE INDEX lvq_pn8_sn4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -8, compression_secondary = -4);
DROP INDEX IF EXISTS lvq_pn8_sn4;
CREATE INDEX lvq_pn8_s8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -8, compression_secondary = 8);
DROP INDEX IF EXISTS lvq_pn8_s8;
CREATE INDEX lvq_pn8_sn8 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = -8, compression_secondary = -8);
DROP INDEX IF EXISTS lvq_pn8_sn8;

-- compression_type = 0: no scheme is selected, so no compression parameter is
-- validated at all -- including values and combinations that either scheme would
-- reject.  This is the same convention leanvec_dims follows under LVQ below.
CREATE INDEX none_p4_s0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 0, compression_primary = 4, compression_secondary = 0);
DROP INDEX IF EXISTS none_p4_s0;
CREATE INDEX none_p5 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 0, compression_primary = 5);
DROP INDEX IF EXISTS none_p5;
CREATE INDEX none_p8_s4 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 0, compression_primary = 8, compression_secondary = 4);
DROP INDEX IF EXISTS none_p8_s4;

-- Values inside the reloption range [-8, 8] but outside {0, +-4, +-8} are
-- rejected by value, under either scheme, before any combination rule runs.
-- (compression_type = 1 with primary 5 and secondary 5 also appears in the
-- boundary block above; repeated here so the matrix stands on its own.)
CREATE INDEX ct1_p0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 0, compression_secondary = 8);
DROP INDEX IF EXISTS ct1_p0;
CREATE INDEX ct1_p5 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 5, compression_secondary = 8);
DROP INDEX IF EXISTS ct1_p5;
CREATE INDEX ct1_s5 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 5);
DROP INDEX IF EXISTS ct1_s5;
CREATE INDEX ct2_p0 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 0, compression_secondary = 8);
DROP INDEX IF EXISTS ct2_p0;
CREATE INDEX ct2_p5 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 5, compression_secondary = 8);
DROP INDEX IF EXISTS ct2_p5;
CREATE INDEX ct2_s5 ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, compression_primary = 4, compression_secondary = 5);
DROP INDEX IF EXISTS ct2_s5;

-- leanvec_dims belongs to LeanVec; under LVQ it is ignored, not rejected.
CREATE INDEX lvq_leanvec_dims ON cmatrix USING vamana (val vector_l2_ops)
    WITH (compression_type = 2, leanvec_dims = 32);
DROP INDEX IF EXISTS lvq_leanvec_dims;

DROP TABLE cmatrix;
