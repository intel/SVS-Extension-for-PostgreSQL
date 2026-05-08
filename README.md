# SVS — Vamana Index, LeanVec and LVQ compression for PostgreSQL pgvector

A PostgreSQL extension that adds the **Vamana** approximate nearest neighbor (ANN) index access method, LeanVec and LVQ compression techniques to [pgvector](https://github.com/pgvector/pgvector), powered by Intel's [Scalable Vector Search (SVS)](https://github.com/IntelLabs/ScalableVectorSearch) library.

**Extension name:** `svs` &nbsp;|&nbsp; **Version:** 0.1.0 &nbsp;|&nbsp; **License:** PostgreSQL

## Features

- Graph-based ANN index using the Vamana algorithm
- Supports `vector` (float32) and `halfvec` (float16) types from pgvector
- Three distance metrics: L2 (`<->`), inner product (`<#>`), cosine (`<=>`)
- LeanVec and LVQ compression to reduce memory usage by 50–75%
- Dynamic index: incremental `INSERT` and `DELETE` without full rebuilds
- On-disk persistence — index survives server restarts
- Optional background worker for a shared index cache across backends
- AVX-512 optimizations on Intel Xeon processors

## Requirements

| Dependency | Version |
|---|---|
| PostgreSQL | 13+ |
| pgvector extension | latest |
| Intel SVS C API (`libsvs_c_api.so`) | see build guide |
| GCC | 11+ |
| CMake | 3.24+ (for building SVS) |

An Intel Xeon processor with AVX-512 is recommended for best performance. The extension works on any x86_64 platform but falls back to scalar code.

## Build and Install

### 1. Build the SVS library

Build and install Intel SVS with the C API enabled:

```bash
cmake -S /path/to/svs/bindings/c -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DSVS_RUNTIME_ENABLE_LVQ_LEANVEC=ON \
  -DCMAKE_INSTALL_PREFIX=${SVS_INSTALL}
cmake --build build -j$(nproc)
cmake --install build
```

### 2. Build the extension

```bash
make
make install
```

The Makefile expects the SVS library at `${SVS_INSTALL}/lib/libsvs_c_api.so`. Set `SVS_INSTALL` to your SVS install prefix before building.

To disable CPU-specific optimizations (e.g., for packaging):

```bash
make OPTFLAGS=""
```

## Algorithm Background

### Vamana

Vamana is a graph-based ANN algorithm that builds a single-layer navigable random graph over the dataset. Each node stores at most `graph_degree` directed edges to its nearest neighbors. At query time, a greedy beam search starts from a fixed entry point and follows edges toward the query vector, maintaining a priority queue of the best `search_window_size` candidates seen so far.

Compared to HNSW, Vamana uses a single flat graph (no hierarchy), relies on a **robust pruning** rule (controlled by `alpha`) that deliberately retains edges to more distant neighbors when they provide directional diversity — this avoids local minima and maintains strong recall even at low `search_window_size` values. The SVS implementation is further optimized for Intel AVX-512: distance computations are fused with SIMD gather instructions so the graph traversal saturates vector execution units rather than memory bandwidth.

Key tuning levers:
- **`graph_degree`** — out-degree per node. 32 is lightweight; 64 is a good default; 96–128 for demanding recall targets.
- **`alpha`** — stored as `alpha / 100.0`; SVS default is 1.2 for L2. Values above 1.0 make pruning more conservative (more edges kept → better recall, larger graph). Values near 1.0 produce a leaner graph.
- **`build_window_size`** — search window used during index construction. Larger values improve graph quality at the cost of build time.
- **`search_window_size`** — the primary recall/latency dial at query time. Increase it to trade latency for recall; decrease it for higher throughput at acceptable recall.

### LeanVec

LeanVec reduces memory usage by projecting vectors into a lower-dimensional space and quantizing them. It delivers the best compression efficiency for large, high-dimensional datasets (≥ 100k vectors, ≥ 256 dims) but requires enough data to train the projection — expect a recall warning below 100k vectors.

The `leanvec_dims` parameter controls the reduced dimensionality (default: `dimensions / 2`). Lower values save more memory but hurt recall; start with the default and adjust based on recall measurements.

### LVQ (Locally-adapted Vector Quantization)

LVQ quantizes vectors in their original space using per-vector scale factors. There is no training step, so it works well on smaller datasets (≥ 10k vectors) and is faster to build than LeanVec. It delivers 4–8× memory reduction depending on bit width, with less compression efficiency than LeanVec on large high-dimensional data.

## Usage

```sql
CREATE EXTENSION vector;
CREATE EXTENSION svs;

CREATE TABLE items (id serial PRIMARY KEY, embedding vector(768));

-- Create a Vamana index
CREATE INDEX ON items USING vamana (embedding vector_l2_ops);

-- Nearest-neighbor search
SELECT id FROM items ORDER BY embedding <-> '[0.1, 0.2, ...]' LIMIT 10;
```

Operator classes: `vector_l2_ops`, `vector_ip_ops`, `vector_cosine_ops`, `halfvec_l2_ops`, `halfvec_ip_ops`, `halfvec_cosine_ops`.

## Index Options

Set at `CREATE INDEX ... WITH (...)`.

### Graph parameters

| Option | Default | Range | Description |
|---|---|---|---|
| `graph_degree` | 64 | 16–256 | Max neighbors per node. Higher → better recall, more memory. |
| `alpha` | -1 | -1–200 | Pruning aggressiveness (stored as `alpha / 100.0`). -1 uses SVS default (1.2 for L2). |
| `build_window_size` | -1 | -1–1000 | Search window during graph construction. -1 = 2 × `graph_degree`. |
| `search_window_size` | 100 | 10–10000 | Search window used at query time (overridable per session). |
| `use_search_history` | true | — | Track visited nodes during traversal to skip revisits. |

### Compression

| Option | Default | Range | Description |
|---|---|---|---|
| `compression_type` | 0 | 0–2 | 0 = none (FP32), 1 = LeanVec, 2 = LVQ. |
| `compression_primary` | 8 | 4, -4, 8, -8 | Primary quantization bits (positive = unsigned, negative = signed). |
| `compression_secondary` | 8 | 4, -4, 8, -8 | Secondary quantization bits (must be ≥ primary precision). |
| `leanvec_dims` | -1 | -1–2000 | Reduced dimensionality for LeanVec. -1 = `dimensions / 2`. |

Compression requires ≥ 100k vectors for LeanVec and ≥ 10k for LVQ; expect a recall warning below these thresholds.

**LeanVec examples:**

```sql
-- LeanVec with 4-bit primary, 8-bit secondary, halved dimensionality (default)
CREATE INDEX ON items USING vamana (embedding vector_l2_ops)
  WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8);

-- LeanVec with explicit reduced dimensionality for 1536-dim embeddings
CREATE INDEX ON items USING vamana (embedding vector_l2_ops)
  WITH (compression_type = 1, compression_primary = 4, compression_secondary = 8,
        leanvec_dims = 512);

-- LeanVec targeting maximum memory savings (4-bit both components)
CREATE INDEX ON items USING vamana (embedding vector_l2_ops)
  WITH (compression_type = 1, compression_primary = 4, compression_secondary = 4,
        leanvec_dims = 256);
```

**LVQ examples:**

```sql
-- LVQ 4×8: good recall/memory balance, no training data minimum beyond 10k
CREATE INDEX ON items USING vamana (embedding vector_l2_ops)
  WITH (compression_type = 2, compression_primary = 4, compression_secondary = 8);

-- LVQ 8×8: highest LVQ recall, ~4× memory reduction vs FP32
CREATE INDEX ON items USING vamana (embedding vector_l2_ops)
  WITH (compression_type = 2, compression_primary = 8, compression_secondary = 8);
```

**Choosing between LeanVec and LVQ:**

| Scenario | Recommendation |
|---|---|
| Large dataset (> 100k), high-dimensional (≥ 256 dims) | LeanVec — better recall per byte |
| Small dataset (< 100k) or low-dimensional vectors | LVQ — no training requirement |
| Build time is constrained | LVQ — no projection training step |
| Maximum compression is the priority | LeanVec with `compression_primary = 4`, `compression_secondary = 4` |

## Session Parameters (GUCs)

Tune at runtime with `SET`:

| Parameter | Default | Range | Description |
|---|---|---|---|
| `vamana.search_window_size` | 100 | 10–10000 | Overrides the index's `search_window_size` for the current session. |
| `vamana.search_num_threads` | 0 | 0–1024 | Threads for SVS search. 0 = auto (nproc − 1). |
| `vamana.compact_threshold_pct` | 10 | 0–100 | `VACUUM` triggers a compact pass when soft-deletes exceed this percentage of total vectors. |

```sql
-- Trade recall for speed
SET vamana.search_window_size = 20;
SELECT id FROM items ORDER BY embedding <-> query LIMIT 5;

-- Trade speed for recall
SET vamana.search_window_size = 500;
```

## Background Worker

The background worker holds a shared SVS index handle across all backends, enabling batched queries and avoiding per-backend load overhead.

To enable, add to `postgresql.conf`:

```
shared_preload_libraries = 'svs'
vamana.worker_enabled = on
vamana.worker_database = 'mydb'
```

Additional worker parameters:

| Parameter | Default | Description |
|---|---|---|
| `vamana.worker_timeout_ms` | 5000 | ms to wait for worker response before falling back to direct load. |
| `vamana.max_batch_size` | 0 | Max queries per SVS batch call. 0 = unlimited. |

## Running Tests

```bash
# SQL regression tests
make installcheck

# Perl TAP tests (background worker, persistence)
make prove_installcheck
```

Test files are in `test/sql/` (`vamana_vector.sql`, `vamana_halfvec.sql`, `vamana_dynamic.sql`) and `test/t/`.


