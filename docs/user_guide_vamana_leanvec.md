# User Guide: SVS Vamana Index and LeanVec Compression

> **⚠️ Disclaimer:** This is a prototype. The implementation is functional but further improvements, additional features, and production hardening are actively in progress. Interfaces, parameters, and behaviors are subject to change in future releases.

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start](#3-quick-start)
4. [Vamana Index in Depth](#4-vamana-index-in-depth)
   - 4.1 [Supported Vector Types and Distance Metrics](#41-supported-vector-types-and-distance-metrics)
   - 4.2 [Index Build Parameters](#42-index-build-parameters)
   - 4.3 [Query-Time Parameters](#43-query-time-parameters)
   - 4.4 [Creating an Index](#44-creating-an-index)
   - 4.5 [Running Queries](#45-running-queries)
5. [LeanVec Compression](#5-leanvec-compression)
   - 5.1 [How LeanVec Works](#51-how-leanvec-works)
   - 5.2 [Compression Parameters](#52-compression-parameters)
   - 5.3 [Memory Savings Estimates](#53-memory-savings-estimates)
   - 5.4 [Choosing a Compression Configuration](#54-choosing-a-compression-configuration)
   - 5.5 [Creating a Compressed Index](#55-creating-a-compressed-index)
6. [Performance Tuning](#6-performance-tuning)
   - 6.1 [Background Worker (Advanced)](#background-worker-advanced)
7. [Operational Considerations](#7-operational-considerations)
   - 7.1 [TRUNCATE](#truncate)
8. [Monitoring](#8-monitoring)
   - 8.1 [Server Log Messages](#server-log-messages)
9. [Troubleshooting](#9-troubleshooting)
10. [Appendix: Vamana vs. HNSW Comparison](#10-appendix-vamana-vs-hnsw-comparison)
11. [Reference: Parameter Summary](#11-reference-parameter-summary)

---

## 1. Overview

This guide covers the **Vamana** index access method and **LeanVec** compression that have been added to the pgvector extension. These features are powered by Intel's **Scalable Vector Search (SVS)** library.

### What is the Vamana Index?

The Vamana index is a graph-based approximate nearest neighbor (ANN) index, similar in concept to HNSW but using a different graph construction strategy (originating from Microsoft Research's DiskANN). Key properties:

- **High recall** at competitive query latencies
- **AVX-512 optimized** — delivers best throughput on Intel Xeon processors (such as those in AWS `r7i` and `c7i` instance families)
- **Dynamic index** — the index is built from the initial table data and supports incremental updates: INSERT adds vectors to the live graph immediately via `SVSAddPoints`, and DELETE + VACUUM removes vectors via `SVSDeletePoints` with automatic graph consolidation (see [Section 7](#7-operational-considerations))
- **On-disk persistence** — the SVS graph is serialized directly to files on the filesystem (via the SVS `save`/`load` API); TID mappings are stored separately in PostgreSQL pages. Both are reloaded automatically on restart

### What is LeanVec Compression?

LeanVec is an optional compression scheme that significantly reduces the memory footprint of a Vamana index by combining:

1. **Dimensionality reduction** (similar to PCA) — projects high-dimensional vectors into a lower-dimensional space
2. **Integer quantization** — stores the projected vectors in 4-bit or 8-bit integers instead of 32-bit floats

LeanVec is ideal when your vectors have high dimensionality (e.g., 1536D from OpenAI embeddings) and memory is a limiting factor.

---

## 2. Prerequisites

- The `svs` extension (version **0.1.0 or later**) installed and enabled. This also installs the `vector` extension as a dependency:

```sql
CREATE EXTENSION IF NOT EXISTS svs;
```

- Verify the extension version:

```sql
SELECT extversion FROM pg_extension WHERE extname = 'svs';
-- Expected: 0.1.0
```

- An Intel Xeon processor instance is strongly recommended to benefit from AVX-512 optimizations. On AWS, the `r7i`, `c7i`, and `m7i` instance families qualify.

- **Optional — Background Worker:** If you plan to use the background search worker (see [Section 6](#background-worker-advanced)), add `svs` to `shared_preload_libraries` in `postgresql.conf` and restart the server:

  ```
  shared_preload_libraries = 'svs'
  ```

  This is required because the worker registers shared memory segments at server start — actions that cannot be performed after the server is already running. Without this, the extension still works fully (the worker is simply not available and all index searches run in-process).

---

## 3. Quick Start

This end-to-end example creates a table of document embeddings, populates it, builds a Vamana index, and runs a similarity search.

```sql
-- 1. Create a table with a 1536-dimensional embedding column
CREATE TABLE documents (
    id      bigserial PRIMARY KEY,
    content text,
    embedding vector(1536)
);

-- 2. Insert some rows (embeddings are produced by your application)
INSERT INTO documents (content, embedding)
VALUES
    ('Introduction to databases', '[0.1, 0.2, ...]'),
    ('Vector similarity search',  '[0.3, 0.1, ...]');

-- 3. Build a Vamana index for cosine-distance similarity
CREATE INDEX documents_vamana_idx
    ON documents
    USING vamana (embedding vector_cosine_ops);

-- 4. Query the five most similar documents to a query vector
SELECT id, content,
       1 - (embedding <=> '[0.2, 0.1, ...]') AS similarity
FROM documents
ORDER BY embedding <=> '[0.2, 0.1, ...]'
LIMIT 5;
```

---

## 4. Vamana Index in Depth

### 4.1 Supported Vector Types and Distance Metrics

| Vector Type  | L2 Distance (`<->`) | Inner Product (`<#>`) | Cosine Distance (`<=>`) |
|-------------|:-------------------:|:--------------------:|:-----------------------:|
| `vector`    | `vector_l2_ops`     | `vector_ip_ops`      | `vector_cosine_ops`     |
| `halfvec`   | `halfvec_l2_ops`    | `halfvec_ip_ops`     | `halfvec_cosine_ops`    |

> **Maximum dimensions:** 2000 for the Vamana index.

> **NULL vectors:** Rows with a `NULL` value in the indexed column are silently skipped at index build and insert time — they are not added to the graph. A `NULL` query vector returns zero results immediately without scanning the index.

> **Zero vectors and cosine distance:** A zero vector has no direction, so cosine distance (which normalizes by the vector's magnitude) produces `NaN` when either the stored or query vector is all zeros. Avoid storing or querying with zero vectors when using `vector_cosine_ops` or `halfvec_cosine_ops`.

### 4.2 Index Build Parameters

These parameters are specified in the `WITH (...)` clause of `CREATE INDEX` and are stored permanently with the index.

| Parameter | Type | Default | Range | Description |
|-----------|------|---------|-------|-------------|
| `graph_degree` | integer | `64` | 16 – 256 | Maximum number of neighbors per graph node. Higher values improve recall but increase build time and memory. |
| `alpha` | integer | `-1` | -1 – 200 | Graph pruning aggressiveness, stored as `alpha × 100` (e.g., `120` = α 1.20). `-1` uses the SVS library default (~1.2). |
| `build_window_size` | integer | `-1` | -1 – 1000 | Search window used during graph construction. `-1` defaults to `2 × graph_degree`. |
| `search_window_size` | integer | `100` | 10 – 10000 | Stored with the index. At query time the `vamana.search_window_size` GUC always governs behavior; because the GUC minimum is 10, this reloption is not used as a query-time fallback in the current implementation. |
| `use_search_history` | boolean | `true` | — | Maintain a visited-node set during graph search. Keeping this enabled (`true`) improves recall; disabling it may reduce per-query memory usage at some recall cost. Not changeable at query time — must be set at index creation. |
| `compression_type` | integer | `0` | 0 – 2 | `0` = none, `1` = LeanVec, `2` = LVQ (reserved). |
| `compression_primary` | integer | `8` | see §5.2 | Primary quantization precision for LeanVec. |
| `compression_secondary` | integer | `8` | see §5.2 | Secondary quantization precision for LeanVec. |
| `leanvec_dims` | integer | `-1` | -1 – 2000 | Reduced dimensions for LeanVec. `-1` = `dimensions / 2`. |

### 4.3 Query-Time Parameters

These are session-scoped GUC parameters that can be changed at any time without rebuilding the index.

```sql
-- Increase the search window for higher recall (at the cost of latency)
SET vamana.search_window_size = 200;

-- Restore to the default (100)
RESET vamana.search_window_size;
```

Use `SET LOCAL` inside a transaction to apply a setting for a single query only:

```sql
BEGIN;
SET LOCAL vamana.search_window_size = 200;
SELECT id FROM my_table ORDER BY embedding <=> '[...]' LIMIT 10;
COMMIT;
```

| GUC | Default | Range | Description |
|-----|---------|-------|-------------|
| `vamana.search_window_size` | `100` | 10 – 10000 | Number of candidates examined during a search. Higher = better recall, higher latency. |
| `vamana.search_num_threads` | `0` | 0 – 1024 | Number of SVS threads used per search. `0` = auto (resolves to `nproc - 1`). Set to a lower value to reduce CPU oversubscription in concurrent workloads. |

> The session GUC takes precedence over the `search_window_size` index reloption whenever it is set. There is currently no special "disable" value (such as `0`); to stop overriding and return to the default behavior, use `RESET vamana.search_window_size`.

### 4.4 Creating an Index

**Minimal index (all defaults):**

```sql
CREATE INDEX ON my_table USING vamana (embedding vector_cosine_ops);
```

**Tuned for high recall on large datasets:**

```sql
CREATE INDEX my_idx
    ON my_table
    USING vamana (embedding vector_cosine_ops)
    WITH (
        graph_degree = 96,           -- denser graph for higher recall
        build_window_size = 192,     -- wider search window during build
        search_window_size = 150     -- default query window
    );
```

**Parallel index build** — SVS manages its own internal thread pool. The number of threads is controlled by `max_parallel_maintenance_workers`:
- When `max_parallel_maintenance_workers = 0` (the PostgreSQL default), SVS automatically uses `nproc - 1` threads, reserving one CPU for the PostgreSQL backend — this is optimal for most deployments.
- When set to a positive value, that value is passed directly to SVS as its build thread count.

```sql
-- Default (0): SVS auto-selects nproc-1 threads — no action needed
CREATE INDEX my_idx ON my_table USING vamana (embedding vector_l2_ops);

-- Explicitly limit threads (e.g. in a shared environment)
SET max_parallel_maintenance_workers = 4;
CREATE INDEX my_idx ON my_table USING vamana (embedding vector_l2_ops);
```

> **Note (prototype limitation):** `maintenance_work_mem` does not currently affect Vamana index builds; SVS manages its own memory allocation internally. A future release will pass `maintenance_work_mem` to the SVS API so that builds respect the configured memory limit.

### 4.5 Running Queries

Vamana is activated automatically when PostgreSQL uses the index for `ORDER BY … LIMIT` queries:

```sql
-- Top-5 nearest neighbors by L2 distance
SELECT id, embedding <-> '[…]' AS distance
FROM my_table
ORDER BY embedding <-> '[…]'
LIMIT 5;

-- Top-10 most similar by cosine similarity
SELECT id, 1 - (embedding <=> '[…]') AS similarity
FROM my_table
ORDER BY embedding <=> '[…]'
LIMIT 10;

-- Inner product similarity (for normalized embeddings)
SELECT id, (embedding <#> '[…]') * -1 AS score
FROM my_table
ORDER BY embedding <#> '[…]'
LIMIT 5;
```

Confirm the index is being used:

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM my_table
ORDER BY embedding <=> '[…]'
LIMIT 5;
-- Look for "Index Scan using my_idx" in the output
```

---

## 5. LeanVec Compression

### 5.1 How LeanVec Works

Without compression, each vector is stored as a contiguous array of 32-bit floats — a 1536-dimensional vector occupies 6 KB. LeanVec reduces this in two steps:

```
Original D-dim float32 vectors
          │
          ▼  Step 1: Dimensionality reduction (PCA-like linear projection)
  Reduced d-dim vectors  (d = leanvec_dims, default D/2)
          │
          ▼  Step 2: Quantization
  Primary quantized vectors  (4-bit or 8-bit integers)
  + Secondary quantized residuals (4-bit or 8-bit integers)
```

During search, the compressed representation is used for candidate filtering. The full graph topology is preserved, so recall is determined by `graph_degree` and `search_window_size` as usual.

### 5.2 Compression Parameters

#### `compression_type`

| Value | Meaning |
|-------|---------|
| `0`   | No compression (default) |
| `1`   | LeanVec (dimensionality reduction + quantization) |
| `2`   | LVQ — reserved for future use |

#### `compression_primary` and `compression_secondary`

Both parameters accept exactly four values:

| Value | Data Type | Bits per element |
|-------|-----------|-----------------|
| `4`   | UINT4 (unsigned 4-bit) | 4 |
| `-4`  | INT4  (signed 4-bit)   | 4 |
| `8`   | UINT8 (unsigned 8-bit) | 8 |
| `-8`  | INT8  (signed 8-bit)   | 8 |

**Constraint:** `abs(compression_primary) ≤ abs(compression_secondary)`. For example:
- ✅ primary=`4`, secondary=`4`
- ✅ primary=`4`, secondary=`8`
- ✅ primary=`8`, secondary=`8`
- ❌ primary=`8`, secondary=`4` — invalid

**Rule of thumb:** Use unsigned types (`4`, `8`) unless your vectors contain negative values and you want to preserve the sign bit explicitly.

#### `leanvec_dims`

| Value | Meaning |
|-------|---------|
| `-1`  | Automatically use `original_dimensions / 2` |
| `1` to `2000` | Explicit reduced dimension count (must be < original dimensions) |

More aggressive reduction (smaller `leanvec_dims`) saves more memory but may reduce recall. The default of `D/2` is a good starting point for most embedding models.

### 5.3 Memory Savings Estimates

For a 1536-dimensional `vector` column:

| Configuration | Bytes per vector | Compression ratio (vs raw float32) |
|---------------|-----------------|-------------------------------------|
| No compression (float32) | 6,144 | 1× |
| UINT8 + UINT8, leanvec_dims=768 | ~1,536 | ~4× |
| UINT4 + UINT8, leanvec_dims=768 | ~1,152 | ~5.3× |
| UINT4 + UINT4, leanvec_dims=768 | ~768   | ~8× |
| UINT4 + UINT4, leanvec_dims=256 | ~256   | ~24× |

> These are approximate index-side storage estimates. The PostgreSQL heap row storing the full vector is not compressed.

### 5.4 Choosing a Compression Configuration

| Goal | Recommended Configuration |
|------|--------------------------|
| Baseline — minimal memory reduction with negligible accuracy loss | `compression_type=1`, `compression_primary=8`, `compression_secondary=8` |
| Balanced — good memory savings, acceptable recall trade-off | `compression_type=1`, `compression_primary=4`, `compression_secondary=8` |
| Maximum compression — smallest index, higher recall trade-off | `compression_type=1`, `compression_primary=4`, `compression_secondary=4`, `leanvec_dims=256` |
| Large embeddings (≥2048D), targeting ~4× reduction | `compression_type=1`, `compression_primary=8`, `compression_secondary=8`, `leanvec_dims=-1` |

Always measure recall on a representative dataset sample before deploying a heavily compressed index in production.

### 5.5 Creating a Compressed Index

**Baseline LeanVec (8-bit, auto dimensions):**

```sql
CREATE INDEX documents_vamana_leanvec_idx
    ON documents
    USING vamana (embedding vector_cosine_ops)
    WITH (
        graph_degree = 64,
        compression_type = 1        -- enable LeanVec
        -- compression_primary   = 8  (default)
        -- compression_secondary = 8  (default)
        -- leanvec_dims          = -1 means dimensions/2 (default)
    );
```

**High compression (4-bit primary and secondary):**

```sql
CREATE INDEX documents_vamana_hc_idx
    ON documents
    USING vamana (embedding vector_cosine_ops)
    WITH (
        graph_degree = 64,
        compression_type = 1,
        compression_primary = 4,
        compression_secondary = 4
    );
```

**Mixed precision (4-bit primary, 8-bit residual — balanced accuracy vs. memory):**

```sql
CREATE INDEX documents_vamana_mixed_idx
    ON documents
    USING vamana (embedding vector_cosine_ops)
    WITH (
        graph_degree = 64,
        compression_type = 1,
        compression_primary = 4,
        compression_secondary = 8
    );
```

**Aggressive dimensionality reduction (explicit `leanvec_dims`):**

```sql
-- 1536D embeddings reduced to 256 dimensions, then 8-bit quantized
CREATE INDEX documents_vamana_agr_idx
    ON documents
    USING vamana (embedding vector_cosine_ops)
    WITH (
        graph_degree = 96,
        compression_type = 1,
        leanvec_dims = 256,
        compression_primary = 8,
        compression_secondary = 8
    );
```

---

## 6. Performance Tuning

### Recall vs. Latency Trade-offs

The core knob is `search_window_size`. A larger value scans more candidates and improves recall, but increases query time.

```sql
-- Quick experiment: measure recall@10 at three search window sizes
SET vamana.search_window_size = 50;   -- fast, lower recall
-- run your benchmark query

SET vamana.search_window_size = 100;  -- default
-- run your benchmark query

SET vamana.search_window_size = 200;  -- slower, higher recall
-- run your benchmark query
```

### Build Quality vs. Build Time

| `graph_degree` | `build_window_size`  | Recall | Build time |
|---------------|---------------------|--------|------------|
| 32            | 64 (default)        | Moderate | Fast |
| 64 (default)  | 128 (default)       | Good     | Moderate |
| 96            | 192                 | High     | Slow |

**General guidance:**
- For interactive search (`p99 < 10 ms`): start with `graph_degree=64`, `search_window_size=100` and tune up.
- For batch / offline retrieval: use `graph_degree=96` or `128` and higher `search_window_size`.
- LeanVec with 4-bit quantization can require a slightly larger `search_window_size` to achieve the same recall as uncompressed.

### Parallel Builds

SVS manages its own internal thread pool for index builds. The thread count is governed by `max_parallel_maintenance_workers`:

- `0` (PostgreSQL default) → SVS uses `nproc - 1` threads automatically (one CPU reserved for the PG backend). This is already optimal for dedicated build hosts.
- Positive value → passed directly to SVS as its build thread count. Use this to limit resource usage in shared environments.

```sql
-- Let SVS auto-select threads (nproc-1) — recommended default
CREATE INDEX … USING vamana (…);

-- Explicitly cap threads in a shared environment
SET max_parallel_maintenance_workers = 4;
CREATE INDEX … USING vamana (…);
```

> **Note:** Unlike HNSW, there is no separate PostgreSQL leader thread — the value is used directly as the SVS thread pool size. Search threads are always capped at `nproc - 1` regardless of this setting.

### Background Worker (Advanced)

The extension includes an optional background worker that holds all Vamana indexes in a single process and serves search requests from every backend via shared memory. This avoids per-backend index loads and can significantly improve throughput under high concurrency.

**Prerequisite:** The background worker only starts when the extension is loaded via `shared_preload_libraries`. Add the following to `postgresql.conf` and restart:

```
shared_preload_libraries = 'svs'
vamana.worker_enabled = on
vamana.worker_database = 'mydb'   # database where your Vamana indexes live
```

`shared_preload_libraries` is required because the worker registers shared memory segments and a background process at server start. Loading the extension later via `CREATE EXTENSION` does not start the worker.

**Startup and fallback GUCs** (`postgresql.conf`, require restart — `PGC_POSTMASTER`):

| GUC | Default | Description |
|-----|---------|-------------|
| `vamana.worker_enabled` | `false` | Enable the background search worker. |
| `vamana.worker_database` | `'postgres'` | Database the worker connects to. Set this to the database where your Vamana indexes are created; the default `'postgres'` is only correct if that is where your indexes live. |

**Runtime-tunable GUCs** (`postgresql.conf` or `pg_reload_conf()` — `PGC_SIGHUP`, no restart needed):

| GUC | Default | Range | Description |
|-----|---------|-------|-------------|
| `vamana.worker_timeout_ms` | `5000` | 100 – 60000 | Milliseconds a backend waits for the worker before falling back to a direct (in-process) load. |
| `vamana.max_batch_size` | `0` | 0 – 1000 | Maximum queries per SVS batch call. `0` = use `MaxBackends` (PostgreSQL's configured backend limit). |

**Fallback behavior:** If the worker does not respond within `vamana.worker_timeout_ms`, the backend automatically falls back to loading and searching the index in-process (the same path used when the worker is disabled). A `LOG`-level message is emitted when the fallback triggers.

**Multi-database note:** The worker connects to a single database (`vamana.worker_database`). If you have Vamana indexes in multiple databases, only indexes in the configured database are served by the worker; backends accessing other databases always fall back to in-process search.

> **Prototype status:** The background worker is not yet recommended for production use. Benchmarking is advised before enabling it.

---

## 7. Operational Considerations

### Inserts, Updates, and Deletes

**INSERT** operations are applied incrementally to the live index graph. New rows are searchable immediately without `REINDEX`:

```sql
INSERT INTO documents (content, embedding) VALUES ('new doc', '[0.4, 0.5, ...]');
-- The new row is immediately searchable
SELECT id FROM documents ORDER BY embedding <=> '[0.4, 0.5, ...]' LIMIT 5;
```

**UPDATE** of an indexed vector column is handled as a DELETE + INSERT internally by PostgreSQL. The old vector is removed from the graph and the new vector is added.

**DELETE** removes heap rows but does not immediately update the index graph. Run `VACUUM` to remove deleted vectors from the index:

```sql
DELETE FROM documents WHERE id = 42;
VACUUM documents;  -- removes deleted vectors from the index graph
```

VACUUM performs three operations on the index:
1. Identifies dead TIDs and calls `SVSDeletePoints` to soft-delete them from the graph
2. Runs `SVSConsolidate` to patch graph edges around deleted entries
3. If more than 10% of vectors have been deleted, runs `SVSCompact` to reclaim memory

**REINDEX** rebuilds the entire index from scratch. Use it when you want a clean graph after a large number of inserts and deletes:

```sql
REINDEX INDEX CONCURRENTLY documents_vamana_idx;
```

**Cold-cache fallback:** If an INSERT arrives before any query has loaded the index into memory (e.g., immediately after a server restart), the insert falls back to cache invalidation and the next query triggers a full rebuild. Subsequent inserts then use the incremental path.

### TRUNCATE

> **Known limitation (see [issue #92](https://github.com/intel-innersource/applications.databases.postgresql.pgvector-optimizations/issues/92)):** `TRUNCATE` resets the index metapage but does **not** invalidate the in-memory Vamana index cache. Backends that have the index cached will continue to query the stale pre-TRUNCATE SVS index, which can return incorrect results.

After `TRUNCATE`, run `REINDEX` to flush the cache and restore correct behavior:

```sql
TRUNCATE documents;
REINDEX INDEX documents_vamana_idx;
```

Until the bug is fixed, do not rely on post-TRUNCATE queries returning empty results without a preceding `REINDEX`.

### VACUUM

VACUUM reclaims space from deleted heap rows and removes deleted vectors from the Vamana index graph. Run it regularly:

```sql
VACUUM ANALYZE documents;
```

### Disk Space for On-Disk Persistence

The Vamana index graph is serialized directly to files on the filesystem (not PostgreSQL data pages). TID mappings are stored in PostgreSQL pages separately. Disk space usage approximately scales as:

```
Disk ≈ N × graph_degree × 8 bytes (neighbor list)
     + N × D × sizeof(stored_element)
```

With LeanVec compression, the stored element size is much smaller than `D × 4 bytes`.

### PostgreSQL Restart / Crash Recovery

The SVS index is automatically reloaded from disk on first access after a restart. There is no data loss. The first query on each backend after a restart will incur a one-time load latency proportional to index size.

---

## 8. Monitoring

### Build Progress

```sql
-- Monitor index build progress (poll every few seconds)
SELECT phase, blocks_done, blocks_total,
       tuples_done, tuples_total
FROM pg_stat_progress_create_index
WHERE relid = 'documents'::regclass;
```

Phases:
- `initializing` — setting up build state
- `loading tuples` — buffering vectors from heap

### Server Log Messages

The extension emits `LOG`-level messages to the PostgreSQL server log during long operations. These appear in the server log (not in the client session) and help diagnose what is happening during slow queries or builds.

| Situation | Log message |
|-----------|-------------|
| Index load triggered (first access / after restart) | `loading vamana index <oid> from "<path>"` |
| TID map being loaded | `vamana index <oid>: loading TID map for N vectors` |
| Index fully loaded from disk | `vamana index <oid> loaded from disk (N vectors)` |
| Cache miss — rebuilding in-process | `vamana index not in memory, rebuilding from table` |
| Rebuild started | `rebuilding vamana index from table data` |
| Rebuild scan progress (every 100,000 tuples) | `vamana index <oid>: scanning table, N vectors collected` |
| Worker fallback triggered | `vamana fallback: no saved copy for index <oid>, rebuilding from table` |

To see these messages in `psql`, ensure your client is connected to a session where `client_min_messages = log` (not the default). They are always written to the PostgreSQL log file regardless of client settings.

```sql
-- Temporarily surface LOG messages in the client session
SET client_min_messages = log;
SELECT id FROM my_table ORDER BY embedding <=> '[…]' LIMIT 1;
RESET client_min_messages;
```

### Index Size

```sql
SELECT pg_size_pretty(pg_relation_size('documents_vamana_idx')) AS index_size;

-- Compare compressed vs uncompressed
SELECT indexname,
       pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
FROM pg_indexes
WHERE tablename = 'documents';
```

### Inspect Index Options

```sql
-- View stored reloptions for a Vamana index
SELECT relname, reloptions
FROM pg_class
WHERE relname = 'documents_vamana_idx';
```

---

## 9. Troubleshooting

### Index not being used by the planner

**Cause:** The Vamana index only supports `ORDER BY … LIMIT` queries (nearest-neighbor scans). PostgreSQL will use a sequential scan instead if:
- There is no `LIMIT` clause
- The query does not use a supported distance operator (`<->`, `<#>`, `<=>`)
- The planner estimates a sequential scan is cheaper (common on small tables)

**Diagnose:**

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT id FROM my_table ORDER BY embedding <=> '[...]' LIMIT 10;
-- Look for "Index Scan using ..." — if absent, the index is not being used
```

**Fix:** Force index use to confirm it works, then investigate the planner's cost estimate:

```sql
SET enable_seqscan = off;
SELECT id FROM my_table ORDER BY embedding <=> '[...]' LIMIT 10;
RESET enable_seqscan;
```

### Error: `invalid compression_primary value: X`

**Cause:** `compression_primary` is not one of the four allowed values.  
**Fix:** Use only `4` (UINT4), `-4` (INT4), `8` (UINT8), or `-8` (INT8).

### Error: `invalid compression_secondary value: X`

**Cause:** Same as above.  
**Fix:** Same as above.

### Error: `compression_primary (8-bit) cannot have higher precision than compression_secondary (4-bit)`

**Cause:** `abs(compression_primary) > abs(compression_secondary)`.  
**Fix:** Ensure primary precision ≤ secondary precision, e.g., primary=`4`, secondary=`8`.

### Error: `value X out of bounds for option "compression_type"`

**Cause:** `compression_type` is outside `[0, 2]`.  
**Fix:** Use `0` (none), `1` (leanvec), or `2` (lvq).

### Unexpected recall with large `leanvec_dims`

**Cause:** `leanvec_dims` is not validated against the actual vector dimension at index creation time. If you set `leanvec_dims` to a value ≥ your vector dimension, the SVS library will receive that value and may behave unexpectedly.
**Fix:** Set `leanvec_dims` to a value strictly less than your vector dimension, or use `-1` for automatic (`dimensions / 2`).

### New rows not appearing in search results after INSERT

**Cause:** If the index was not yet loaded into the backend's cache when the INSERT arrived (e.g., first INSERT after a server restart), the insert falls back to cache invalidation instead of the incremental path. The next query triggers a full rebuild from the table.
**Fix:** Run a query first to warm the cache, then insert. Alternatively, run `REINDEX INDEX CONCURRENTLY <index_name>;` to rebuild.

### Low recall after compression

**Cause:** Aggressive compression (small `leanvec_dims` or 4-bit quantization) can reduce recall.  
**Fix:** Increase `search_window_size` at query time, or rebuild with less aggressive compression settings (larger `leanvec_dims`, or switch to 8-bit).

### Slow first query after restart

**Cause:** The index graph is loaded from disk on first access.  
**Fix:** "Warm up" the index after restart by running a representative query:

```sql
-- Warm-up query (results can be discarded)
SELECT id FROM documents
ORDER BY embedding <=> '[0,0,0,…]'
LIMIT 1;
```

---

## 10. Appendix: Vamana vs. HNSW Comparison

If your workload already uses the HNSW index, this table helps you decide whether to migrate to Vamana.

| Feature | HNSW | Vamana |
|---------|------|--------|
| Graph structure | Hierarchical multi-layer | Single-layer |
| Memory (uncompressed) | High | Medium |
| Memory (compressed) | Not supported | Low — with LeanVec |
| Parallel build model | PostgreSQL worker processes | SVS-managed OS threads |
| Shared memory required for build | Yes | No |
| Incremental inserts update graph | Yes | Yes (via SVS dynamic API) |
| Intel AVX-512 optimization | No | Yes |
| Supported distance metrics | L2, inner product, cosine, L1 | L2, inner product, cosine |
| Max dimensions | 2000 | 2000 |

### Expected Performance Characteristics

> **Note:** The figures below are indicative estimates based on internal benchmarks on Intel Xeon hardware. Actual results will vary by instance type, dataset, and configuration.

| Metric | Estimate vs. HNSW baseline |
|--------|----------------------------|
| Build time | ~30–50% faster |
| Query latency (same recall) | ~15–30% lower |
| Memory footprint with LeanVec | ~40–60% reduction |
| Query throughput on Intel Xeon | ~2–3× higher QPS |

**Build time breakdown** (approximate, 1 million 1536D vectors, 4 threads):

| Phase | Estimated time |
|-------|----------------|
| Table scan + vector buffering | ~30 s |
| SVS graph construction | ~90 s |
| Serialize index to disk | ~20 s |
| **Total** | **~140 s** |

### Parameter Migration from HNSW

| HNSW parameter | Vamana equivalent | Notes |
|----------------|-------------------|-------|
| `m` | `graph_degree` | Max neighbors per node |
| `ef_construction` | `build_window_size` | Search window during build |
| `hnsw.ef_search` (GUC) | `vamana.search_window_size` (GUC) | Runtime query beam width |

---

## 11. Reference: Parameter Summary

### Index Build Parameters (`CREATE INDEX … WITH (…)`)

| Parameter | Default | Min | Max | Notes |
|-----------|---------|-----|-----|-------|
| `graph_degree` | `64` | `16` | `256` | Max neighbors per node |
| `alpha` | `-1` | `-1` | `200` | Pruning factor × 100; -1 = SVS default |
| `build_window_size` | `-1` | `-1` | `1000` | Build search window; -1 = 2×graph_degree |
| `search_window_size` | `100` | `10` | `10000` | Default query window (always governed by `vamana.search_window_size` GUC at runtime) |
| `use_search_history` | `true` | — | — | Maintain visited-node set during search; improves recall |
| `compression_type` | `0` | `0` | `2` | 0=none, 1=leanvec, 2=lvq (reserved) |
| `compression_primary` | `8` | — | — | One of: 4, -4, 8, -8 |
| `compression_secondary` | `8` | — | — | One of: 4, -4, 8, -8; ≥ primary precision |
| `leanvec_dims` | `-1` | `-1` | `2000` | Reduced dims; -1 = dimensions/2 |

### Session GUC Parameters (`SET …`)

| GUC | Default | Min | Max | Notes |
|-----|---------|-----|-----|-------|
| `vamana.search_window_size` | `100` | `10` | `10000` | Governs query-time search window size; always takes effect (the `search_window_size` index reloption is not used as a fallback in the current implementation) |
| `vamana.search_num_threads` | `0` | `0` | `1024` | SVS threads per search; 0 = auto (nproc-1) |

### Server GUC Parameters (require restart — `postgresql.conf` only, `PGC_POSTMASTER`)

| GUC | Default | Notes |
|-----|---------|-------|
| `vamana.worker_enabled` | `false` | Enable background search worker |
| `vamana.worker_database` | `'postgres'` | Database the worker connects to; must match where indexes are created |

### Runtime-tunable Server GUC Parameters (`PGC_SIGHUP` — reload with `SELECT pg_reload_conf()`)

| GUC | Default | Min | Max | Notes |
|-----|---------|-----|-----|-------|
| `vamana.worker_timeout_ms` | `5000` | `100` | `60000` | Worker response timeout (ms) before in-process fallback |
| `vamana.max_batch_size` | `0` | `0` | `1000` | Max queries per SVS batch call; 0 = MaxBackends |

### Operator Classes

| Vector Type | Operator Class | Distance Operator | Metric |
|-------------|---------------|-------------------|--------|
| `vector` | `vector_l2_ops` | `<->` | Euclidean (L2) |
| `vector` | `vector_ip_ops` | `<#>` | Inner product |
| `vector` | `vector_cosine_ops` | `<=>` | Cosine distance |
| `halfvec` | `halfvec_l2_ops` | `<->` | Euclidean (L2) |
| `halfvec` | `halfvec_ip_ops` | `<#>` | Inner product |
| `halfvec` | `halfvec_cosine_ops` | `<=>` | Cosine distance |

> **Note on `<#>`:** PostgreSQL index scans only support ascending order, so `<#>` internally returns the *negative* inner product to allow `ORDER BY … ASC` to retrieve the highest-scoring vectors. When displaying the score, multiply by `-1`: `(embedding <#> query) * -1 AS score`.


