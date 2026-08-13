# SVS — Vamana Index, LeanVec and LVQ Compression for PostgreSQL pgvector

A PostgreSQL extension that adds the **Vamana** approximate nearest neighbor (ANN) index access method and **LeanVec**/**LVQ** compression to [pgvector](https://github.com/pgvector/pgvector), powered by Intel's [Scalable Vector Search (SVS)](https://github.com/IntelLabs/ScalableVectorSearch) library.

**Extension name:** `svs` &nbsp;|&nbsp; **Version:** 0.1.0 &nbsp;|&nbsp; **License:** PostgreSQL

## Features

- Graph-based ANN index using the Vamana algorithm
- Supports `vector` (float32) and `halfvec` (float16) types from pgvector
- Three distance metrics: L2 (`<->`), inner product (`<#>`), cosine (`<=>`)
- LeanVec and LVQ compression to reduce memory usage by 50–75%
- Dynamic index: incremental `INSERT` and `DELETE` without full rebuilds
- On-disk persistence — index survives server restarts
- Background worker for a shared index cache across backends
- AVX-512 optimizations on Intel Xeon processors

## Requirements

| Dependency | Version |
|---|---|
| PostgreSQL | 13+ |
| pgvector extension | latest |
| Intel SVS C API (`libsvs_c_api.so`) | see [build guide](docs/build_guide/README.md) |
| GCC | 11+ |
| CMake | 3.24+ (for building SVS) |
| `gcovr` | 5.0+ — optional, only for `make coverage` ([coverage guide](docs/dev/CODE_COVERAGE.md)) |

An Intel Xeon processor with AVX-512 is recommended for best performance. The extension works on any x86_64 platform but falls back to scalar code.

**Linux only.** The extension and its SVS dependency are only supported on Linux; there is no macOS or Windows support.

## Building

Building SVS and the extension involves compiling Intel's SVS C API, then building the extension against it. See the [build guide](docs/build_guide/README.md) for the full sequence, prerequisites, and an all-in-one build script.

```bash
make          # build the extension (SVS_INSTALL must point at your SVS install prefix)
make install
```

Coverage instrumentation is opt-in and off by default; build with `make COVERAGE=1` to enable it. See the [coverage guide](docs/dev/CODE_COVERAGE.md).

## Quick Start

```sql
CREATE EXTENSION vector;
CREATE EXTENSION svs;

CREATE TABLE items (id serial PRIMARY KEY, embedding vector(768));

-- Create a Vamana index
CREATE INDEX ON items USING vamana (embedding vector_l2_ops);

-- Nearest-neighbor search
SELECT id FROM items ORDER BY embedding <-> '[0.1, 0.2, ...]' LIMIT 10;
```

Vamana is a graph-based ANN algorithm, similar in spirit to HNSW but using a single flat graph and a robust-pruning rule that keeps recall high even at low search-window sizes. LeanVec and LVQ are two compression modes that trade memory for a small amount of recall — LeanVec projects vectors into a lower-dimensional space before quantizing and suits large, high-dimensional datasets; LVQ quantizes vectors in their original space with no training step and suits smaller datasets or constrained build times.

For index options, compression tuning, session parameters, the background worker, operational guidance, monitoring, and troubleshooting, see the [user guide](docs/USER_GUIDE.md).

## Architecture

The extension implements a PostgreSQL index access method backed by a background worker that owns the SVS graph in shared memory, communicating with backends over IPC. Writes are synchronous for visibility and use an undo log plus WAL/replication-slot replay for crash recovery and durability. See the [architecture doc](docs/dev/ARCHITECTURE.md) for the full design, including ACID compliance, checkpointing, and GUC reference.

## Running Tests

```bash
# SQL regression tests
make installcheck

# Perl TAP tests (background worker, persistence)
make prove_installcheck
```

Test files are in `test/sql/` and `test/t/`.

