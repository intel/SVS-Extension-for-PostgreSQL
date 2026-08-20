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
