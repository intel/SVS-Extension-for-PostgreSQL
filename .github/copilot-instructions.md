# pgvector Development Guide for AI Coding Agents

## Project Overview
pgvector is a PostgreSQL extension providing vector similarity search with ACID compliance. This codebase implements custom data types (`vector`, `halfvec`, `bitvec`, `sparsevec`) and index access methods (HNSW, IVFFlat, Vamana) in C using the PostgreSQL extension API. This is an optimizations fork that integrates Intel's Scalable Vector Search (SVS) library to provide a third index type: Vamana. The Vamana index is implemented and functional, supporting batch builds, K-NN queries, LeanVec compression, and on-disk persistence.

## Architecture Components

### Core Data Types (`src/vector.c`, `src/halfvec.c`, `src/bitvec.c`, `src/sparsevec.c`)
- Each vector type follows PostgreSQL's type extension pattern with I/O functions, typmod support, and binary recv/send
- All functions must be declared with `FUNCTION_PREFIX PG_FUNCTION_INFO_V1()` for version compatibility (handles PG 15/16+ differences)
- Max dimensions: `VECTOR_MAX_DIM=16000`, `HNSW_MAX_DIM=2000`, `IVFFLAT_MAX_DIM=2000`, `VAMANA_MAX_DIM=2000`
- Distance functions use custom operators: `<->` (L2), `<#>` (inner product), `<=>` (cosine), `<+>` (L1), `<~>` (Hamming), `<%>` (Jaccard)
- Vector struct layout: `{vl_len_, dim, unused, x[]}` where `x[]` is flexible array member

### Index Access Methods

**HNSW** (`src/hnsw*.c`, `src/hnsw.h`):
- Two-phase build: in-memory graph construction (using shared memory for parallel builds with relative pointers) → on-disk insertion
- Element-level LWLocks protect neighbor modifications during parallel builds
- Parameters: `m` (connections, default 16, range 2-100), `ef_construction` (default 64, range 4-1000), `ef_search` (GUC, default 40, range 1-1000)
- Support functions via `HNSW_*_PROC` constants: distance, norm, type_info
- Parallel builds use relative pointers (`relptr`) with offset from `hnswarea` base address
- Entry point tracking: `entryBlkno/entryOffno/entryLevel` in metapage

**IVFFlat** (`src/ivfflat*.c`, `src/ivfflat.h`):
- Three-phase build: k-means clustering → tuple assignment → loading
- Parameters: `lists` (default 100, max 32768), `probes` (GUC, default 1)
- Uses generic xlog for WAL logging (see `test/t/*_wal.pl` tests)
- K-means implementation in `ivfkmeans.c` uses sampling for large datasets
- Centers stored on first pages, then data pages organized by cluster

**Vamana** (`src/vamana*.c`, `src/vamana.h`, `src/svs_wrapper.c`):
- Graph-based ANN index using Intel SVS library with Vamana algorithm
- Batch build: buffer all vectors from table scan → call SVS `svs_index_build()` → serialize to PostgreSQL pages
- SVS manages parallelism internally (no manual DSM coordination or LWLocks)
- On-disk persistence: index data serialized to filesystem via `SVSSaveIndex()`/`SVSLoadIndex()`, with TID mappings stored in PostgreSQL pages
- Backend-private `VamanaIndexCache` holds the deserialized SVS index in memory per-backend
- Parameters: `graph_degree` (default 64, range 16-256), `alpha` (default -1 = SVS default, range -1 to 200, scaled by 100), `build_window_size` (default -1 = 2×graph_degree, range -1 to 1000), `search_window_size` (GUC + reloption, default 100, range 10-10000)
- Compression: `compression_type` (0=none, 1=leanvec, 2=lvq), `compression_primary`/`compression_secondary` (4=UINT4, -4=INT4, 8=UINT8, -8=INT8), `leanvec_dims` (default -1 = dimensions/2)
- Support functions: `VAMANA_DISTANCE_PROC=1`, `VAMANA_NORM_PROC=2`, `VAMANA_TYPE_INFO_PROC=3`
- Object-access hook (`VamanaInstallObjectAccessHook`) cleans up on-disk save directories on DROP INDEX/TABLE
- Metapage format: `VamanaMetaPageData` with magic number, version, dimensions, parameters, and `hasSavedIndex` flag
- Indexes are built as **dynamic** (mutable) using `svs_index_build_dynamic`, enabling incremental INSERT and DELETE+VACUUM without full REINDEX
- Metapage fields: `nextExternalId`, `numDeleted`, `tidMappingCapacity` track dynamic index state
- `VAMANA_DYNAMIC_WRITE_LOCK_KEY` advisory lock serializes concurrent inserts and vacuum deletes

## Build System & Testing

### Build Commands
```bash
make                          # Build extension (uses PGXS from pg_config)
make install                  # Install to PostgreSQL (may need sudo)
make installcheck             # Run SQL regression tests (test/sql/*.sql)
make prove_installcheck       # Run Perl TAP tests (test/t/*.pl)
```

### Compilation Flags
Auto-vectorization is enabled (`-march=native -ftree-vectorize`). Use `OPTFLAGS=""` to disable CPU-specific flags for portability.

### Test Patterns
- **SQL regression**: `test/sql/*.sql` → expected output in `test/expected/*.out`
- **Perl TAP tests**: Use `PostgreSQL::Test::Cluster` for WAL replication, recall testing, and vacuum scenarios
- Test naming: number prefix indicates execution order (e.g., `001_ivfflat_wal.pl`, `012_hnsw_vector_build_recall.pl`)
- Recall tests verify approximate nearest neighbor accuracy after index operations
- WAL tests create primary/replica setup with streaming replication to verify generic xlog records

## Code Conventions

### PostgreSQL Version Compatibility
- Use `PG_VERSION_NUM` preprocessor checks (e.g., `#if PG_VERSION_NUM >= 150000`)
- `FUNCTION_PREFIX` macro handles function export differences between PG 15/16 (see `src/vector.h`)
- Current support: Postgres 13+

### Memory Management
- Index builds use `maintenance_work_mem` for graph sizing
- Dedicated memory contexts: `graphCtx` for HNSW in-memory phase
- Shared memory allocation with relative pointers (`relptr`) for parallel builds

### Naming Patterns
- Index-specific prefixes: `Hnsw*`, `Ivfflat*`, `Vamana*`, `Vector*` for functions/structs
- Build state structs: `HnswBuildState`, `IvfflatBuildState`, `VamanaBuildState` with phase tracking
- Opaque page data: `HnswPageOpaqueData`, `IvfflatPageOpaqueData`, `VamanaPageOpaqueData` for on-disk structures
- Tuple types: `HnswElementTuple`, `HnswNeighborTuple`, `IvfflatTuple` with type discriminators
- Handler functions: `hnswhandler`, `ivfflathandler`, `vamanahandler` implement `IndexAmRoutine` interface

### Support Functions & Operator Classes
- Each index type defines support functions via `*_PROC` constants (distance calculation, normalization, type info)
- Operator classes in `sql/vector.sql` bind operators to index access methods via strategy numbers

### Commenting Style
Delete comments that restate the code. Keep comments for non-obvious invariants, concurrency constraints, workarounds, and cross-references to PostgreSQL internals or SVS API contracts. See `.github/prompts/commenting-style.prompt.md` for extended guidance and examples.

## Performance Optimization

### Critical Hot Paths
- Distance calculations auto-vectorized (verify with `-fopt-info-vec` or `-Rpass=loop-vectorize`)
- HNSW neighbor selection in `src/hnswbuild.c` uses pruning heuristics
- IVFFlat k-means uses sampling for large datasets (see `src/ivfkmeans.c`)
- Enable `-DIVFFLAT_BENCH` for timing instrumentation (see `src/ivfflat.h`)

### GUC Parameters
- `hnsw.ef_search`, `ivfflat.probes`: Runtime query tuning (set per query/session)
- `vamana.search_window_size`: Runtime query tuning for Vamana scan search window (default 100, range 10-10000); forwarded to SVS via `svs_search_params_create_vamana()` on every search call
- `hnsw.iterative_scan`, `ivfflat.iterative_scan`: Enable relaxed ORDER BY semantics for LIMIT queries
- `maintenance_work_mem`: Controls in-memory graph size during index builds

## External Dependencies & Integration

### SVS Vamana Integration
- Third index access method following HNSW/IVFFlat patterns, fully functional
- Uses Intel SVS C API for AVX-512 optimizations on Xeon processors
- Batch build approach: SVS manages parallelism internally, simpler than HNSW's manual DSM coordination
- Implementation files: `src/vamana.c`, `src/vamanabuild.c`, `src/vamanascan.c`, `src/vamanainsert.c`, `src/vamanautils.c`, `src/vamanavacuum.c`, `src/svs_wrapper.c`
- Incremental INSERT support: uses `svs_index_build_dynamic` / `svs_index_dynamic_add_points` so new rows are searchable immediately without `REINDEX`
- Incremental DELETE support: `VACUUM` calls `svs_index_dynamic_delete_points` + consolidate/compact to remove dead tuples from the graph
- SVS C API details, available functions, and known gaps: see `.github/prompts/svs-api-reference.prompt.md`

## Common Development Tasks
See `.github/prompts/development-tasks.prompt.md` for step-by-step guides on adding new vector types, distance metrics, and index access methods, plus debugging and WAL replication testing workflows.
