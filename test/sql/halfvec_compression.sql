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

-- These builds actually invoke SVS's LeanVec (compression_type = 1) and LVQ
-- (compression_type = 2) storage paths, which require hardware most CI
-- runners lack (SVS_ERROR_UNSUPPORTED_HW).  Run standalone via
-- `make installcheck-hw`; excluded from `make installcheck`.

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

-- Test with compression
CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[2,2,2]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (build_window_size = 150, compression_type = 1, compression_primary = 8);
SELECT COUNT(*) FROM (SELECT * FROM t ORDER BY val <-> '[3,3,3]' LIMIT 3) sub;
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

-- rebuild preserves compression_type
-- VamanaRebuildFromTable must use LeanVec storage, not hardcoded FP32.

CREATE TABLE t (id serial PRIMARY KEY, val halfvec(3));
INSERT INTO t (val) VALUES ('[0,0,0]'), ('[1,2,3]'), ('[1,1,1]'), ('[3,3,3]');
CREATE INDEX ON t USING vamana (val halfvec_l2_ops) WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);

INSERT INTO t (val) VALUES ('[2,2,2]');
SELECT * FROM t ORDER BY val <-> '[2,2,2]', id;

DROP TABLE t;
