# SVS C API Reference for pgvector-optimizations

<!-- Last updated: Apr 2026. Owner: svs-integration team. Update when SVS C API changes or new bindings are added. -->

API header: `svs/bindings/c/include/svs/c_api/svs_c.h`
Usage example: `svs/bindings/c/samples/simple.c`

## Available APIs (as of Feb 2026)

```c
// Configure Vamana algorithm parameters
svs_algorithm_create_vamana(graph_degree, build_window, search_window)

// Storage backends
svs_storage_create_simple(data_type)                          // float32/float16/int8
svs_storage_create_leanvec(dims, primary, secondary)          // LeanVec compression

// Builder pattern — index creation
svs_index_builder_create(metric, dimension, algorithm)
svs_index_build(builder, data, num_vectors)                   // batch build from float array

// Search
svs_index_search(index, queries, num_queries, k, search_params)
svs_search_params_create_vamana(search_window_size)
svs_search_params_free()

// Persistence
svs_index_save(index, path)
svs_index_load(path, config)
```

## Supported distances

`SVS_DISTANCE_METRIC_EUCLIDEAN`, `SVS_DISTANCE_METRIC_COSINE`, `SVS_DISTANCE_METRIC_DOT_PRODUCT`

## Supported data types

`SVS_DATA_TYPE_FLOAT32`, `FLOAT16`, `INT8`, `UINT8`, `INT4`, `UINT4`

## Dynamic index APIs (available as of Apr 2026)

```c
// Build mutable index with explicit external IDs
svs_index_build_dynamic(builder, data, ids, num_vectors, blocksize_bytes)  // ids=NULL lets SVS assign

// Load previously saved dynamic index
svs_index_load_dynamic(builder, directory, blocksize_bytes)

// Incremental mutations (work on handles returned by build_dynamic/load_dynamic)
svs_index_dynamic_add_points(index, new_points, ids, num_vectors)          // returns count added
svs_index_dynamic_delete_points(index, ids, num_ids)                       // soft-delete by external ID
svs_index_dynamic_has_id(index, id, out_has_id)                            // check if ID exists
svs_index_dynamic_consolidate(index)                                       // patch graph around deletes
svs_index_dynamic_compact(index, batchsize)                                // reclaim deleted memory
```

`svs_index_search()` and `svs_index_save()` work with dynamic indexes.
Search returns **external IDs** (the ids passed at build/insert time), not positional indices.

## Usage pattern

Static: Builder → batch build → search → save/load.
Dynamic: Builder → `build_dynamic` → `add_points`/`delete_points` → search → save → `load_dynamic`.

## NOT YET AVAILABLE

- IVF algorithm — only Vamana is supported in the current SVS build path

## Storage support matrix

| Storage | Build | Search | Notes |
|---------|-------|--------|-------|
| Vamana + Simple | Yes | Yes | float32/float16/int8 |
| Vamana + LeanVec | Yes | Yes | primary/secondary compression |
| Vamana + LVQ | Partial | — | `compression_type=2`, not fully wired |
