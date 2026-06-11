\set ON_ERROR_STOP on

-- ============================================================
-- Enhanced Valgrind Vamana Test Suite
-- Exercises all major code paths including new features:
-- - Deferred save functionality
-- - Background worker operations
-- - Dynamic index updates (INSERT after CREATE INDEX)
-- - New compression options
-- - TRUNCATE handling
-- - search_window_size parameter
-- ============================================================

-- -------------------------------------------------------
-- 1. L2 distance: basic build + scan + dynamic insert
--    Covers: BuildCallback, InitBuildState, GetDistanceMetricFromIndex (L2),
--            SVSCreateSimpleStorage, SVSBuildDynamicIndex, vamanagettuple,
--            INSERT after index creation
-- -------------------------------------------------------
\echo '--- Test 1: L2 build, scan, and dynamic insert ---'
CREATE TABLE vg_l2 (id int, v vector(3));
INSERT INTO vg_l2 SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 1024) i;
CREATE INDEX ON vg_l2 USING vamana (v vector_l2_ops);

-- Test dynamic insert after index creation
INSERT INTO vg_l2 VALUES (1025, '[0.5, 0.5, 0.5]');
INSERT INTO vg_l2 VALUES (1026, '[0.6, 0.6, 0.6]');

SELECT id FROM vg_l2 ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 10;
DROP TABLE vg_l2;

-- -------------------------------------------------------
-- 2. Cosine distance (vector type)
--    Covers: GetDistanceMetricFromIndex cosine branch (OidIsValid normFuncOid)
-- -------------------------------------------------------
\echo '--- Test 2: Cosine build and scan (vector) ---'
CREATE TABLE vg_cos (id int, v vector(4));
INSERT INTO vg_cos SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100 + 0.01,
        ((i * 3331) % 100)::real / 100 + 0.01,
        ((i * 7919) % 100)::real / 100 + 0.01,
        ((i * 5381) % 100)::real / 100 + 0.01
    ]::vector
FROM generate_series(1, 512) i;
CREATE INDEX ON vg_cos USING vamana (v vector_cosine_ops);
SELECT id FROM vg_cos ORDER BY v <=> '[0.1,0.9,0.2,0.8]' LIMIT 10;
DROP TABLE vg_cos;

-- -------------------------------------------------------
-- 3. Inner product distance (vector type)
--    Covers: GetDistanceMetricFromIndex IP branch (normFuncOid invalid)
-- -------------------------------------------------------
\echo '--- Test 3: Inner product build and scan (vector) ---'
CREATE TABLE vg_ip (id int, v vector(4));
INSERT INTO vg_ip SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100 + 0.01,
        ((i * 3331) % 100)::real / 100 + 0.01,
        ((i * 7919) % 100)::real / 100 + 0.01,
        ((i * 5381) % 100)::real / 100 + 0.01
    ]::vector
FROM generate_series(1, 512) i;
CREATE INDEX ON vg_ip USING vamana (v vector_ip_ops);
SELECT id FROM vg_ip ORDER BY v <#> '[0.1,0.9,0.2,0.8]' LIMIT 10;
DROP TABLE vg_ip;

-- -------------------------------------------------------
-- 4. Empty table
--    Covers: numVectors == 0 branch, VamanaInvalidateCache, goto cleanup
-- -------------------------------------------------------
\echo '--- Test 4: Empty table (numVectors==0 path) ---'
CREATE TABLE vg_empty (id int, v vector(3));
CREATE INDEX ON vg_empty USING vamana (v vector_l2_ops);
SELECT COUNT(*) FROM vg_empty;
DROP TABLE vg_empty;

-- -------------------------------------------------------
-- 5. NULL vectors
--    Covers: isnull[0] skip in BuildCallback
-- -------------------------------------------------------
\echo '--- Test 5: NULL vectors in BuildCallback ---'
CREATE TABLE vg_nulls (id int, v vector(3));
INSERT INTO vg_nulls VALUES (1, '[1,2,3]'), (2, NULL), (3, '[4,5,6]'), (4, NULL), (5, '[7,8,9]');
CREATE INDEX ON vg_nulls USING vamana (v vector_l2_ops);
SELECT id FROM vg_nulls ORDER BY v <-> '[5,5,5]' LIMIT 3;
DROP TABLE vg_nulls;

-- -------------------------------------------------------
-- 6. Buffer growth (> initial bufferCapacity of 1000)
--    Covers: repalloc branch in BuildCallback (bufferCapacity doubling)
-- -------------------------------------------------------
\echo '--- Test 6: Buffer growth beyond initial capacity (>1000 vectors) ---'
CREATE TABLE vg_large (id int, v vector(3));
INSERT INTO vg_large SELECT i,
    ARRAY[
        ((i * 1731) % 1000)::real / 1000,
        ((i * 3331) % 1000)::real / 1000,
        ((i * 7919) % 1000)::real / 1000
    ]::vector
FROM generate_series(1, 2000) i;
CREATE INDEX ON vg_large USING vamana (v vector_l2_ops);
SELECT COUNT(*) FROM (SELECT id FROM vg_large ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 20) t;
DROP TABLE vg_large;

-- -------------------------------------------------------
-- 7. REINDEX — rebuild of existing index
--    Covers: full build path again including VamanaInvalidateCache on second build
-- -------------------------------------------------------
\echo '--- Test 7: REINDEX (rebuild path) ---'
CREATE TABLE vg_reindex (id int, v vector(3));
INSERT INTO vg_reindex SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 300) i;
CREATE INDEX vg_reindex_idx ON vg_reindex USING vamana (v vector_l2_ops);
SELECT id FROM vg_reindex ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 5;
REINDEX INDEX vg_reindex_idx;
SELECT id FROM vg_reindex ORDER BY v <-> '[0.5,0.5,0.5]' LIMIT 5;
DROP TABLE vg_reindex;

-- -------------------------------------------------------
-- 8. halfvec type with L2
--    Covers: halfvec_l2_squared_distance branch in GetDistanceMetricFromIndex
-- -------------------------------------------------------
\echo '--- Test 8: halfvec L2 ---'
CREATE TABLE vg_hv (id int, v halfvec(4));
INSERT INTO vg_hv SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100,
        ((i * 5381) % 100)::real / 100
    ]::halfvec
FROM generate_series(1, 300) i;
CREATE INDEX ON vg_hv USING vamana (v halfvec_l2_ops);
SELECT id FROM vg_hv ORDER BY v <-> '[0.5,0.5,0.5,0.5]'::halfvec LIMIT 5;
DROP TABLE vg_hv;

-- -------------------------------------------------------
-- 9. Higher-dimension vectors (stress mem allocation paths)
--    Covers: MemoryContextAllocHuge for flatData, per-vector palloc/pfree loop
-- -------------------------------------------------------
\echo '--- Test 9: Higher dimensions (128-d) ---'
CREATE TABLE vg_hd (id int, v vector(128));
INSERT INTO vg_hd
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 128) j)
    FROM generate_series(1, 200) i;
CREATE INDEX ON vg_hd USING vamana (v vector_l2_ops)
    WITH (graph_degree = 16, build_window_size = 32);
SELECT id FROM vg_hd
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 128))
LIMIT 5;
DROP TABLE vg_hd;

-- -------------------------------------------------------
-- 10. LeanVec compression
--     Covers: SVSCreateLeanVecStorage, compression_type==VAMANA_COMPRESSION_LEANVEC,
--             ValidateCompressionParam, primary/secondary precision check
-- -------------------------------------------------------
\echo '--- Test 10: LeanVec compression ---'
CREATE TABLE vg_lv (id int, v vector(32));
INSERT INTO vg_lv
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 32) j)
    FROM generate_series(1, 400) i;
CREATE INDEX ON vg_lv USING vamana (v vector_l2_ops)
    WITH (compression_type = 1, leanvec_dims = 16,
          compression_primary = 8, compression_secondary = 8);
SELECT id FROM vg_lv
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 32))
LIMIT 5;
DROP TABLE vg_lv;

-- -------------------------------------------------------
-- 11. Unlogged table — exercises vamanabuildempty path
-- -------------------------------------------------------
\echo '--- Test 11: Unlogged table (vamanabuildempty) ---'
CREATE UNLOGGED TABLE vg_unlogged (id int, v vector(3));
INSERT INTO vg_unlogged VALUES (1, '[1,2,3]'), (2, '[4,5,6]');
CREATE INDEX ON vg_unlogged USING vamana (v vector_l2_ops);
SELECT id FROM vg_unlogged ORDER BY v <-> '[3,3,3]' LIMIT 2;
DROP TABLE vg_unlogged;

-- -------------------------------------------------------
-- 12. Custom index parameters (non-default alpha, windows)
--     Covers: InitBuildState option parsing from rd_options
-- -------------------------------------------------------
\echo '--- Test 12: Custom index options (alpha, windows) ---'
CREATE TABLE vg_opts (id int, v vector(8));
INSERT INTO vg_opts
    SELECT i,
        (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
         FROM generate_series(1, 8) j)
    FROM generate_series(1, 300) i;
CREATE INDEX ON vg_opts USING vamana (v vector_l2_ops)
    WITH (graph_degree = 24, alpha = 135, build_window_size = 48, search_window_size = 20);
SELECT id FROM vg_opts
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 8))
LIMIT 5;
DROP TABLE vg_opts;

-- -------------------------------------------------------
-- 13. LeanVec compression with UINT8 quantization
--     Covers: compression_type=1, compression_primary=8, compression_secondary=8
-- -------------------------------------------------------
\echo '--- Test 13: LeanVec compression (UINT8) ---'
CREATE TABLE vg_comp8 (id int, v vector(16));
INSERT INTO vg_comp8 SELECT i,
    (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
     FROM generate_series(1, 16) j)
FROM generate_series(1, 200) i;
CREATE INDEX ON vg_comp8 USING vamana (v vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);
SELECT id FROM vg_comp8
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 16))
LIMIT 5;
DROP TABLE vg_comp8;

\echo '--- Test 13b: LeanVec compression (UINT4 primary) ---'
CREATE TABLE vg_comp4 (id int, v vector(16));
INSERT INTO vg_comp4 SELECT i,
    (SELECT array_agg(((j * i * 1731) % 1000)::real / 1000 + 0.001)::vector
     FROM generate_series(1, 16) j)
FROM generate_series(1, 200) i;
CREATE INDEX ON vg_comp4 USING vamana (v vector_l2_ops)
    WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);
SELECT id FROM vg_comp4
ORDER BY v <-> (SELECT array_agg(0.5::real)::vector FROM generate_series(1, 16))
LIMIT 5;
DROP TABLE vg_comp4;

-- -------------------------------------------------------
-- 14. TRUNCATE handling
--     Covers: Special handling for TRUNCATE operations on indexed tables
-- -------------------------------------------------------
\echo '--- Test 14: TRUNCATE handling ---'
CREATE TABLE vg_truncate (id int, v vector(3));
INSERT INTO vg_truncate SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 100) i;
CREATE INDEX ON vg_truncate USING vamana (v vector_l2_ops);
SELECT COUNT(*) FROM vg_truncate;
TRUNCATE vg_truncate;
SELECT COUNT(*) FROM vg_truncate;
-- Insert after truncate
INSERT INTO vg_truncate VALUES (1, '[0.1, 0.2, 0.3]');
SELECT id FROM vg_truncate ORDER BY v <-> '[0.1, 0.2, 0.3]' LIMIT 1;
DROP TABLE vg_truncate;

-- -------------------------------------------------------
-- 15. search_window_size parameter
--     Covers: New runtime parameter for search window control
-- -------------------------------------------------------
\echo '--- Test 15: search_window_size parameter ---'
CREATE TABLE vg_search_param (id int, v vector(4));
INSERT INTO vg_search_param SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100,
        ((i * 5381) % 100)::real / 100
    ]::vector
FROM generate_series(1, 500) i;
CREATE INDEX ON vg_search_param USING vamana (v vector_l2_ops);

-- Test with different search_window_size values
SHOW svs.search_window_size;
SET svs.search_window_size = 10;
SELECT COUNT(*) FROM (SELECT id FROM vg_search_param ORDER BY v <-> '[0.5,0.5,0.5,0.5]' LIMIT 10) t;
SET svs.search_window_size = 100;
SELECT COUNT(*) FROM (SELECT id FROM vg_search_param ORDER BY v <-> '[0.5,0.5,0.5,0.5]' LIMIT 10) t;
RESET svs.search_window_size;
DROP TABLE vg_search_param;

-- -------------------------------------------------------
-- 16. Mixed operations: INSERT, UPDATE, DELETE after index
--     Covers: Dynamic index maintenance paths
-- -------------------------------------------------------
\echo '--- Test 16: Mixed DML operations after index creation ---'
CREATE TABLE vg_dml (id int PRIMARY KEY, v vector(3));
INSERT INTO vg_dml SELECT i,
    ARRAY[
        ((i * 1731) % 100)::real / 100,
        ((i * 3331) % 100)::real / 100,
        ((i * 7919) % 100)::real / 100
    ]::vector
FROM generate_series(1, 100) i;
CREATE INDEX ON vg_dml USING vamana (v vector_l2_ops);

-- INSERT after index
INSERT INTO vg_dml VALUES (101, '[0.5, 0.5, 0.5]');
INSERT INTO vg_dml VALUES (102, '[0.6, 0.6, 0.6]');

-- UPDATE vector values
UPDATE vg_dml SET v = '[0.7, 0.7, 0.7]' WHERE id = 1;
UPDATE vg_dml SET v = '[0.8, 0.8, 0.8]' WHERE id = 2;

-- DELETE some vectors
DELETE FROM vg_dml WHERE id IN (3, 4, 5);

-- Verify index still works
SELECT id FROM vg_dml ORDER BY v <-> '[0.5, 0.5, 0.5]' LIMIT 5;
DROP TABLE vg_dml;

\echo '=== All Enhanced Vamana valgrind tests completed ==='