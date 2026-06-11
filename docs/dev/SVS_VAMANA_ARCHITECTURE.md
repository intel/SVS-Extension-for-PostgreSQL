# SVS Vamana Index Integration Architecture for pgvector

**Date:** May 27, 2026
**Version:** 0.9.0
**Status:** Implementation Complete

## Table of Contents
1. [Executive Summary](#executive-summary)
2. [Background](#background)
3. [Architecture Overview](#architecture-overview)
4. [Detailed Design](#detailed-design)
5. [GUC Parameters](#guc-parameters)
6. [Integration Points](#integration-points)
7. [Performance Considerations](#performance-considerations)

---

## 1. Executive Summary

This document describes the `svs` PostgreSQL extension, which adds a Vamana index access method backed by Intel's Scalable Vector Search (SVS) library. The extension is a standalone PostgreSQL extension that depends on pgvector (`vector` extension) for its vector types and operator classes; it does not bundle pgvector source.

**Achieved Goals:**
- Added `vamana` index access method to pgvector
- Integrated Intel SVS C API for high-performance vector search
- Maintained PostgreSQL compatibility and pgvector conventions
- Implemented LeanVec and LVQ compression with integer-based parameters
- Enabled Intel AVX-512 optimizations for Xeon processors
- Implemented on-disk index serialization via PostgreSQL pages
- Implemented background worker for persistent index caching across backends
- Incremental insert and delete via SVS dynamic index API (no full rebuild required)
- Cost estimation for query planner
- Build-phase progress reporting via `pg_stat_progress_create_index`

---

## 2. Background

### 2.1 Intel SVS Library
- **Repository:** https://github.com/intel/ScalableVectorSearch
- **License:** Mixed — see below
- **Key Features:**
  - Vamana graph-based index (similar to HNSW)
  - Locally-adaptive Vector Quantization (LVQ) compression
  - LeanVec two-level quantization compression
  - Optimized for Intel Xeon processors (2nd gen and newer)
  - Support for float32, float16
  - Distance metrics: Euclidean, Inner Product, Cosine similarity
  - Billion-scale performance

**Licensing details:**

| Component | License |
|---|---|
| Core Vamana index (open-source SVS) | Apache 2.0 |
| LVQ and LeanVec compression | Intel Simplified Software License (binary-only, proprietary) |

LVQ and LeanVec are **not open-source**. They are distributed in binary form only and run only on Intel CPUs. The Intel Simplified Software License prohibits reverse engineering, decompilation, modification, or disassembly. See `ScalableVectorSearch/LICENSE` and `docs/non-open-source-notice.rst` in the SVS repository for the full terms.

### 2.2 Vamana Algorithm
- Graph-based approximate nearest neighbor search
- Similar to HNSW but with a single-layer graph and different construction strategy
- Uses greedy search with pruning strategies
- Research paper: [DiskANN: Fast Accurate Billion-point Nearest Neighbor Search on a Single Node](https://www.microsoft.com/en-us/research/publication/diskann-fast-accurate-billion-point-nearest-neighbor-search-on-a-single-node/) (Microsoft Research); [GitHub](https://github.com/microsoft/DiskANN)

### 2.3 Existing pgvector Index Implementations
- **HNSW:** Graph-based, supports parallel build, in-memory + on-disk phases
- **IVFFlat:** Clustering-based, k-means partitioning, probe-based search

---

## 3. Architecture Overview

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    PostgreSQL Core                          │
├─────────────────────────────────────────────────────────────┤
│  pgvector Extension (vector/halfvec/sparsevec types,        │
│  HNSW index, IVFFlat index)          [separate extension]   │
├─────────────────────────────────────────────────────────────┤
│                svs Extension  (requires = 'vector')         │
├─────────────────────────────────────────────────────────────┤
│                       Vamana Index                          │
│   vamana.c / vamanabuild.c / vamanainsert.c                 │
│   vamanascan.c / vamanavacuum.c / vamanautils.c             │
│   vamanaworker.c / vamana_undo.c                            │
└─────────────────────────────────────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │    Intel SVS C API Wrapper   │
         │        svs_wrapper.c/h       │
         ├──────────────────────────────┤
         │  - Index Build               │
         │  - Index Search (batch)      │
         │  - Dynamic insert/delete     │
         │  - Compression (LVQ/LeanVec) │
         └──────────────────────────────┘
                        │
                        ▼
         ┌──────────────────────────────┐
         │  Intel SVS Shared Library    │
         │  libsvs_c_api.so             │
         └──────────────────────────────┘
```

### 3.2 Component Structure

**Core Implementation Files:**
- `src/svs.c` — Extension entry point (`_PG_init`), calls `VamanaInit()`
- `src/vamana.c` — Index access method handler, GUC registration, object-access hook
- `src/vamana.h` — Data structures, constants, and function declarations
- `src/vamanabuild.c` — Batch index build with LeanVec/LVQ compression support
- `src/vamanainsert.c` — Incremental single-tuple insert via SVS dynamic API
- `src/vamanascan.c` — Query execution, result retrieval, on-disk index loading
- `src/vamanautils.c` — Utility functions, parameter validation, cost estimation
- `src/vamanavacuum.c` — Vacuum and cleanup operations
- `src/vamanaworker.c/h` — Background worker: persistent index caching, batch search, and write-path dispatch via shared memory
- `src/vamana_undo.c/h` — Per-transaction undo log for INSERT rollback (XactCallback/SubXactCallback)
- `src/svs_wrapper.c/h` — SVS C API wrapper layer

**Test Files:**
- `test/sql/vamana_vector.sql` — Regression tests for `vector` type with Vamana
- `test/sql/vamana_halfvec.sql` — Regression tests for `halfvec` type with Vamana
- `test/sql/vamana_dynamic.sql` — Regression tests for incremental INSERT, DELETE + VACUUM, and REINDEX
- `test/t/01_vamana_worker_tests.pl` — TAP tests for index persistence, background worker, and batch search
- `test/t/02_vamana_lock_slot_leak.pl` — TAP test for LWLock slot leak detection

---

## 4. Detailed Design

### 4.1 Design Choice: SVS C API Batch Build

SVS provides a high-level batch build API with internal parallelism management.

**Implementation characteristics:**
- **SVS manages parallelism internally** via threads
- **No manual shared memory management** required for build
- **PostgreSQL passes thread count** via `max_parallel_maintenance_workers` for build operations and `svs.search_num_threads` for search operations
- **Dynamic index:** Uses `svs_index_build_dynamic` to produce a mutable index; INSERT calls `SVSAddPoints` for incremental updates, DELETE + VACUUM calls `SVSDeletePoints` with consolidation and compaction
- **Must buffer vectors:** All vectors loaded into memory before build

### 4.2 On-Disk Serialization

After the SVS batch build completes, the index is serialized to a directory on the filesystem using `VamanaGetIndexSavePath()`. The path is keyed by the index's relation OID. The metapage stores `hasSavedIndex`, `indexDataBlkno`, and `indexDataSize` to track serialization state.

On the first query after a cold start, `LoadIndexFromPages()` attempts to read the saved index from disk. If no saved copy exists, `VamanaRebuildFromTable()` performs an in-memory rebuild from the heap.

An object-access hook (`VamanaInstallObjectAccessHook`) cleans up the on-disk save directory when an index or its parent table is dropped.

### 4.3 Insert and Vacuum Behavior

**Inserts (`vamanainsert.c`):** `vamanainsert` routes the insert through the background worker (slot kind `VAMANA_SLOTKIND_INSERT`). The worker calls `SVSAddPoints` to add the new vector incrementally to the live in-memory index. External IDs are allocated from a counter held in the BGW's in-memory cache (`cache->nextExternalId`); the latest value is written back to the metapage by `VamanaWriteMetaPageDynamic` so the counter survives restart. The inserting backend records the new external ID in the per-transaction undo log (`VamanaUndoAppend`); on transaction ABORT, the registered XactCallback submits a BGW DELETE for each logged ID to roll back the in-memory graph state. All indexes are born dynamic; there is no static-only fallback path for inserts.

**Vacuum (`vamanavacuum.c`):** `vamanabulkdelete` iterates the TID mapping, calls PostgreSQL's dead-tuple callback for each live entry, and batches dead IDs to `SVSDeletePoints`. `vamanavacuumcleanup` calls `SVSConsolidate` to patch graph edges around deleted entries, and `SVSCompact` (when the deleted fraction exceeds 10%) to reclaim memory. Both functions update the metapage counters atomically.

**Known Limitation:** `PREPARE TRANSACTION` (two-phase commit / 2PC) is not supported on any transaction that has inserted into a Vamana index. The extension raises `ERRCODE_FEATURE_NOT_SUPPORTED` at prepare time (`vamana_undo.c`, `XACT_EVENT_PREPARE` handler). This is a fundamental constraint of the in-memory undo log design: prepared state cannot be persisted to disk and resumed by a later `COMMIT PREPARED`. Users with `max_prepared_transactions > 0` or distributed 2PC coordinators (e.g., Citus, XA drivers) must avoid issuing `PREPARE TRANSACTION` on transactions that touch Vamana indexes.

### 4.4 Background Worker

`vamanaworker.c` implements a background process that holds the SVS index permanently and serves all backends via shared memory. The worker is **always registered** when the extension is loaded via `shared_preload_libraries`; there is no opt-in GUC to enable or disable it.

**Architecture:**
- A single PostgreSQL background worker connects to `svs.worker_database` at startup and loads all Vamana indexes for that database
- Shared memory region (`VamanaWorkerShmem`) contains a per-backend slot array plus variable-length areas for query vectors, result TIDs, and distances
- Each slot has a kind (`VAMANA_SLOTKIND_SEARCH`, `_INSERT`, `_DELETE`, `_MAINTENANCE`); backends set the kind and data, set status `PENDING`, and wait on a shared latch
- The worker drains all pending slots each cycle: SEARCH slots are batched and dispatched to `SVSSearch`; write slots (`INSERT`, `DELETE`, `MAINTENANCE`) are dispatched one at a time via `VamanaWorkerProcessWriteSlot`
- If the worker is unavailable or startup times out (controlled by `svs.worker_startup_timeout_ms`), the backend throws an error rather than silently falling back
- Per-index LWLocks (`VamanaIndexLockSlot`, up to `VAMANA_MAX_INDEXES = 64` live indexes) serialize concurrent write operations within the worker
- Crash recovery: the worker restarts automatically after `svs.worker_restart_time` seconds. While the worker is down, backends that attempt index operations receive an ERROR (no silent fallback). On restart, the worker itself uses `LoadIndexFromPages` (then `VamanaRebuildFromTable` if no saved copy exists) to reload indexes before accepting requests
- Reload signaling: backends write to `reloadRequests[]` when their index is invalidated; the worker reloads on its next cycle

**Transaction safety:** Inserts are logged to a per-transaction undo log (`vamana_undo.c`). On ABORT, an XactCallback/SubXactCallback submits BGW DELETE operations for each logged insert, rolling back the in-memory graph state. On COMMIT, the undo log is discarded.

The worker is enabled by loading the extension via `shared_preload_libraries = 'vector,svs'` (requires server restart). No additional GUC is required.

### 4.5 Supported Vector Types and Operator Classes

Vamana indexes support `vector` (float32) and `halfvec` (float16) types. `sparsevec` and `bit` are not supported.

| Operator Class | Type | Distance Operator | Metric |
|---|---|---|---|
| `vector_l2_ops` | `vector` | `<->` | L2 (Euclidean) |
| `vector_ip_ops` | `vector` | `<#>` | Inner product (negated) |
| `vector_cosine_ops` | `vector` | `<=>` | Cosine |
| `halfvec_l2_ops` | `halfvec` | `<->` | L2 (Euclidean) |
| `halfvec_ip_ops` | `halfvec` | `<#>` | Inner product (negated) |
| `halfvec_cosine_ops` | `halfvec` | `<=>` | Cosine |

### 4.6 Index Build Phases

Two progress phases are reported via `pg_stat_progress_create_index`:
1. `PROGRESS_CREATEIDX_SUBPHASE_INITIALIZE` — initializing build state
2. `PROGRESS_VAMANA_PHASE_LOAD` — scanning heap and accumulating vectors

---

## 5. GUC Parameters

### 5.1 Runtime Query Parameters

| GUC | Type | Default | Range | Scope | Description |
|---|---|---|---|---|---|
| `svs.search_window_size` | int | 100 | 10–10000 | `PGC_USERSET` | Search window (L) for index scans. Higher values improve recall at the cost of latency. |
| `svs.search_num_threads` | int | 0 | 0–1024 | `PGC_USERSET` | Threads SVS uses for search. `0` = auto (`nproc-1`). Lower values reduce oversubscription under concurrent load. |

### 5.2 Background Worker Parameters

`svs.worker_database` and `svs.worker_restart_time` require a server restart (set before starting PostgreSQL or changed with restart). The timeout GUCs can be updated at runtime via `SIGHUP`.

| GUC | Type | Default | Range | Scope | Description |
|---|---|---|---|---|---|
| `svs.worker_database` | string | `"postgres"` | — | `PGC_POSTMASTER` | Database the background worker connects to. Must match the database where Vamana indexes are created. |
| `svs.worker_restart_time` | int | 5 | -1–300 | `PGC_POSTMASTER` | Seconds before a crashed worker is restarted. `-1` = `BGW_NEVER_RESTART`. |
| `svs.worker_startup_timeout_ms` | int | 60000 | 1000–300000 | `PGC_SIGHUP` | Milliseconds a backend waits for the worker to finish startup before throwing an error. Startup can be slow when many large indexes are deserialized from disk. |
| `svs.worker_timeout_ms` | int | 5000 | 100–60000 | `PGC_SIGHUP` | Milliseconds a backend waits for the worker to respond to an IPC request (search or write) before throwing an error. |
| `svs.max_batch_size` | int | 0 | 0–1000 | `PGC_SIGHUP` | Maximum queries per SVS batch search call. `0` = `MaxBackends`. |
| `svs.compact_threshold_pct` | int | 10 | 0–100 | `PGC_USERSET` | Percent-deleted threshold that triggers SVS compact during VACUUM cleanup. `0` = compact on every VACUUM with pending deletes; `100` = disable compact (consolidate still runs). |

### 5.3 Index Creation Parameters

Specified in the `WITH (...)` clause of `CREATE INDEX`.

| Parameter | Type | Default | Range | Description |
|---|---|---|---|---|
| `graph_degree` | int | 64 | 16–256 | Maximum graph connections per node (R parameter). |
| `alpha` | int | -1 | -1–200 | Pruning parameter scaled by 100 (`120` = α 1.20). `-1` uses SVS library default. |
| `build_window_size` | int | -1 | -1–1000 | Build window size (L parameter). `-1` = `2 × graph_degree`. |
| `search_window_size` | int | 100 | 10–10000 | Search window during build and initial queries. |
| `use_search_history` | bool | `true` | — | Maintain the visited-node set during search. |
| `compression_type` | int | 0 | 0–2 | `0` = none, `1` = LeanVec, `2` = LVQ. |
| `compression_primary` | int | 8 | -8–8 | LeanVec primary quantization: `4`=UINT4, `-4`=INT4, `8`=UINT8, `-8`=INT8. |
| `compression_secondary` | int | 8 | -8–8 | LeanVec secondary quantization (same values as primary). |
| `leanvec_dims` | int | -1 | -1–2000 | Reduced dimensions for LeanVec. `-1` = `dimensions / 2`. |

---

## 6. Integration Points

### 6.1 Build System (Makefile)

The extension is built with `pgxs` and requires the Intel SVS C API library:

```makefile
SVS_INSTALL ?= svs_install_public
# Requires: $(SVS_INSTALL)/lib/libsvs_c_api.so
```

Compiler flags for SIMD optimization:
```
-march=native -ftree-vectorize -fassociative-math -fno-signed-zeros -fno-trapping-math
```

> **Note:** `-march=native` is conditionally disabled on ARM Mac, PowerPC, and RISC-V64 (see `Makefile:17–33`). On those platforms `OPTFLAGS` is empty and only the remaining flags are applied.

### 6.2 Extension Control File (`svs.control`)

```
comment = 'SVS Vamana index access method for pgvector'
default_version = '0.1.0'
requires = 'vector'
module_pathname = '$libdir/svs'
```

### 6.3 SQL Registration

```sql
CREATE FUNCTION vamanahandler(internal) RETURNS index_am_handler ...;
CREATE ACCESS METHOD vamana TYPE INDEX HANDLER vamanahandler;
```

Operator classes for `vector` and `halfvec` are registered as shown in Section 4.6.

Users install the extension with:

```sql
CREATE EXTENSION svs;  -- also installs the 'vector' dependency automatically
```

### 6.4 Loading via shared_preload_libraries

The background worker is registered automatically when the extension is loaded via `shared_preload_libraries`. No additional GUC is needed to enable it.

```
# postgresql.conf
shared_preload_libraries = 'vector,svs'
svs.worker_database = 'mydb'          # default: 'postgres'
svs.worker_restart_time = 5           # default: 5 seconds
```

`vector` must appear before `svs` because `svs` depends on it.

---

## 7. Performance Considerations

### 7.1 Optimization Strategies
1. **AVX-512 SIMD:** SVS automatically uses Intel hardware optimizations when compiled with `-march=native`
2. **Compression:** Enable LVQ (`compression_type=2`) for memory-constrained systems; LeanVec (`compression_type=1`) for two-level quantization
3. **Thread count:** Tune `svs.search_num_threads` to match workload; `0` auto-selects `nproc-1`
4. **Background worker:** Load the extension via `shared_preload_libraries` to amortize index load cost across all backends; the worker is always-on when loaded this way
5. **Incremental writes:** Inserts update the graph incrementally; periodic `REINDEX` restores optimal graph quality after many mutations

### 7.2 Write Considerations

Inserts are applied incrementally via `SVSAddPoints` and are immediately searchable. Deletes are applied during VACUUM via `SVSDeletePoints` with graph consolidation. For write-heavy workloads:
- Writes are serialized per-index via an advisory lock; high-throughput inserts may experience contention
- Periodic `REINDEX CONCURRENTLY` produces a fresh, optimally-constructed graph after many incremental mutations
- All writes (INSERT, DELETE, VACUUM) go through the background worker; the worker is the single owner of the live in-memory index, so all backends see a consistent view after the worker processes each slot

---

## Appendix A. Comparison: Vamana vs HNSW

| Feature | HNSW | Vamana |
|---|---|---|
| Graph structure | Hierarchical layers | Single-layer |
| Build complexity | O(N log N) | O(N log N) |
| Search complexity | O(log N) | O(log N) |
| Memory (uncompressed) | High | Medium |
| Memory (compressed) | No built-in quantization compression | Low (LeanVec/LVQ) |
| Parallel build | Yes (PostgreSQL workers) | Yes (SVS threads) |
| Update efficiency | Moderate | Incremental (SVS dynamic API) |
| Intel SIMD optimization | No (SVS-level intrinsics; auto-vectorization still applies) | Yes (AVX-512 via SVS) |
| Parallelism model | PostgreSQL processes | SVS threads |
| Shared memory for build | Required | Not required |
| Persistent index cache | No | Yes (optional background worker) |
| **Build params** | `m`, `ef_construction` | `graph_degree`, `build_window_size` (`alpha` for pruning) |
| **Query param** | `hnsw.ef_search` (GUC) | `svs.search_window_size` (GUC) |
| **Supported types** | vector, halfvec, bit, sparsevec | vector, halfvec |

**Parameter Migration Guide:**

| HNSW Parameter | Vamana Equivalent | Notes |
|---|---|---|
| `m` | `graph_degree` | Max graph degree (R); Vamana default 64 |
| `ef_construction` | `build_window_size` | Build-time search beam width (L); `-1` = `2 × graph_degree` |
| `hnsw.ef_search` | `svs.search_window_size` | Search beam width (L); runtime GUC |
| *(no equivalent)* | `alpha` | Vamana-specific pruning aggressiveness (scaled ×100); `-1` uses SVS default |

## Appendix B. SQL Usage Examples

```sql
-- Basic Vamana index (L2 distance)
CREATE INDEX ON embeddings USING vamana (embedding vector_l2_ops)
WITH (graph_degree = 64);

-- Cosine similarity with LeanVec 8-bit compression
CREATE INDEX ON embeddings USING vamana (embedding vector_cosine_ops)
WITH (compression_type = 1, compression_primary = 8, compression_secondary = 8);

-- LVQ compression (2-bit primary, 8-bit secondary)
CREATE INDEX ON embeddings USING vamana (embedding vector_l2_ops)
WITH (compression_type = 2);

-- Tune search quality at query time
SET svs.search_window_size = 200;
SELECT id FROM embeddings ORDER BY embedding <-> '[1,2,3]' LIMIT 10;

-- Use more search threads for a single large query
SET svs.search_num_threads = 8;
SELECT id FROM embeddings ORDER BY embedding <-> '[1,2,3]' LIMIT 10;
```

## Appendix C. Testing Checklist

**Regression tests** (`test/sql/vamana_vector.sql`, `test/sql/vamana_halfvec.sql`):
- [x] Basic CRUD operations (INSERT/UPDATE/DELETE) with incremental dynamic updates
- [x] Distance metrics: L2, inner product, cosine
- [x] All compression types: none, LeanVec (UINT4, INT4, UINT8, INT8 primary/secondary), LVQ
- [x] Custom `leanvec_dims` settings (-1=auto, explicit values)
- [x] Error validation: out-of-range `compression_type`, `compression_primary`, `compression_secondary`, `leanvec_dims`, `graph_degree`, `alpha`, `build_window_size`, `search_window_size`
- [x] Unlogged tables
- [x] Runtime `svs.search_window_size` tuning (min, max, RESET)
- [x] `svs.search_num_threads` GUC correctness
- [x] `max_parallel_maintenance_workers` decoupled from search thread count
- [x] `search_window_size` value forwarded to SVS at query time
- [x] Index serialization: CREATE INDEX saves to disk; incremental INSERT updates in-memory index
- [x] Incremental INSERT searchable without rebuild (L2, IP, cosine) (`vamana_dynamic.sql`)
- [x] DELETE + VACUUM removes vectors from live index (`vamana_dynamic.sql`)
- [x] Mixed INSERT + DELETE + VACUUM cycle (`vamana_dynamic.sql`)
- [x] REINDEX after incremental inserts (`vamana_dynamic.sql`)
- [x] Index introspection via `pg_indexes`

**TAP tests** (`test/t/01_vamana_worker_tests.pl`):
- [x] Index persistence: query results after server restart match pre-restart baseline
- [x] Disk load on restart: no table rebuild when saved copy exists (log confirmed)
- [x] Deferred save: index persisted via `vamanaendscan` after rebuild
- [x] Vacuum safety-net save: `vamanavacuumcleanup` saves when `vamanaendscan` save failed
- [x] Crash recovery: immediate-stop restart, worker re-launched, queries resume
- [x] `max_parallel_maintenance_workers` does not cap search thread count (regression for SVSLoadIndex bug; `SVSLoadIndex` has since been removed — dynamic-only)
- [x] `svs.search_num_threads` GUC explicitly overrides auto default
- [x] Background worker visible in `pg_stat_activity`
- [x] Worker results are correct (query returns expected neighbors)
- [x] No per-backend index load when worker is running
- [x] Worker loads index from disk after restart (no table rebuild)
- [x] Worker reloads index after INSERT signals reload
- [x] `DROP DATABASE` completes while worker is running (ProcSignalBarrier)
- [x] `svs.max_batch_size = 1`: sequential slot draining correct
- [x] `svs.worker_database` non-default: worker connects to named database
- [x] `dbOid != MyDatabaseId`: backend receives ERROR with actionable hint
- [x] Worker timeout: backend receives ERROR after `svs.worker_timeout_ms` expires
- [x] SIGHUP GUC reload: `svs.worker_timeout_ms` updated in worker without restart
- [x] Multiple concurrent Vamana indexes served by one worker
- [x] `search_window_size` boundary value (10000) accepted; 10001 rejected by GUC
- [x] Concurrent queries: correctness and result isolation across backends
- [x] Native SVS batch search path taken when N clients arrive in same worker iteration
- [x] `max_batch_size` cap: batch split across iterations, all clients get correct results
- [x] Heterogeneous `search_window_size`: sequential fallback path, correct results

**Not yet covered:**
- [ ] pg_upgrade compatibility
