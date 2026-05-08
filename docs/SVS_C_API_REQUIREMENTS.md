# SVS C API — Integration Reference

**Project:** pgvector Vamana Index Integration (standalone `svs` extension)
**Date:** May 7, 2026
**Version:** 2.0
**Status:** Implementation Complete

---

## Overview

This document describes the Intel SVS C API functions used by the `svs` PostgreSQL
extension, covering all phases of the Vamana index lifecycle: algorithm configuration,
index build, serialization, search, dynamic mutation, and maintenance.

The API surface is consumed entirely through `src/svs_wrapper.c`, which wraps each
SVS function in a thin PostgreSQL-friendly shim (error translation, type conversion).
The public interface exposed to the rest of the extension is declared in
`src/svs_wrapper.h`.

---

## Table of Contents

1. [Error Handling](#1-error-handling)
2. [Algorithm Configuration](#2-algorithm-configuration)
3. [Storage / Compression Configuration](#3-storage--compression-configuration)
4. [Builder and Thread Configuration](#4-builder-and-thread-configuration)
5. [Index Build](#5-index-build)
6. [Index Serialization](#6-index-serialization)
7. [Search](#7-search)
8. [Dynamic Index Operations](#8-dynamic-index-operations)
9. [Maintenance](#9-maintenance)
10. [API Summary Table](#10-api-summary-table)

---

## 1. Error Handling

Every SVS call receives an `svs_error_h` handle. After the call, the wrapper checks
`svs_error_ok(error)`; on failure it reads the message with `svs_error_get_message`
and the code with `svs_error_get_code`, then raises a PostgreSQL `ERROR`.

```c
svs_error_h  svs_error_create(void);
bool         svs_error_ok(svs_error_h error);
const char  *svs_error_get_message(svs_error_h error);
svs_error_code_t svs_error_get_code(svs_error_h error);
void         svs_error_free(svs_error_h error);
```

All error handles are freed on every code path (success and failure) via
`svs_error_free`.

---

## 2. Algorithm Configuration

Creates a Vamana algorithm handle that encodes graph construction parameters.

```c
svs_algorithm_h svs_algorithm_create_vamana(
    size_t graph_degree,
    size_t build_window_size,
    size_t search_window_size,
    svs_error_h error
);

void svs_algorithm_vamana_set_alpha(
    svs_algorithm_h algorithm,
    double alpha,
    svs_error_h error
);

void svs_algorithm_vamana_set_use_search_history(
    svs_algorithm_h algorithm,
    bool use_search_history,
    svs_error_h error
);

void svs_algorithm_free(svs_algorithm_h algorithm);
```

**Wrapper functions:** `SVSCreateAlgorithm`, `SVSFreeAlgorithm`

`alpha` is stored in the index reloptions as an integer scaled by 100 (e.g. `120` = α 1.20);
the wrapper converts it to `double` before calling `svs_algorithm_vamana_set_alpha`.
When the reloption is `-1`, the default is left unset and SVS uses its built-in default (~1.2).

---

## 3. Storage / Compression Configuration

Creates a storage descriptor that controls how vectors are quantized in the index.

```c
svs_storage_h svs_storage_create_simple(
    svs_data_type_t dtype,
    svs_error_h error
);

svs_storage_h svs_storage_create_leanvec(
    size_t leanvec_dims,
    svs_data_type_t primary_type,
    svs_data_type_t secondary_type,
    svs_error_h error
);

void svs_storage_free(svs_storage_h storage);
```

**Wrapper functions:** `SVSCreateSimpleStorage`, `SVSCreateLeanVecStorage`, `SVSFreeStorage`

Supported `svs_data_type_t` values (mapped from the `compression_primary` /
`compression_secondary` integer reloptions):

| Reloption value | SVS type |
|---|---|
| `4`  | `SVS_DATA_TYPE_UINT4` |
| `-4` | `SVS_DATA_TYPE_INT4`  |
| `8`  | `SVS_DATA_TYPE_UINT8` |
| `-8` | `SVS_DATA_TYPE_INT8`  |

`compression_type = 0` (no compression) uses `svs_storage_create_simple` with `FLOAT32`
or `FLOAT16` depending on the vector column type. `compression_type = 1` (LeanVec) uses
`svs_storage_create_leanvec`. `compression_type = 2` (LVQ) is reserved.

---

## 4. Builder and Thread Configuration

Creates a builder that combines a metric, dimensionality, and algorithm handle, then
attaches a storage descriptor and thread pool.

```c
svs_index_builder_h svs_index_builder_create(
    svs_distance_type_t distance_type,
    size_t dimensions,
    svs_algorithm_h algorithm,
    svs_error_h error
);

void svs_index_builder_set_storage(
    svs_index_builder_h builder,
    svs_storage_h storage,
    svs_error_h error
);

void svs_index_builder_set_threadpool(
    svs_index_builder_h builder,
    svs_threadpool_kind_t kind,   /* SVS_THREADPOOL_KIND_NATIVE */
    size_t num_threads,
    svs_error_h error
);

void svs_index_builder_free(svs_index_builder_h builder);
```

**Wrapper functions:** `SVSCreateBuilder`, `SVSBuilderSetStorage`, `SVSBuilderSetThreadpool`,
`SVSFreeBuilder`

Thread count is derived from `max_parallel_maintenance_workers`: when the GUC is `0`,
the wrapper calls `SVSDefaultBuildThreads()` (which returns `nproc - 1`); otherwise the
GUC value is passed directly.

---

## 5. Index Build

Builds the initial Vamana graph from a complete set of float32 vectors. The `dynamic`
variant produces a mutable index handle that accepts subsequent incremental operations.

```c
svs_index_h svs_index_build_dynamic(
    svs_index_builder_h builder,
    const float *data,            /* row-major, num_vectors × dimensions */
    const size_t *ids,            /* external IDs, length num_vectors */
    size_t num_vectors,
    size_t blocksize_bytes,       /* hint for internal batching; 0 = library default */
    svs_error_h error
);

void svs_index_free(svs_index_h index);
```

**Wrapper functions:** `SVSBuildDynamicIndex`, `SVSFreeIndex`

The extension buffers all heap vectors in memory before calling `svs_index_build_dynamic`.
Build-time parallelism is managed entirely inside SVS; PostgreSQL simply passes the
thread count via the builder (see §4).

---

## 6. Index Serialization

The SVS index graph is serialized to a directory on the filesystem (not PostgreSQL
data pages). The TID mapping is stored separately as a sidecar file (`tidmap.bin`)
alongside the SVS directory.

```c
bool svs_index_save(
    svs_index_h index,
    const char *path,             /* directory path; created if absent */
    svs_error_h error
);

svs_index_h svs_index_load_dynamic(
    svs_index_builder_h builder,  /* carries compression / dimension config */
    const char *path,
    size_t flags,                 /* 0 = default */
    svs_error_h error
);
```

**Wrapper functions:** `SVSSaveIndex`, `SVSLoadDynamicIndex`

`svs_index_save` is called by `VamanaSaveIndexToDisk` after any operation that
dirtied the in-memory graph (`needsSave = true`). The save path is
`$PGDATA/vamana_indexes/<oid>/`.

`svs_index_load_dynamic` reconstructs the mutable graph from a previously saved
directory. The builder handle is reconstructed from the metapage reloptions so that
compression configuration (LeanVec dims, dtypes) is correctly restored.

---

## 7. Search

### Single-query search

```c
svs_search_params_h svs_search_params_create_vamana(
    size_t search_window_size,
    svs_error_h error
);

svs_search_results_t svs_index_search(
    svs_index_h index,
    const float *query,           /* length = dimensions */
    size_t k,
    svs_search_params_h params,
    svs_error_h error
);

void svs_search_params_free(svs_search_params_h params);
void svs_search_results_free(svs_search_results_t results);
```

**Wrapper functions:** `SVSSearch`, `SVSBatchSearch`

`svs_index_search` is called in a loop for batch search (one call per query vector).
`search_window_size` is read from the `vamana.search_window_size` GUC at scan time.

### Result accessors

After `svs_index_search` succeeds the wrapper reads results using:

```c
size_t svs_search_results_get_n(svs_search_results_t results);
size_t svs_search_results_get_id(svs_search_results_t results, size_t i);
float  svs_search_results_get_distance(svs_search_results_t results, size_t i);
```

Each returned SVS ID is used as an index into the backend's `tidMapping` array to
recover the PostgreSQL `ItemPointer`. Slots marked `InvalidItemPointer` (soft-deleted
entries awaiting VACUUM) are skipped.

---

## 8. Dynamic Index Operations

These functions mutate the live index graph in place, enabling PostgreSQL `INSERT`,
`DELETE`, and `VACUUM` to update the index without a full rebuild.

### Add vectors

```c
bool svs_index_dynamic_add_points(
    svs_index_h index,
    const float *data,            /* row-major, num_vectors × dimensions */
    const size_t *ids,            /* external IDs */
    size_t num_vectors,
    svs_error_h error
);
```

**Wrapper function:** `SVSAddPoints`

Called from `vamanainsert.c` under a per-index advisory lock
(`VAMANA_DYNAMIC_WRITE_LOCK_KEY`). External IDs are assigned monotonically from
`nextExternalId` on the metapage, preventing collisions across backends.

### Delete vectors

```c
bool svs_index_dynamic_delete_points(
    svs_index_h index,
    const size_t *ids,            /* external IDs to soft-delete */
    size_t num_ids,
    svs_error_h error
);
```

**Wrapper function:** `SVSDeletePoints`

Called from `vamanabulkdelete` during VACUUM. Marks entries deleted in the SVS
graph (tombstone semantics). Deleted entries are filtered at query time by the
`InvalidItemPointer` check in `SVSSearch`.

### Check ID existence

```c
bool svs_index_dynamic_has_id(
    svs_index_h index,
    size_t id,
    bool *has_id_out,
    svs_error_h error
);
```

**Wrapper function:** `SVSHasId`

Used for sanity checks during development and debugging.

---

## 9. Maintenance

Called during `vamanavacuumcleanup` to restore graph quality and reclaim memory
after deletions.

### Consolidate

```c
bool svs_index_dynamic_consolidate(
    svs_index_h index,
    svs_error_h error
);
```

**Wrapper function:** `SVSConsolidate`

Patches graph edges that point at deleted entries so the remaining graph stays
connected. Run unconditionally whenever `numDeleted > 0`. Preserves recall for
surviving vectors.

### Compact

```c
bool svs_index_dynamic_compact(
    svs_index_h index,
    size_t batchsize,             /* 0 = library default */
    svs_error_h error
);
```

**Wrapper function:** `SVSCompact`

Physically reclaims memory for deleted slots. Run only when the deleted fraction
exceeds `vamana.compact_threshold_pct` (default 10%). SVS preserves external IDs
during compaction so the `tidMapping` array does not need to be rewritten.

---

## 10. API Summary Table

| SVS C API function | Wrapper | Phase |
|---|---|---|
| `svs_error_create/ok/get_message/get_code/free` | inline in wrapper | all |
| `svs_algorithm_create_vamana` | `SVSCreateAlgorithm` | build |
| `svs_algorithm_vamana_set_alpha` | `SVSCreateAlgorithm` | build |
| `svs_algorithm_vamana_set_use_search_history` | `SVSCreateAlgorithm` | build |
| `svs_algorithm_free` | `SVSFreeAlgorithm` | build |
| `svs_storage_create_simple` | `SVSCreateSimpleStorage` | build |
| `svs_storage_create_leanvec` | `SVSCreateLeanVecStorage` | build |
| `svs_storage_free` | `SVSFreeStorage` | build |
| `svs_index_builder_create` | `SVSCreateBuilder` | build |
| `svs_index_builder_set_storage` | `SVSBuilderSetStorage` | build |
| `svs_index_builder_set_threadpool` | `SVSBuilderSetThreadpool` | build |
| `svs_index_builder_free` | `SVSFreeBuilder` | build |
| `svs_index_build_dynamic` | `SVSBuildDynamicIndex` | build |
| `svs_index_free` | `SVSFreeIndex` | all |
| `svs_index_save` | `SVSSaveIndex` | serialization |
| `svs_index_load_dynamic` | `SVSLoadDynamicIndex` | serialization |
| `svs_search_params_create_vamana` | `SVSSearch` / `SVSBatchSearch` | search |
| `svs_index_search` | `SVSSearch` / `SVSBatchSearch` | search |
| `svs_search_params_free` | `SVSSearch` / `SVSBatchSearch` | search |
| `svs_search_results_free` | `SVSSearch` / `SVSBatchSearch` | search |
| `svs_search_results_get_n/id/distance` | `SVSSearch` / `SVSBatchSearch` | search |
| `svs_index_dynamic_add_points` | `SVSAddPoints` | dynamic |
| `svs_index_dynamic_delete_points` | `SVSDeletePoints` | dynamic |
| `svs_index_dynamic_has_id` | `SVSHasId` | dynamic |
| `svs_index_dynamic_consolidate` | `SVSConsolidate` | maintenance |
| `svs_index_dynamic_compact` | `SVSCompact` | maintenance |

### Not implemented

The following were considered during design and are recorded here for future reference:

| Capability | Notes |
|---|---|
| Memory usage query | No `svs_index_memory_usage`; `maintenance_work_mem` is not yet enforced during SVS builds |
| Build memory limit | No `svs_index_builder_set_memory_limit`; SVS manages memory internally |
| Custom memory allocator | Not needed; SVS and PostgreSQL memory management are kept separate |
| Batch insert from a single `INSERT` statement | `SVSAddPoints` is called once per row; potential future optimization |
| `pg_upgrade` compatibility | Not yet verified; index save directories are outside the PostgreSQL data format |
