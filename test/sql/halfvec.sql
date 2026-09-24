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

-- L2

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
SET client_min_messages = error;
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);
RESET client_min_messages;

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> (SELECT NULL::halfvec)) t2;
SELECT COUNT(*) FROM t;

TRUNCATE t;
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- inner product

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_ip_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <#> '[3,3,3]', id;
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <#> (SELECT NULL::halfvec)) t2;

DROP TABLE t;

-- cosine

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_cosine_ops);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <=> '[3,3,3]', id;
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <=> '[0,0,0]') t2;
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <=> (SELECT NULL::halfvec)) t2;

DROP TABLE t;

-- element width
--
-- A halfvec element is half as wide as a vector element, so the datum has to
-- be read at its own element width and widened on the way to the index.  Read
-- at the wrong width, every distance is computed from the wrong numbers and
-- the rows come back in the wrong order, with no error.
--
-- The data below is deliberately asymmetric.  Symmetric data such as
-- '[1,0,0]', '[0,1,0]', '[0,0,1]' cannot detect this: every candidate is
-- mismeasured the same way and the ordering survives.  Each case prints the
-- index order and then the exact order over the same rows, so a difference
-- between them is the failure, not a value anyone has to read.
--
-- Note the missing ", id" tie-break that the rest of this file uses.  It is
-- left off on purpose: it puts an Incremental Sort above the index scan, and
-- below DEFAULT_MIN_GROUP_SIZE (32) tuples that node buffers the whole input
-- and sorts it outright, which repairs a wrong index order before it is ever
-- printed.  Every distance in these cases is distinct, so no tie-break is
-- needed to make the output deterministic.

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[100,1,0]'), ('[0,2,0]'), ('[0,8,0]'), ('[0,32,0]');
SET client_min_messages = error;
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);
RESET client_min_messages;

-- The index is what answers this, and nothing re-sorts what it returns --
-- otherwise the comparison below would hold no matter what the index held.
EXPLAIN (COSTS OFF) SELECT id FROM t ORDER BY val <-> '[0,1,0]';
SELECT id FROM t ORDER BY val <-> '[0,1,0]';

SET enable_indexscan = off;
SET enable_seqscan = on;
SELECT id FROM t ORDER BY val <-> '[0,1,0]';
RESET enable_indexscan;
SET enable_seqscan = off;

DROP TABLE t;

-- Same, for inner product and cosine: the element width is read the same way
-- whatever the metric, so each metric has to be shown reaching its own
-- correct order.
--
-- The inner-product rows put the weight the query asks about in the first
-- dimension and an opposing value in the second, because a wrong-width read
-- pairs the two: with the L2 rows above, the pairing happens to preserve the
-- correct order for this metric, and the case would pass either way.

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[1,32,0]'), ('[2,8,0]'), ('[8,2,0]'), ('[32,1,0]');
CREATE INDEX ON t USING vamana (val halfvec_ip_ops);

SELECT id FROM t ORDER BY val <#> '[1,0,0]';

SET enable_indexscan = off;
SET enable_seqscan = on;
SELECT id FROM t ORDER BY val <#> '[1,0,0]';
RESET enable_indexscan;
SET enable_seqscan = off;

DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[1,4,0]'), ('[1,1,0]'), ('[4,1,0]'), ('[0,1,0]');
CREATE INDEX ON t USING vamana (val halfvec_cosine_ops);

SELECT id FROM t ORDER BY val <=> '[1,0,0]';

SET enable_indexscan = off;
SET enable_seqscan = on;
SELECT id FROM t ORDER BY val <=> '[1,0,0]';
RESET enable_indexscan;
SET enable_seqscan = off;

DROP TABLE t;

-- Compression composes with the element width rather than replacing it: under
-- LeanVec or LVQ the compressed spec owns the stored format, but the datum
-- still arrives as halfvec and still has to be read at halfvec's width.

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[100,1,0]'), ('[0,2,0]'), ('[0,8,0]'), ('[0,32,0]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops)
	WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);

SELECT id FROM t ORDER BY val <-> '[0,1,0]';

DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[100,1,0]'), ('[0,2,0]'), ('[0,8,0]'), ('[0,32,0]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops)
	WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);

SELECT id FROM t ORDER BY val <-> '[0,1,0]';

DROP TABLE t;

-- A wider, denser case: 300 rows at 64 dimensions, every row distinct, with
-- each dimension carrying its own value so that neither the correct ordering
-- nor a mismeasured one is simply the row order.
--
-- This one prints the top-5 distances rather than the top-5 ids: two rows can
-- sit at the same distance from the query, and which of those the index puts
-- first is arbitrary, while the sequence of distances is not.  A wrong element
-- width shows up as a sequence that does not ascend, or does not match the
-- exact one below it.

CREATE TABLE t (id int PRIMARY KEY, val halfvec(64));
INSERT INTO t
SELECT i,
	   (SELECT array_agg(CASE WHEN j = 1 THEN i ELSE ((i * (j + 7)) % 89) + 1 END ORDER BY j)
		  FROM generate_series(1, 64) AS j)::halfvec
  FROM generate_series(1, 300) AS i;
SET client_min_messages = error;
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);
RESET client_min_messages;

SELECT round((val <-> (SELECT val FROM t WHERE id = 150))::numeric, 3) AS distance
  FROM t ORDER BY val <-> (SELECT val FROM t WHERE id = 150) LIMIT 5;

SET enable_indexscan = off;
SET enable_seqscan = on;
SELECT round((val <-> (SELECT val FROM t WHERE id = 150))::numeric, 3) AS distance
  FROM t ORDER BY val <-> (SELECT val FROM t WHERE id = 150) LIMIT 5;
RESET enable_indexscan;
SET enable_seqscan = off;

DROP TABLE t;

-- unlogged

CREATE UNLOGGED TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- options

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (graph_degree = 15);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (graph_degree = 257);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (alpha = 50);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (alpha = 201);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (graph_degree = 64, alpha = 120);

DROP TABLE t;

-- compression with LeanVec UINT8

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- compression with LeanVec UINT4 primary

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);

INSERT INTO t (val) VALUES ('[1,2,4]');

SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- compression detailed parameters

-- Test compression_type enum (0=none, 1=leanvec)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 0);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- Test compression_primary variations (4, -4, 8, -8)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = -4, compression_secondary = 8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = -8, compression_secondary = 8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- Test compression_secondary variations (4, -4, 8, -8)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 4);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = -4);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8, compression_secondary = -8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- Test leanvec_dims (-1=auto, custom values)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(128));
INSERT INTO t (val) VALUES (array_fill(1, ARRAY[128])::halfvec), (array_fill(2, ARRAY[128])::halfvec);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = -1);
SELECT id FROM t ORDER BY val <-> array_fill(1.5, ARRAY[128])::halfvec, id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(128));
INSERT INTO t (val) VALUES (array_fill(1, ARRAY[128])::halfvec), (array_fill(2, ARRAY[128])::halfvec);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = 32);
SELECT id FROM t ORDER BY val <-> array_fill(1.5, ARRAY[128])::halfvec, id;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(128));
INSERT INTO t (val) VALUES (array_fill(1, ARRAY[128])::halfvec), (array_fill(2, ARRAY[128])::halfvec);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = 48);
SELECT id FROM t ORDER BY val <-> array_fill(1.5, ARRAY[128])::halfvec, id;
DROP TABLE t;

-- Test compression with inner product
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_ip_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
SELECT * FROM t ORDER BY val <#> '[3,3,3]', id;
DROP TABLE t;

-- Test compression with cosine
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[1,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_cosine_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
SELECT * FROM t ORDER BY val <=> '[3,3,3]', id;
DROP TABLE t;

-- LVQ compression (compression_type = 2)
--
-- One real build per SVS specialization: (4,0), (8,0), (4,4) and (4,8), plus a
-- bare compression_type = 2 to pin that the shared defaults resolve to a legal
-- LVQ pair.  The three LeanVec specializations are already built above.  Sign
-- variants are not repeated here -- SVS keeps bit counts only, so -4 and 4 reach
-- the same specialization, and reloption_params.sql covers their acceptance.
-- Each build is followed by a search, so a storage spec that does not match the
-- data shows up as a wrong answer rather than a silent pass.

-- LVQ4: 4-bit primary, no residual
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2, compression_primary = 4, compression_secondary = 0);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- LVQ8: 8-bit primary, no residual
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2, compression_primary = 8, compression_secondary = 0);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- LVQ4x4: 4-bit primary with a 4-bit residual
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2, compression_primary = 4, compression_secondary = 4);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- LVQ4x8: 4-bit primary with an 8-bit residual
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- Defaults only: resolves to LVQ4x8
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2);
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;


-- compression error cases

-- Test invalid compression_type values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 99);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = -1);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 2);
DROP TABLE t;

-- Test invalid compression_primary values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 5);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 10);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 3);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 16);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 0);
DROP TABLE t;

-- Test invalid compression_secondary values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 5);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 10);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 3);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 4, compression_secondary = 16);
DROP TABLE t;

-- Test invalid leanvec_dims values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(128));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = 0);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = -2);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, leanvec_dims = 200);
DROP TABLE t;

-- Test compression parameters without compression_type = 1
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_primary = 4);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 0, compression_primary = 4);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 0, compression_secondary = 8);
DROP TABLE t;

-- Test invalid build parameter values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 0);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = -1);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (search_window_size = 0);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (search_window_size = -1);
DROP TABLE t;

-- advanced build parameters
-- Note: With small datasets (5 vectors) and halfvec quantization,
-- exact result ordering can be non-deterministic due to graph structure variations.
-- These tests verify parameter acceptance and basic functionality without exact ordering.

-- Test build_window_size variations
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 100);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 150);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 200);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- Test search_window_size variations
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (search_window_size = 50);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (search_window_size = 150);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (search_window_size = 200);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- Test use_search_history boolean
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (use_search_history = true);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (use_search_history = false);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- Test combined parameters
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 150, search_window_size = 100, use_search_history = true);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- Test with compression
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 150, compression_type = 1, compression_primary = 8);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- Test with different distance metrics
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_ip_ops) WITH (build_window_size = 150);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <#> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[1,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_cosine_ops) WITH (search_window_size = 100);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <=> '[3,3,3]' LIMIT 3) sub;
DROP TABLE t;

-- DML operations

-- Test UPDATE of vector values
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

-- Update a vector and verify searchability
UPDATE t SET val = '[5,5,5]' WHERE id = 2;
SELECT * FROM t ORDER BY val <-> '[4,4,4]', id;
DROP TABLE t;

-- Test DELETE of rows
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

-- Delete a row and verify it's not in results
DELETE FROM t WHERE id = 3;
SELECT * FROM t ORDER BY val <-> '[1,1,1]', id;
DROP TABLE t;

-- Test INSERT after index creation
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

-- Insert new rows after index exists
INSERT INTO t (val) VALUES ('[2,2,2]'), ('[3,3,3]');
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;
DROP TABLE t;

-- Test mixed DML operations
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]'), ('[4,4,4]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

-- Mix of UPDATE, DELETE, INSERT
UPDATE t SET val = '[1.5,1.5,1.5]' WHERE id = 2;
DELETE FROM t WHERE id = 4;
INSERT INTO t (val) VALUES ('[5,5,5]');
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;
DROP TABLE t;

-- Test DML with compressed index
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8);

-- Update with compressed index
UPDATE t SET val = '[5,5,5]' WHERE id = 2;
SELECT * FROM t ORDER BY val <-> '[4,4,4]', id;

-- Delete with compressed index
DELETE FROM t WHERE id = 1;
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;

-- Insert with compressed index
INSERT INTO t (val) VALUES ('[6,6,6]');
SELECT * FROM t ORDER BY val <-> '[5,5,5]', id;
DROP TABLE t;

-- Test DML with different distance metrics
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]');
CREATE INDEX ON t USING vamana (val halfvec_ip_ops);

UPDATE t SET val = '[5,5,5]' WHERE id = 2;
DELETE FROM t WHERE id = 1;
INSERT INTO t (val) VALUES ('[3,3,3]');
SELECT * FROM t ORDER BY val <#> '[3,3,3]', id;
DROP TABLE t;

-- index introspection

-- Verify basic index metadata
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]');
CREATE INDEX vamana_meta_idx ON t USING vamana (val halfvec_l2_ops);

SELECT indexname, tablename FROM pg_indexes WHERE indexname = 'vamana_meta_idx';

DROP TABLE t;

-- Verify index parameters appear in definition
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX vamana_params_idx ON t USING vamana (val halfvec_l2_ops) 
  WITH (graph_degree = 64, alpha = 120);

SELECT indexname, indexdef FROM pg_indexes WHERE indexname = 'vamana_params_idx';

DROP TABLE t;

-- Verify compression parameters in definition
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX vamana_compress_idx ON t USING vamana (val halfvec_l2_ops) 
  WITH (compression_type = 1, compression_primary = 8);

SELECT indexname FROM pg_indexes WHERE indexname = 'vamana_compress_idx';

DROP TABLE t;

-- Verify operator class mappings (L2, inner product, cosine)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX vamana_l2_idx ON t USING vamana (val halfvec_l2_ops);
CREATE INDEX vamana_ip_idx ON t USING vamana (val halfvec_ip_ops);
CREATE INDEX vamana_cosine_idx ON t USING vamana (val halfvec_cosine_ops);

SELECT indexname FROM pg_indexes 
WHERE tablename = 't' AND indexname LIKE 'vamana_%_idx'
ORDER BY indexname;

DROP TABLE t;

-- runtime parameter tuning

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

SET svs.search_window_size = 50;
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

SET svs.search_window_size = 200;
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

RESET svs.search_window_size;
SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- test with reversed insertion order (tests index robustness)

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[1,2,4]'), ('[1,1,1]'), ('[1,2,3]'), ('[0,0,0]'), (NULL);
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

SELECT * FROM t ORDER BY val <-> '[3,3,3]', id;

DROP TABLE t;

-- test top-K recall (verify index returns reasonable results)
-- Note: Exact recall varies due to approximate nature of Vamana
-- halfvec may have lower quality than vector due to quantization
-- Use Perl TAP tests (test/t/*_recall.pl) for statistical recall verification

CREATE TABLE t (id int, val halfvec(3));
INSERT INTO t VALUES 
  (1, '[10,10,10]'),
  (2, '[20,20,20]'), 
  (3, '[30,30,30]'),
  (4, '[1,2,3]'),
  (5, '[5,5,5]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

-- Verify index returns k results (exact ordering may vary with small datasets)
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[1,2,3]' LIMIT 3) sub;

DROP TABLE t;

-- serialization

-- CREATE INDEX persists to disk (no "not yet implemented" notice);
-- INSERT invalidates the saved copy; next SELECT rebuilds from table and re-saves.
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);

INSERT INTO t (val) VALUES ('[2,2,2]');
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;

DROP TABLE t;

-- rebuild preserves compression_type
-- VamanaRebuildFromTable must use LeanVec storage, not hardcoded FP32.

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);

INSERT INTO t (val) VALUES ('[2,2,2]');
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;

DROP TABLE t;

-- pgvector rejects NaN/Inf at parse time on tables carrying a vamana index (halfvec type)
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);
INSERT INTO t (val) VALUES ('[1,NaN,3]');
INSERT INTO t (val) VALUES ('[1,Infinity,3]');
DROP TABLE t;

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,1,1]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops);
SELECT * FROM t ORDER BY val <-> '[1,NaN,3]' LIMIT 1;
SELECT * FROM t ORDER BY val <-> '[1,Infinity,3]' LIMIT 1;
DROP TABLE t;
