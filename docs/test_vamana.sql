--------------------------------------------------------------------------------
-- Vamana Index - Interactive Development and Testing Script
--------------------------------------------------------------------------------
--
-- PURPOSE:
--   This file is a DEVELOPER TOOL for interactive testing, benchmarking,
--   performance analysis, and prototyping of the Vamana index implementation.
--   It is NOT part of the automated test suite and is NOT run by `make installcheck`.
--
-- USAGE:
--   Run manually with: psql -d your_database -f docs/test_vamana.sql
--   Expected use cases:
--   - Interactive development and debugging
--   - Performance benchmarking with EXPLAIN ANALYZE
--   - Recall quality validation (statistical analysis)
--   - Prototyping new features before formal test integration
--   - Exploring edge cases and parameter tuning
--
-- IMPORTANT NOTES:
--   - Tests in this file may produce NON-DETERMINISTIC output (timing, explain plans)
--   - Results are NOT validated by regression tests
--   - Use psql meta-commands (\timing, \echo, etc.) freely for development
--
-- FORMAL TEST COVERAGE:
--   For automated regression testing, see:
--   - test/sql/vamana_vector.sql      - Vector type regression tests
--   - test/sql/vamana_halfvec.sql     - Halfvec type regression tests
--   - test/t/*_vamana_*.pl            - Perl TAP tests (recall, WAL, etc.)
--
-- SECTIONS:
--   1. Quick Start - Basic functionality verification
--   2. Performance Benchmarks - EXPLAIN ANALYZE and timing tests
--   3. Recall Validation - Statistical quality analysis
--   4. Compression Exploration - LeanVec parameter testing
--   5. Experimental - Cutting-edge features and edge cases
--
--------------------------------------------------------------------------------

-- SECTION 1: QUICK START
-- Basic functionality verification

-- 1. Load or create extension
CREATE EXTENSION IF NOT EXISTS vector;

-- Check extension version
SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';

-- 2. Create test table
DROP TABLE IF EXISTS vamana_test_vectors CASCADE;
CREATE TABLE vamana_test_vectors (
    id SERIAL PRIMARY KEY,
    embedding vector(128),
    metadata TEXT
);

-- 3. Insert sample data (100 random vectors)
INSERT INTO vamana_test_vectors (embedding, metadata)
SELECT
    ARRAY(SELECT random()::real FROM generate_series(1, 128))::vector(128),
    'Sample vector ' || i
FROM generate_series(1, 100) i;

-- 4. Create Vamana index
\timing on
CREATE INDEX vamana_idx ON vamana_test_vectors 
USING vamana (embedding vector_l2_ops)
WITH (graph_degree = 32, alpha = 120);

-- 5. Check index was created
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE indexname = 'vamana_idx';

-- 6. Test query with ORDER BY (uses index)
EXPLAIN (ANALYZE, BUFFERS) 
SELECT id, embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128) AS distance
FROM vamana_test_vectors
ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
LIMIT 5;

-- 7. Actually run the query
SELECT id, metadata, embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128) AS distance
FROM vamana_test_vectors
ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
LIMIT 5;

-- 8. Test cache behavior - run same query again (should be faster)
\echo 'Second query (should use cached index):'
SELECT id, metadata
FROM vamana_test_vectors
ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
LIMIT 5;

-- 9. Test INSERT invalidates cache
INSERT INTO vamana_test_vectors (embedding, metadata)
VALUES (ARRAY(SELECT random()::real FROM generate_series(1, 128))::vector(128), 'New vector after index');

\echo 'Query after INSERT (cache should be invalidated):'
SELECT id, metadata
FROM vamana_test_vectors
ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
LIMIT 5;

-- 10. Verify correctness: Compare Vamana (approximate) vs Sequential Scan (exact)
\echo ''
\echo '=== Correctness Verification ==='
\echo 'Comparing Vamana index results vs ground truth (sequential scan):'
\echo ''

-- Ground truth using sequential scan (no index)
SET enable_indexscan = off;
SET enable_bitmapscan = off;
\echo 'Ground truth (sequential scan - exact nearest neighbors):'
SELECT id, embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128) AS distance
FROM vamana_test_vectors
ORDER BY distance
LIMIT 10;

RESET enable_indexscan;
RESET enable_bitmapscan;

\echo ''
\echo 'Vamana index results (approximate nearest neighbors):'
SELECT id, embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128) AS distance
FROM vamana_test_vectors
ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
LIMIT 10;

\echo ''
\echo 'Calculating Recall@10 (percentage of ground truth results found by Vamana):'

-- Calculate recall by comparing the two result sets
WITH ground_truth AS (
    SELECT id
    FROM vamana_test_vectors
    ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
    LIMIT 10
),
vamana_results AS (
    SELECT id
    FROM vamana_test_vectors
    ORDER BY embedding <-> '[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8,0.9,1.0,1.1,1.2,1.3,1.4,1.5,1.6,1.7,1.8,1.9,2.0,2.1,2.2,2.3,2.4,2.5,2.6,2.7,2.8,2.9,3.0,3.1,3.2,3.3,3.4,3.5,3.6,3.7,3.8,3.9,4.0,4.1,4.2,4.3,4.4,4.5,4.6,4.7,4.8,4.9,5.0,5.1,5.2,5.3,5.4,5.5,5.6,5.7,5.8,5.9,6.0,6.1,6.2,6.3,6.4,6.5,6.6,6.7,6.8,6.9,7.0,7.1,7.2,7.3,7.4,7.5,7.6,7.7,7.8,7.9,8.0,8.1,8.2,8.3,8.4,8.5,8.6,8.7,8.8,8.9,9.0,9.1,9.2,9.3,9.4,9.5,9.6,9.7,9.8,9.9,10.0,10.1,10.2,10.3,10.4,10.5,10.6,10.7,10.8,10.9,11.0,11.1,11.2,11.3,11.4,11.5,11.6,11.7,11.8,11.9,12.0,12.1,12.2,12.3,12.4,12.5,12.6,12.7,12.8]'::vector(128)
    LIMIT 10
),
matches AS (
    SELECT COUNT(*) as match_count
    FROM vamana_results v
    INNER JOIN ground_truth g ON v.id = g.id
)
SELECT 
    match_count as matches_found,
    10 as total_results,
    ROUND(100.0 * match_count / 10, 1) as recall_percentage
FROM matches;

\echo ''
\echo 'Interpretation: Recall@10 of 90%+ means 9 or 10 out of 10 results match ground truth.'
\echo ''

-- 11. Show extension is working
\echo '=== Vamana Index Test Complete ==='
\echo 'Expected behavior:'
\echo '  - Index builds successfully'
\echo '  - Queries return correct heap tuple IDs'
\echo '  - INSERT should show cache invalidation notice'
\echo '  - Subsequent query should show cache rebuild notice'
\echo '  - Correctness verification shows high recall (most IDs match ground truth)'
\echo ''

-- Test distance metric detection for Vamana index
-- This script verifies that the correct distance metric is detected from operator class

-- Setup
DROP TABLE IF EXISTS test_vamana_metrics CASCADE;
CREATE TABLE test_vamana_metrics (
    id serial PRIMARY KEY,
    vec vector(3)
);

-- Insert test data
INSERT INTO test_vamana_metrics (vec) VALUES
    ('[1,2,3]'),
    ('[4,5,6]'),
    ('[7,8,9]'),
    ('[10,11,12]'),
    ('[13,14,15]');

-- Test 1: L2 distance (Euclidean) with explicit alpha
\echo '=== Testing L2 Distance (Euclidean) with alpha=120 ==='
DROP INDEX IF EXISTS idx_vamana_l2;
CREATE INDEX idx_vamana_l2 ON test_vamana_metrics USING vamana (vec vector_l2_ops)
    WITH (graph_degree = 32, alpha = 120);

-- Test 2: Inner Product with custom build windows
\echo '=== Testing Inner Product with build_window_size=100, search_window_size=150 ==='
DROP INDEX IF EXISTS idx_vamana_ip;
CREATE INDEX idx_vamana_ip ON test_vamana_metrics USING vamana (vec vector_ip_ops)
    WITH (graph_degree = 32, build_window_size = 100, search_window_size = 150);

-- Test 3: Cosine Distance with all defaults (SVS manages everything)
\echo '=== Testing Cosine Distance with all SVS defaults ==='
DROP INDEX IF EXISTS idx_vamana_cosine;
CREATE INDEX idx_vamana_cosine ON test_vamana_metrics USING vamana (vec vector_cosine_ops)
    WITH (graph_degree = 32);  -- All other params use SVS/pgvector defaults

-- Verify indexes exist
\echo '=== Verifying indexes ==='
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE tablename = 'test_vamana_metrics' 
ORDER BY indexname;

-- Query tests to ensure correctness
\echo '=== Testing L2 query ==='
SET enable_seqscan = off;
SELECT id, vec <-> '[2,3,4]' AS distance
FROM test_vamana_metrics
ORDER BY vec <-> '[2,3,4]'
LIMIT 3;

\echo '=== Testing Inner Product query ==='
SELECT id, vec <#> '[2,3,4]' AS distance
FROM test_vamana_metrics
ORDER BY vec <#> '[2,3,4]'
LIMIT 3;

\echo '=== Testing Cosine Distance query ==='
SELECT id, vec <=> '[2,3,4]' AS distance
FROM test_vamana_metrics
ORDER BY vec <=> '[2,3,4]'
LIMIT 3;

-- Cleanup
DROP TABLE test_vamana_metrics CASCADE;

\echo '=== Distance metric tests completed ==='


-- Test use_search_history parameter for Vamana index

-- Create test table
DROP TABLE IF EXISTS test_search_history CASCADE;
CREATE TABLE test_search_history (id serial PRIMARY KEY, embedding vector(3));

-- Insert test data
INSERT INTO test_search_history (embedding) VALUES 
    ('[1,2,3]'),
    ('[4,5,6]'),
    ('[7,8,9]'),
    ('[2,3,4]'),
    ('[5,6,7]');

-- Test 1: Create index with search_history enabled (default)
DROP INDEX IF EXISTS idx_with_history;
CREATE INDEX idx_with_history ON test_search_history 
USING vamana (embedding vector_l2_ops)
WITH (graph_degree = 16);

-- Verify parameters
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE indexname = 'idx_with_history';

-- Query with history enabled
SELECT id, embedding <-> '[3,4,5]' AS distance
FROM test_search_history
ORDER BY embedding <-> '[3,4,5]'
LIMIT 3;

-- Test 2: Create index with search_history disabled
DROP INDEX IF EXISTS idx_without_history;
CREATE INDEX idx_without_history ON test_search_history 
USING vamana (embedding vector_l2_ops)
WITH (graph_degree = 16, use_search_history = false);

-- Verify parameters
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE indexname = 'idx_without_history';

-- Query with history disabled
SELECT id, embedding <-> '[3,4,5]' AS distance
FROM test_search_history
ORDER BY embedding <-> '[3,4,5]'
LIMIT 3;

-- Test 3: Explicitly enable search_history
DROP INDEX IF EXISTS idx_explicit_history;
CREATE INDEX idx_explicit_history ON test_search_history 
USING vamana (embedding vector_l2_ops)
WITH (graph_degree = 16, use_search_history = true, alpha = 150);

-- Verify parameters
SELECT indexname, indexdef 
FROM pg_indexes 
WHERE indexname = 'idx_explicit_history';

-- Cleanup
DROP TABLE test_search_history CASCADE;

-- ==============================================================================
-- NOTES:
-- ==============================================================================
-- use_search_history controls whether the Vamana algorithm maintains
-- a visited set during graph traversal for search operations.
-- 
-- Benefits of use_search_history = true (default):
-- - Better accuracy (higher recall)
-- - Prevents revisiting nodes during search
-- - Recommended for most use cases
--
-- When to use use_search_history = false:
-- - Slightly faster queries (less memory overhead)
-- - Lower memory usage during search
-- - Acceptable when small accuracy loss is tolerable



-- Test LeanVec compression for Vamana index
-- Covers all compression parameters and use cases

-- Create test table
CREATE TABLE test_leanvec (
    id serial PRIMARY KEY,
    vec vector(128)
);

-- Insert test data (100 vectors)
INSERT INTO test_leanvec (vec)
SELECT array_to_vector(ARRAY(SELECT random() FROM generate_series(1, 128)), 128, false)
FROM generate_series(1, 100);

-- ========================================
-- Test 1: No compression (baseline)
-- ========================================
\echo '=== Test 1: No compression ==='
CREATE INDEX idx_none ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 0);  -- 0=none, 1=leanvec

-- Verify index works
SELECT COUNT(*) FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 10;

DROP INDEX idx_none;

-- ========================================
-- Test 2: Default LeanVec compression
-- ========================================
\echo '=== Test 2: Default LeanVec (UINT8/UINT8) ==='
CREATE INDEX idx_leanvec_default ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 1);  -- 0=none, 1=leanvec

-- Query test
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 5;

DROP INDEX idx_leanvec_default;

-- ========================================
-- Test 3: All compression_primary values
-- ========================================
\echo '=== Test 3: compression_primary variations ==='

-- UINT4 primary
CREATE INDEX idx_uint4_primary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 4,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_uint4_primary;

-- INT4 primary (signed)
CREATE INDEX idx_int4_primary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = -4,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_int4_primary;

-- UINT8 primary
CREATE INDEX idx_uint8_primary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_uint8_primary;

-- INT8 primary (signed)
CREATE INDEX idx_int8_primary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = -8,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_int8_primary;

-- ========================================
-- Test 4: All compression_secondary values
-- ========================================
\echo '=== Test 4: compression_secondary variations ==='

-- UINT4 secondary
CREATE INDEX idx_uint4_secondary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 4,
    compression_secondary = 4
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_uint4_secondary;

-- INT4 secondary (signed)
CREATE INDEX idx_int4_secondary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = -4,
    compression_secondary = -4
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_int4_secondary;

-- UINT8 secondary
CREATE INDEX idx_uint8_secondary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_uint8_secondary;

-- INT8 secondary (signed)
CREATE INDEX idx_int8_secondary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = -8,
    compression_secondary = -8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_int8_secondary;

-- ========================================
-- Test 5: Mixed precision (primary <= secondary)
-- ========================================
\echo '=== Test 5: Mixed precision ==='

-- 4-bit primary, 8-bit secondary (high compression)
CREATE INDEX idx_4bit_8bit ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 4,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_4bit_8bit;

-- -4-bit primary (signed), 8-bit secondary
CREATE INDEX idx_int4_uint8 ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = -4,
    compression_secondary = 8
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_int4_uint8;

-- ========================================
-- Test 6: Custom leanvec_dims
-- ========================================
\echo '=== Test 6: Custom leanvec_dims ==='

-- Default dims (dimensions / 2 = 64)
CREATE INDEX idx_default_dims ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 8,
    leanvec_dims = -1
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_default_dims;

-- Custom reduced dims (32)
CREATE INDEX idx_32_dims ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 8,
    leanvec_dims = 32
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_32_dims;

-- Higher custom dims (96)
CREATE INDEX idx_96_dims ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 8,
    leanvec_dims = 96
);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_96_dims;

-- ========================================
-- Test 7: Different distance metrics
-- ========================================
\echo '=== Test 7: Distance metrics with compression ==='

-- L2 distance
CREATE INDEX idx_l2_compressed ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 1);
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_l2_compressed;

-- Inner product
CREATE INDEX idx_ip_compressed ON test_leanvec USING vamana (vec vector_ip_ops)
WITH (compression_type = 1);
SELECT id FROM test_leanvec ORDER BY vec <#> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_ip_compressed;

-- Cosine distance
CREATE INDEX idx_cosine_compressed ON test_leanvec USING vamana (vec vector_cosine_ops)
WITH (compression_type = 1);
SELECT id FROM test_leanvec ORDER BY vec <=> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 3;
DROP INDEX idx_cosine_compressed;

-- ========================================
-- Test 8: Integer compression type values
-- ========================================
\echo '=== Test 8: Integer compression type values ==='

CREATE INDEX idx_int_leanvec ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 1);  -- 1 = leanvec
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 1;
DROP INDEX idx_int_leanvec;

CREATE INDEX idx_int_none ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 0);  -- 0 = none
SELECT id FROM test_leanvec ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector LIMIT 1;
DROP INDEX idx_int_none;

-- ========================================
-- Test 9: Error cases (should fail)
-- ========================================
\echo '=== Test 9: Error cases (should fail) ==='

-- Invalid compression_type (out of range)
\echo 'Testing invalid compression_type...'
CREATE INDEX idx_invalid_type ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 99);  -- Should fail: value out of range 0-2

-- Invalid compression_primary
\echo 'Testing invalid compression_primary...'
CREATE INDEX idx_invalid_primary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 5  -- Should fail: only 4, -4, 8, -8 allowed
);

-- Invalid compression_secondary
\echo 'Testing invalid compression_secondary...'
CREATE INDEX idx_invalid_secondary ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 10  -- Should fail: only 4, -4, 8, -8 allowed
);

-- Primary > secondary (precision violation)
\echo 'Testing primary > secondary...'
CREATE INDEX idx_invalid_precision ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,
    compression_primary = 8,
    compression_secondary = 4
);

-- Compression params without compression_type=1 (leanvec)
\echo 'Testing compression params with compression_type=0...'
CREATE INDEX idx_params_no_compression ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 0,  -- 0=none
    compression_primary = 8
);

-- ========================================
-- Test 10: Insert/Update/Delete with compression
-- ========================================
\echo '=== Test 10: DML operations with compression ==='

CREATE INDEX idx_dml ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (compression_type = 1);  -- 1=leanvec

-- Insert new vector
INSERT INTO test_leanvec (vec)
VALUES (array_to_vector(ARRAY(SELECT 0.5 FROM generate_series(1, 128)), 128, false));

-- Verify it's searchable
SELECT id FROM test_leanvec 
WHERE id = (SELECT MAX(id) FROM test_leanvec)
ORDER BY vec <-> '[0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5,0.5]'::vector
LIMIT 1;

-- Update vector
UPDATE test_leanvec 
SET vec = array_to_vector(ARRAY(SELECT 0.1 FROM generate_series(1, 128)), 128, false)
WHERE id = 1;

-- Verify update
SELECT id FROM test_leanvec 
WHERE id = 1
ORDER BY vec <-> '[0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1,0.1]'::vector
LIMIT 1;

-- Delete vector
DELETE FROM test_leanvec WHERE id = 50;

-- Verify deletion
SELECT COUNT(*) FROM test_leanvec WHERE id = 50;

DROP INDEX idx_dml;

-- ========================================
-- Test 11: All parameter combinations
-- ========================================
\echo '=== Test 11: Comprehensive parameter test ==='

CREATE INDEX idx_comprehensive ON test_leanvec USING vamana (vec vector_l2_ops)
WITH (
    compression_type = 1,  -- 1=leanvec
    compression_primary = 4,
    compression_secondary = 8,
    leanvec_dims = 48,
    graph_degree = 32,
    alpha = 120
);

-- Run query
SELECT id FROM test_leanvec 
ORDER BY vec <-> '[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]'::vector
LIMIT 5;

DROP INDEX idx_comprehensive;

-- ========================================
-- Cleanup
-- ========================================
DROP TABLE test_leanvec;

\echo '=== All LeanVec compression tests completed ==='
