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
   - 6.1 [Background Workers and Per-Database Enablement (Advanced)](#61-background-workers-and-per-database-enablement-advanced)
7. [Operational Considerations](#7-operational-considerations)
   - 7.1 [Pausing vs. Removing a Database](#pausing-vs-removing-a-database)
   - 7.2 [TRUNCATE](#truncate)
   - 7.3 [Security and Deployment Notes](#security-and-deployment-notes)
8. [Monitoring](#8-monitoring)
   - 8.1 [Worker Status](#worker-status)
   - 8.2 [Server Log Messages](#server-log-messages)
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
- **On-disk persistence** — the SVS graph and TID mappings are serialized directly to files on the filesystem (via the SVS `save`/`load` API and atomic checkpoint sequence). Both are reloaded automatically on restart

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

- **Required — Background Workers:** Background workers must be running for all Vamana operations (search, INSERT, DELETE+VACUUM). Add `svs` to `shared_preload_libraries` in `postgresql.conf` and restart the server:

  ```
  shared_preload_libraries = 'svs'
  ```

  This is required because the extension registers shared memory segments and a supervisor process (the *launcher*) at server start — actions that cannot be performed after the server is already running. Without this, no workers start and all index reads and writes will return an error.

- **Required — Enable your database:** Each database that hosts Vamana indexes must be enrolled in the `vamana_databases` table so the launcher spawns a worker for it. Enrollment takes effect immediately, with no restart:

  ```sql
  -- Run this in the launcher's database (default: postgres)
  INSERT INTO vamana_databases (datname) VALUES ('mydb');
  ```

  See [Section 6.1](#61-background-workers-and-per-database-enablement-advanced) for the full model. A `CREATE INDEX ... USING vamana` in a database that is not enabled fails immediately with an actionable error.

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

**Behavioral highlights:**

| Aspect | Behavior |
|---|---|
| `INSERT` | Vector added to the live graph immediately; next `SELECT` serves from the updated index |
| `DELETE` + `VACUUM` | Vectors soft-deleted, graph edges patched, memory reclaimed when deletion pressure exceeds threshold |
| `REINDEX` needed for correctness? | No |

**Edge cases to know about:**

- Indexes are loaded on demand, not eagerly at worker startup. The first `SELECT`, `INSERT`, or `VACUUM` touching a given index after a server restart pays that index's load cost; subsequent operations serve from the warm cache. To pre-warm deliberately, call `svs_warmup_index()` or `svs_warmup_database()` (see [Section 6.1](#61-background-workers-and-per-database-enablement-advanced)).
- Writes are serialized per index inside the worker. For high-concurrency ingest, batch rows in multi-row `INSERT` statements from a single backend to reduce contention.
- Deletes are soft: `VACUUM` marks entries deleted, patches graph edges, and compacts when deletion pressure exceeds `svs.compact_threshold_pct` (default 10%).
- External IDs are never reused for the life of the index. `REINDEX` resets the counter.

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
| `search_window_size` | integer | `100` | 10 – 10000 | Stored with the index. At query time the `svs.search_window_size` GUC always governs behavior; because the GUC minimum is 10, this reloption is not used as a query-time fallback in the current implementation. |
| `use_search_history` | boolean | `true` | — | Maintain a visited-node set during graph search. Keeping this enabled (`true`) improves recall; disabling it may reduce per-query memory usage at some recall cost. Not changeable at query time — must be set at index creation. |
| `compression_type` | integer | `0` | 0 – 2 | `0` = none, `1` = LeanVec, `2` = LVQ (reserved). |
| `compression_primary` | integer | `8` | see §5.2 | Primary quantization precision for LeanVec. |
| `compression_secondary` | integer | `8` | see §5.2 | Secondary quantization precision for LeanVec. |
| `leanvec_dims` | integer | `-1` | -1 – 2000 | Reduced dimensions for LeanVec. `-1` = `dimensions / 2`. |

### 4.3 Query-Time Parameters

These are session-scoped GUC parameters that can be changed at any time without rebuilding the index. `svs.search_window_size` is settable by any role; `svs.search_num_threads` requires superuser (`PGC_SUSET`).

```sql
-- Increase the search window for higher recall (at the cost of latency)
SET svs.search_window_size = 200;

-- Restore to the default (100)
RESET svs.search_window_size;
```

Use `SET LOCAL` inside a transaction to apply a setting for a single query only:

```sql
BEGIN;
SET LOCAL svs.search_window_size = 200;
SELECT id FROM my_table ORDER BY embedding <=> '[...]' LIMIT 10;
COMMIT;
```

| GUC | Default | Range | Description |
|-----|---------|-------|-------------|
| `svs.search_window_size` | `100` | 10 – 10000 | Number of candidates examined during a search. Higher = better recall, higher latency. |
| `svs.search_num_threads` | `0` | 0 – 1024 | Number of SVS threads used per search. `0` = auto (resolves to `nproc - 1`). Set to a lower value to reduce CPU oversubscription in concurrent workloads. Requires superuser to set (`PGC_SUSET`). |

> The session GUC takes precedence over the `search_window_size` index reloption whenever it is set. There is currently no special "disable" value (such as `0`); to stop overriding and return to the default behavior, use `RESET svs.search_window_size`.

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

### Training Data Requirement

LeanVec and LVQ use the vectors present at index creation time as training data for their compression matrices. Building an index on a table with very few rows produces an index with poor recall (no error is raised).

Recommended minimums before `CREATE INDEX`:
- **LeanVec** (`compression_type = 1`): 100,000 rows (10,000 minimum)
- **LVQ** (`compression_type = 2`): 10,000 rows

A WARNING is emitted at build time if the row count is below these thresholds. To fix, load more data and run `REINDEX INDEX`.

```sql
-- Example: WARNING fires because the table has only 100 rows
CREATE INDEX ON docs USING vamana (embedding vector_cosine_ops)
  WITH (compression_type = 1);
-- WARNING:  building LeanVec index with only 100 vectors;
--           recall may be poor (recommend >= 100000, minimum 10000)
```

The same WARNING fires during cold-start index rebuilds from the heap.

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
SET svs.search_window_size = 50;   -- fast, lower recall
-- run your benchmark query

SET svs.search_window_size = 100;  -- default
-- run your benchmark query

SET svs.search_window_size = 200;  -- slower, higher recall
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

### 6.1 Background Workers and Per-Database Enablement (Advanced)

The extension serves every Vamana operation through background workers. A worker owns the in-memory SVS graph for all Vamana indexes in one database: all write operations (INSERT, DELETE+VACUUM, consolidate, and compact) and all search requests are submitted to it by backends via shared-memory IPC and executed exclusively by the worker. This avoids per-backend index loads and enables high read concurrency.

#### The launcher and per-database workers

There is **one worker per database**, and a single supervisor process — the *launcher* — that starts, stops, restarts, and tracks them. The launcher is the only process registered at server start; every per-database worker is spawned dynamically. This means you can enable Vamana for a new database, pause it, or remove it entirely by changing a table, with no server restart and no `postgresql.conf` edit.

```
postmaster
  └── vamana launcher            (reads vamana_databases)
        └── vamana worker: mydb
        └── vamana worker: appdb
        └── ...
```

**Prerequisite:** The launcher only starts when the extension is loaded via `shared_preload_libraries`. Add the following to `postgresql.conf` and restart:

```
shared_preload_libraries = 'svs'
```

`shared_preload_libraries` is required because the extension registers shared memory segments and the launcher process at server start. Loading the extension later via `CREATE EXTENSION` does not start the launcher.

#### Enabling and disabling a database

Enablement lives in the `vamana_databases` table in the launcher's home database (`svs.launcher_database`, default `postgres`). The launcher reacts to changes within a fraction of a second.

```sql
-- Enable Vamana for a database (no restart). A worker is spawned within moments.
INSERT INTO vamana_databases (datname) VALUES ('mydb');

-- Pause it (reversible — see Section 7). The worker checkpoints and stops;
-- on-disk state and the replication slot are kept, idle.
UPDATE vamana_databases SET enabled = false WHERE datname = 'mydb';

-- Resume it. The worker restarts and picks up where it left off.
UPDATE vamana_databases SET enabled = true WHERE datname = 'mydb';
```

Enrollment reserves the database's worker slot **synchronously** at commit, so a `CREATE INDEX ... USING vamana` issued immediately afterward will not spuriously fail with a "not enabled" error. The worker itself spawns asynchronously a moment later; the first operation against an index waits (bounded by `svs.worker_startup_timeout_ms`) if the worker is still starting.

> **Do not use `enabled = false` then `true` to bounce a worker.** Use `svs_restart_worker()` instead (below). Two updates in one transaction never produce an intermediate state the launcher can observe, and disabling is the "take this database offline" signal, not a restart primitive.

#### Restarting a single worker on demand

To bounce one database's worker without taking the database offline — for example, to force a clean checkpoint and replication-slot advance right now rather than waiting for the debounced checkpoint policy:

```sql
SELECT svs_restart_worker('mydb');
```

This drains and cleanly stops the worker (checkpointing every cached index first) and respawns it. It raises an error if the named database is paused or not configured. Only enabled databases can be restarted. Internally it increments the row's `restart_generation` column; the launcher observes the change through its normal reconcile pass and bounces that worker.

#### Removing a database permanently

Pausing (`enabled = false`) and removal are **different** operations. Pausing is reversible and keeps on-disk state; removal is permanent. Removal is a deliberate two-step action — see [Section 7](#7-operational-considerations) for full details:

```sql
-- Step 1, connected to the target database: drop every Vamana index in it.
SELECT * FROM svs_teardown_database();

-- Step 2, connected to the launcher's database: remove the row.
DELETE FROM vamana_databases WHERE datname = 'mydb';
```

Running step 2 first is rejected: `DELETE` fails with an actionable hint if Vamana indexes still exist in that database, so on-disk save directories and replication slots are never orphaned.

#### Warming the cache

Because indexes load on demand, there is otherwise no way to get a hot cache without waiting on real query traffic. Force a warm cache deliberately, at a time you control (e.g. after a planned restart, or in a benchmark's load phase):

```sql
SELECT svs_warmup_index('documents_vamana_idx');  -- one index
SELECT svs_warmup_database();                      -- every Vamana index in this database
```

`svs_warmup_index()` errors if the argument is not a Vamana index or no worker is available. `svs_warmup_database()` is best-effort: per-index failures other than a privilege denial warn and are skipped; an index the caller lacks `SELECT` on is skipped silently. It returns the number of indexes warmed.

#### Capacity

`svs.max_databases` (default 8) sizes the fixed shared-memory array of worker slots at server start. Enabling more databases than this limit fails the `INSERT`/`UPDATE` with:

```
ERROR: cannot enable database "mydb": svs.max_databases (8) already reached
HINT:  increase svs.max_databases and restart, or disable another database first
```

Plan for your expected number of Vamana-enabled databases plus headroom, since changing this limit requires a server restart.

#### Configuration parameters

**Startup GUCs** (`postgresql.conf`, require restart — `PGC_POSTMASTER`):

| GUC | Default | Description |
|-----|---------|-------------|
| `svs.launcher_database` | `'postgres'` | Database the launcher connects to in order to read `vamana_databases`. Set once at install time. This is the only remaining GUC that names a specific database. |
| `svs.max_databases` | `8` | Maximum number of databases that can run a worker concurrently. Sizes the per-database shared-memory array. Range 1 – 128. |
| `svs.worker_restart_time` | `5` (s) | Seconds the postmaster waits before restarting the **launcher** if it crashes. `-1` disables auto-restart. Governs only the launcher, not per-database workers. Range -1 – 300. |

**Runtime-tunable GUCs** (`postgresql.conf` or `pg_reload_conf()` — `PGC_SIGHUP`, no restart needed):

| GUC | Default | Range | Description |
|-----|---------|-------|-------------|
| `svs.worker_startup_timeout_ms` | `60000` | 1000 – 300000 | Milliseconds a backend waits for a worker that is enabled but not yet started before returning an error. |
| `svs.worker_timeout_ms` | `5000` | 100 – 60000 | Milliseconds a backend waits for a worker IPC response before returning an error. |
| `svs.worker_restart_backoff` | `1000` (ms) | 100 – 300000 | Base delay before the launcher respawns a crashed **per-database** worker, applied with escalating backoff on repeated crashes of the same database's worker. |
| `svs.max_batch_size` | `0` | 0 – 1000 | Maximum queries per SVS batch call. `0` = use `MaxBackends`. |
| `svs.shutdown_drain_budget_ms` | `30000` | 0 – 600000 | Time budget for the worker's shutdown drain, checked between indexes. A single in-progress checkpoint is not preemptible, so the real bound is this budget plus one checkpoint's worst case. |
| `svs.worker_stop_timeout_ms` | `30000` | 0 – 600000 | Milliseconds the launcher waits for a restarting worker to report stopped before giving up. Does not force-kill; the restart stays pending until the worker exits naturally. |

> `svs.worker_restart_time` and `svs.worker_restart_backoff` govern two different restart policies deliberately: a fixed interval for the launcher itself (via the postmaster's native mechanism), and escalating backoff for per-database workers (a worker crash-looping on a corrupted index or an out-of-memory condition should not be respawned every second forever). They are not interchangeable.

**Crash handling:** If a per-database worker crashes, the launcher detects it near-instantly and respawns it, backing off exponentially on repeated crashes. If the launcher itself crashes, the postmaster restarts it, and it re-derives the full worker set from `vamana_databases`.

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

**Cold-cache behavior:** Indexes are loaded on demand, not eagerly at worker startup. The worker becomes available as soon as it connects to its database; the first operation touching a given index loads that index from its on-disk save (replaying any committed operations from the replication slot since the last checkpoint) before that operation proceeds. Subsequent operations serve from the warm cache. An operation that arrives while the worker is still starting waits until the worker signals it is ready, bounded by `svs.worker_startup_timeout_ms`. If no saved copy exists on disk, the worker rebuilds that index from the heap on first access. To warm a cold cache deliberately rather than on first query, use `svs_warmup_index()`/`svs_warmup_database()` (see [Section 6.1](#61-background-workers-and-per-database-enablement-advanced)).

### Pausing vs. Removing a Database

Disabling a database and removing it are different operations with different, well-defined effects. A DBA reasoning about "is it safe to leave this database like this" needs to know exactly what survives each:

| | Pause (`enabled = false`) | Permanent removal (teardown + `DELETE`) |
|---|---|---|
| Worker process | Stopped | Stopped |
| On-disk save directory | Kept | Deleted |
| Replication slot | Kept, idle, caught up | Dropped |
| Catalog row | Kept | Removed |
| Resumable? | Yes — re-enable and the worker resumes | No — indexes must be rebuilt |

**Pause** means "stop serving this database for now, but I may come back": a maintenance window, a cost-driven scale-down, a database quiet on weekends. When you set `enabled = false`, the worker checkpoints every cached index (flushing to disk and advancing the replication slot), then stops. At rest, no worker runs; the on-disk saves are current; the replication slot is present, inactive, and not accumulating WAL. Re-enabling later replays little or nothing. Nothing ever escalates a pause into removal — a long-paused database stays exactly paused until you act.

While paused, any query or write against a Vamana index in that database fails (after the startup timeout), rather than queuing quietly.

**Permanent removal** means "I am done with Vamana in this database." It is a deliberate two-step action, run in the two databases it affects (PostgreSQL has no cross-database DDL):

```sql
-- Step 1, connected to the target database: drops every Vamana index in it,
-- deleting each index's on-disk save directory and dropping its replication slot.
SELECT * FROM svs_teardown_database();

-- Step 2, connected to the launcher's database: stops the launcher running a
-- worker for it.
DELETE FROM vamana_databases WHERE datname = 'mydb';
```

`svs_teardown_database()` runs with **your own privileges** (not elevated), so it can only drop indexes you own; it returns one row per index reporting whether each was dropped and, if skipped, why. It does not abort on the first index you cannot drop — it continues and reports the mixed result. Each failed drop also emits a `WARNING` to the server log (mirroring the `reason` column of that row), so failures are visible in logs as well as in the result set.

**Order matters, and the wrong order is rejected.** Running step 2 first — `DELETE` while Vamana indexes still exist — fails immediately:

```
ERROR: cannot remove "mydb" from vamana_databases: 3 Vamana index(es) still exist in that database
HINT:  run svs_teardown_database() in "mydb" first
```

This guarantees on-disk save directories and replication slots are never orphaned with no catalog row pointing at them.

**Forgetting step 2 is safe, not harmful.** If you run teardown but never remove the row, the real cleanup already happened; what remains is only an idle worker serving zero indexes. It is wasteful (it holds one worker slot) but harmless, and it is surfaced via `pg_stat_vamana_worker` (`index_count = 0`) and a one-time server-log hint. The launcher deliberately does not auto-remove the row, since a database with zero indexes right now may simply be between `CREATE INDEX` calls.

> `TRUNCATE vamana_databases` is revoked from `PUBLIC` (the owner or a superuser retains it) because it would bypass the removal-safety check on every row at once. Use the two-step removal per database instead.

### TRUNCATE

`TRUNCATE` rebuilds every index on the table, including any Vamana index, via the same path `ambuild` uses — no manual `REINDEX` is needed:

```sql
TRUNCATE documents;
-- documents_vamana_idx is already empty and searchable; no REINDEX required
```

### Typical Deployment Flow

```sql
-- 1. Enable this database for Vamana (run in the launcher's database).
--    Skip if already enabled. A worker is spawned within moments.
INSERT INTO vamana_databases (datname) VALUES ('mydb')
    ON CONFLICT (datname) DO NOTHING;

-- 2. Build the index
CREATE INDEX CONCURRENTLY docs_vamana ON docs USING vamana (embedding vector_cosine_ops);

-- 3. Warm the worker cache before first INSERT (optional)
SELECT svs_warmup_index('docs_vamana');

-- 4. Begin serving writes
INSERT INTO docs (embedding) VALUES ('[...]');
```

### Tuning `svs.compact_threshold_pct`

The percent-deleted threshold that triggers `SVSCompact` during VACUUM cleanup. Default 10. Range 0–100.

- **0**: compact on every VACUUM with any pending deletes. Tightest memory footprint; highest VACUUM cost.
- **10** (default): compact once deleted entries exceed 10% of live vectors. Balances memory and VACUUM cost.
- **100**: disable compact entirely. Consolidate still runs (graph recall is preserved) but memory for deleted slots is never reclaimed without `REINDEX`.

Lower for memory-constrained deployments with heavy delete churn. Raise for write-heavy workloads where VACUUM latency matters more than memory. Change takes effect on the next `VACUUM` — no restart required.

### When to REINDEX

You do **not** need periodic `REINDEX` for correctness. You might still choose to `REINDEX` if:

- Autovacuum has not run for an extended period and the deleted fraction is unusually high.
- You have observed measurable recall drop in production after a long write horizon. Vamana graphs accumulate a small amount of topological debt over many incremental inserts; a fresh build produces the optimal graph for the current data.
- You need to change a build-time parameter (`graph_degree`, `compression_type`, etc.).

### VACUUM

VACUUM reclaims space from deleted heap rows and removes deleted vectors from the Vamana index graph. Run it regularly:

```sql
VACUUM ANALYZE documents;
```

### Disk Space for On-Disk Persistence

The Vamana index graph and TID mappings are serialized directly to files on the filesystem. Disk space usage approximately scales as:

```
Disk ≈ N × graph_degree × 8 bytes (neighbor list)
     + N × D × sizeof(stored_element)
```

With LeanVec compression, the stored element size is much smaller than `D × 4 bytes`.

### PostgreSQL Restart / Crash Recovery

After a restart or crash, the launcher re-reads `vamana_databases` and respawns a worker for each enabled database. Each worker loads an index on first access: it reads the last checkpoint from disk and replays any committed operations recorded in the replication slot since that checkpoint before serving the first operation against that index. Because replay happens before that operation proceeds, the index is fully consistent by the time the first query or insert against it completes. There is no data loss for committed transactions. (Loading is per-index and on demand, so startup no longer scales with the number or size of indexes; see [Section 6.1](#61-background-workers-and-per-database-enablement-advanced).)

### Security and Deployment Notes

This section describes security-relevant deployment considerations that operators should be aware of.

#### On-Disk Index Protection

The serialized SVS index directory (`$PGDATA/vamana_indexes/<oid>/`) contains raw embedding vectors. Its confidentiality and integrity are protected by PostgreSQL's `$PGDATA` permission posture: the postmaster process umask applies `0700` to all directories under `$PGDATA`, including the Vamana index save directory. The extension does not enforce permissions independently.

**Important:** A separately-encrypted tablespace volume does **not** protect the Vamana index files. The extension serializes index data directly to the filesystem under `$PGDATA`, bypassing PostgreSQL's tablespace indirection. `ALTER INDEX ... SET TABLESPACE` is a **silent no-op** for Vamana indexes in the current release (v0.1). This limitation is tracked for resolution in v0.2.

Operators who require encryption-at-rest for embedding data should use full-disk or volume-level encryption on the filesystem backing `$PGDATA`.

#### WAL Configuration Requirement

Background workers require `wal_level = logical` in `postgresql.conf`. If `wal_level` is set to a lower value (`replica` or `minimal`), each per-database worker emits `FATAL` at startup; the launcher respawns it with escalating backoff (`svs.worker_restart_backoff`), so it enters a backoff-limited crash loop rather than restarting every few seconds. The postmaster and launcher are not affected, but all Vamana index operations (search, insert, delete) will fail with "background worker unavailable" errors until the configuration is corrected and the server is restarted.

```
# Required in postgresql.conf
wal_level = logical
```

#### Standby Replication Slot Configuration

On a standby server using a Vamana replication slot, `hot_standby_feedback` must be set to `on`:

```
# Required on standby servers with Vamana indexes
hot_standby_feedback = on
```

If `hot_standby_feedback = off`, the primary may remove WAL segments that the standby's Vamana replication slot still needs. PostgreSQL silently invalidates the slot and emits only a WARNING in the standby's server log. After invalidation, the standby BGW cannot replay committed changes, and a full index rebuild from the heap is required the next time the standby BGW restarts. Monitor standby logs for `replication slot ... has been invalidated` warnings.

#### `vamana_databases` Access

INSERT, UPDATE, DELETE, and TRUNCATE on `vamana_databases` are all revoked from `PUBLIC`; only the table owner (or a superuser) can change which databases run a Vamana worker. Any role with CONNECT privilege can call `pg_notify('vamana_databases_changed', '')` directly — this is not a privilege escalation: the payload is empty, and the launcher only wakes up and re-reads `vamana_databases` under its own privileges, so an unprivileged NOTIFY cannot change which databases are enabled.

The table also enforces CHECK constraints on its per-database resource columns: `graph_memory_mb > 0`, `total_memory_mb > 0`, and `search_num_threads BETWEEN 1 AND 1024`. These reject out-of-range values at write time (a NULL means "use the GUC default"), so a bad row cannot reach the launcher.

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

### Worker Status

`pg_stat_vamana_worker` reports one row per enabled database — including databases whose worker is starting, backing off after a crash, or serving zero indexes — mirroring how `pg_stat_replication` shows slots regardless of transient state:

```sql
SELECT (SELECT datname FROM pg_database WHERE oid = db_oid) AS datname,
       worker_pid, worker_state, index_count, heartbeat_ts
FROM pg_stat_vamana_worker;
```

| Column | Meaning |
|---|---|
| `db_oid` | OID of the enabled database |
| `worker_pid` | The worker's PID, or NULL if no worker is currently running (starting, or crashed and awaiting respawn) |
| `worker_state` | `running`, `starting`, `backoff` (crash backoff), `unresponsive`, or `replica` (serving a hot standby) |
| `index_count` | Number of Vamana indexes in that database. `0` flags a database that may no longer need a worker (see [Section 7](#pausing-vs-removing-a-database)). NULL on a standby, where the counter is not maintained. |
| `evict_all` | `true` while the worker is draining every cached index (e.g. during a restart or shutdown); normally `false` |
| `heartbeat_ts` | Last time the worker updated its heartbeat |

`pg_stat_vamana_worker_slot` reports one row per worker request slot per visible database — including idle (`empty`) slots, not just in-flight ones — for finer-grained diagnosis of what a worker is currently processing (`slot_status`, `slot_kind`, `index_relid`, `error_message`).

> **Cross-database visibility:** both views are cluster-wide. An ordinary user sees only their own database's rows; a `pg_read_all_stats` member sees all databases. When you care about the current database only, filter by `db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())`.

### Server Log Messages

The extension emits `LOG`-level messages to the PostgreSQL server log during long operations. These appear in the server log (not in the client session) and help diagnose what is happening during slow queries or builds.

| Situation | Log message |
|-----------|-------------|
| Index load triggered (first access / after restart) | `loading vamana index <oid>`, with the save directory path on the accompanying `DETAIL:` line |
| TID map being loaded | `vamana index <oid>: loading TID map for N vectors (M slots total)` |
| Index fully loaded from disk | `vamana index <oid> loaded from disk (N vectors, capacity M)` |
| No saved copy on disk; rebuilding from table | `vamana worker: no saved copy for index <oid>, rebuilding` |
| Rebuild started | `rebuilding vamana index from table data` |
| Rebuild scan progress (every 100,000 tuples) | `vamana index <oid>: scanning table, N vectors collected` |

To see these messages in `psql`, ensure your client is connected to a session where `client_min_messages = log` (not the default). They are always written to the PostgreSQL log file regardless of client settings.

File system paths and library diagnostics are attached as log-only detail, so they appear on the `DETAIL:` line in the server log but are never sent to a client session at any `client_min_messages` setting. Read the server log file when you need the path.

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

### Write and Vacuum Activity

| What | How |
|---|---|
| Live vs. deleted vector count | No SQL-level view currently; monitor via server log messages below. |
| Worker state per database | Query `pg_stat_vamana_worker` (see [Worker Status](#worker-status) above). |
| Write serialization pressure | `vamana_index_rwlock` is only held inside the worker process, not by backends; backends instead block on their own IPC slot latch. Query `pg_stat_vamana_worker_slot` for rows with `slot_status = 'pending'` or `'processing'` to see queued work. |
| Rebuild frequency | Look for `rebuilding vamana index from table data` in server logs. A healthy dynamic index sees this only on worker cold start after a restart or REINDEX. |
| Checkpoint activity | Look for slot advance log messages; infrequent checkpoints indicate low write volume. |

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

**Cause:** The database's worker must be running before it can accept inserts. If no worker is available, the backend returns an ERROR rather than silently dropping the insert. The two common reasons are: the database is not enabled in `vamana_databases`, or the worker is still starting after a restart.
**Fix:** Confirm the database's worker is running (`SELECT worker_state FROM pg_stat_vamana_worker WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database())`) — if there is no row at all, the database is not enabled in `vamana_databases` (checking the row directly requires the table owner or a superuser, since `SELECT` on `vamana_databases` is not granted to `PUBLIC`). Ensure `shared_preload_libraries = 'svs'`. If the server just restarted, the first operation waits until the worker finishes startup (controlled by `svs.worker_startup_timeout_ms`); if the timeout is exceeded, increase it or investigate slow startup.

### Low recall after compression

**Cause:** Aggressive compression (small `leanvec_dims` or 4-bit quantization) can reduce recall.  
**Fix:** Increase `search_window_size` at query time, or rebuild with less aggressive compression settings (larger `leanvec_dims`, or switch to 8-bit).

### Slow first query after restart

**Cause:** Indexes load on demand, so the first query against a given index after a restart pays that index's load-and-replay cost. This is per index, not a single upfront load of the whole database.
**Fix:** Warm the cache deliberately after the server is ready, rather than paying the cost on the first real query:

```sql
SELECT svs_warmup_database();   -- warm every Vamana index in this database
-- or a single index:
SELECT svs_warmup_index('documents_vamana_idx');
```

### INSERT does not appear in a SELECT from another session

**Cause:** All inserts go through the worker synchronously — the inserting session blocks until the worker ACKs. If a SELECT in another session does not return the inserted row, the most likely cause is that this database's worker is not running.

**Check:** is this database's worker running?
```sql
SELECT worker_state, worker_pid FROM pg_stat_vamana_worker
WHERE db_oid = (SELECT oid FROM pg_database WHERE datname = current_database());
```

**Fix:** ensure the database is enabled in `vamana_databases` and its `worker_state` is `running`. If the worker is running and rows are still missing, force a rebuild with `REINDEX INDEX CONCURRENTLY <idx>`.

### SELECT returns fewer than `LIMIT` rows after many DELETEs

**Cause:** Deleted vectors are soft-deleted and filtered at query time. The returned count can be less than `k` until VACUUM runs consolidation.
**Fix:** Run `VACUUM` to trigger consolidate. If underfill persists after VACUUM, check server logs for `SVS consolidate failed` warnings. If consolidation keeps failing, run `REINDEX INDEX CONCURRENTLY <idx>`.

### INSERT throughput drops at high concurrency

**Cause:** Writes are serialized per index inside the BGW. Throughput is bounded by single-threaded SVS add.

**Fix:**
- Batch rows in multi-row `INSERT` statements from a single backend.
- Consider splitting logically independent datasets across multiple table partitions — each partition has its own index and its own serialization domain.

### SVSAddPoints failure warning in server log

When `SVSAddPoints` fails, the insert invalidates the cache and returns success to the client, so no user-visible error is raised. If you see `WARNING: SVS dynamic add points failed` frequently in the server log, read the SVS error text from the `DETAIL:` line that follows it. It typically indicates dimension mismatch or an out-of-memory condition.

### "background worker unavailable; dead vector removal skipped" WARNING during VACUUM

This warning fires when VACUUM runs but the database's worker is not available (e.g., immediately after a server restart, or while the worker is backing off after a crash). Dead vectors accumulate in the index graph until the worker is running again and VACUUM runs again; this is a temporary recall-quality issue, not a correctness issue. If you see this warning persistently, verify the database is enabled and its worker is running (`pg_stat_vamana_worker`), and check server logs for startup errors.

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
| `hnsw.ef_search` (GUC) | `svs.search_window_size` (GUC) | Runtime query beam width |

---

## 11. Reference: Parameter Summary

### Index Build Parameters (`CREATE INDEX … WITH (…)`)

| Parameter | Default | Min | Max | Notes |
|-----------|---------|-----|-----|-------|
| `graph_degree` | `64` | `16` | `256` | Max neighbors per node |
| `alpha` | `-1` | `-1` | `200` | Pruning factor × 100; -1 = SVS default |
| `build_window_size` | `-1` | `-1` | `1000` | Build search window; -1 = 2×graph_degree |
| `search_window_size` | `100` | `10` | `10000` | Default query window (always governed by `svs.search_window_size` GUC at runtime) |
| `use_search_history` | `true` | — | — | Maintain visited-node set during search; improves recall |
| `compression_type` | `0` | `0` | `2` | 0=none, 1=leanvec, 2=lvq (reserved) |
| `compression_primary` | `8` | — | — | One of: 4, -4, 8, -8 |
| `compression_secondary` | `8` | — | — | One of: 4, -4, 8, -8; ≥ primary precision |
| `leanvec_dims` | `-1` | `-1` | `2000` | Reduced dims; -1 = dimensions/2 |

### Session GUC Parameters (`SET …`)

| GUC | Default | Min | Max | Notes |
|-----|---------|-----|-----|-------|
| `svs.search_window_size` | `100` | `10` | `10000` | Governs query-time search window size; always takes effect (the `search_window_size` index reloption is not used as a fallback in the current implementation) |
| `svs.search_num_threads` | `0` | `0` | `1024` | SVS threads per search; 0 = auto (nproc-1). Superuser-only (`PGC_SUSET`) |
| `svs.compact_threshold_pct` | `10` | `0` | `100` | Percent-deleted threshold that triggers SVS compact during VACUUM; `0` = compact on every VACUUM with pending deletes, `100` = disable compact |

### Server GUC Parameters (require restart — `postgresql.conf` only, `PGC_POSTMASTER`)

| GUC | Default | Notes |
|-----|---------|-------|
| `svs.launcher_database` | `'postgres'` | Database the launcher reads `vamana_databases` from; set once at install time |
| `svs.max_databases` | `8` | Max databases that can run a worker concurrently (range 1–128); sizes the shared-memory slot array |
| `svs.worker_restart_time` | `5` (s) | Postmaster wait before restarting the **launcher** after a crash; `-1` disables. Range -1–300 |

### Runtime-tunable Server GUC Parameters (`PGC_SIGHUP` — reload with `SELECT pg_reload_conf()`)

| GUC | Default | Min | Max | Notes |
|-----|---------|-----|-----|-------|
| `svs.worker_startup_timeout_ms` | `60000` | `1000` | `300000` | Wait for a not-yet-started worker (ms); exceeded → error |
| `svs.worker_timeout_ms` | `5000` | `100` | `60000` | Worker IPC response timeout (ms); exceeded → error |
| `svs.worker_restart_backoff` | `1000` (ms) | `100` | `300000` | Base delay before respawning a crashed **per-database** worker; escalates on repeated crashes |
| `svs.max_batch_size` | `0` | `0` | `1000` | Max queries per SVS batch call; 0 = MaxBackends |
| `svs.shutdown_drain_budget_ms` | `30000` | `0` | `600000` | Time budget for the worker's shutdown drain, checked between indexes |
| `svs.worker_stop_timeout_ms` | `30000` | `0` | `600000` | Wait for a restarting worker to report stopped before giving up; does not force-kill |
| `svs.max_slot_wal_size` | `10GB` | — | — | If WAL retained by the replication slot exceeds this, the slot is dropped and the index is rebuilt from the heap |
| `svs.checkpoint_debounce_window` | `300s` | — | — | Quiet-period wait after a write burst before triggering a checkpoint |
| `svs.checkpoint_max_interval` | `3600s` | — | — | Maximum time between checkpoints; safety net for constant-write workloads |
| `svs.checkpoint_min_ops` | `10000` | — | — | Minimum number of write operations required before a checkpoint is considered (AND-logic filter) |
| `svs.checkpoint_operations` | `-1` (off) | — | — | Legacy op-count checkpoint trigger; activates simple mode when set |
| `svs.checkpoint_interval` | `-1` (off) | — | — | Legacy time-based checkpoint trigger in seconds; activates simple mode when set |

### SQL Functions

| Function | Runs in | Requires | Purpose |
|----------|---------|----------|---------|
| `svs_restart_worker(dbname name)` | launcher's database | `UPDATE` on `vamana_databases` (owner or superuser) | Drain, stop, and respawn one enabled database's worker on demand |
| `svs_teardown_database()` | target database | Ownership of each index dropped (checked per-index) | Drop every Vamana index in the current database (step 1 of permanent removal); returns one row per index |
| `svs_warmup_index(regclass)` | target database | `SELECT` on the index's table | Load one Vamana index into the worker cache |
| `svs_warmup_database()` | target database | `SELECT` on each index's table (unreadable indexes are skipped, not an error) | Load every Vamana index in the current database; returns the count warmed |

### Catalog and Views

| Object | Purpose |
|--------|---------|
| `vamana_databases` | Per-database enablement (`INSERT` to enable, `UPDATE ... SET enabled` to pause/resume, two-step teardown + `DELETE` to remove) |
| `pg_stat_vamana_worker` | One row per enabled database: worker PID, state, index count, heartbeat |
| `pg_stat_vamana_worker_slot` | One row per in-flight IPC work-request slot |

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


