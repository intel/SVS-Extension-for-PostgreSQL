# SVS — Vamana Index, LeanVec and LVQ Compression for PostgreSQL pgvector

A PostgreSQL extension that adds the **Vamana** approximate nearest neighbor (ANN) index access method and **LeanVec**/**LVQ** compression to [pgvector](https://github.com/pgvector/pgvector), powered by Intel's [Scalable Vector Search (SVS)](https://github.com/IntelLabs/ScalableVectorSearch) library.

**Extension name:** `svs` &nbsp;|&nbsp; **Version:** 0.1.0 &nbsp;|&nbsp; **License:** PostgreSQL

## Features

- Graph-based ANN index using the Vamana algorithm
- Supports `vector` (float32) and `halfvec` (float16) types from pgvector, each stored in its own element format
- Three distance metrics: L2 (`<->`), inner product (`<#>`), cosine (`<=>`)
- LeanVec and LVQ compression to reduce memory usage by 50–75%
- Dynamic index: incremental `INSERT` and `DELETE` without full rebuilds
- On-disk persistence — index survives server restarts
- Background worker for a shared index cache across backends

## Requirements

| Dependency | Version |
|---|---|
| PostgreSQL | 18.1+ |
| pgvector extension | 0.8.2+ |
| Intel SVS C API (`libsvs_c_api.so`) | see [build guide](docs/build_guide/README.md) |
| GCC | 11+ |
| `gcovr` | 5.0+ — optional, only for `make coverage` ([coverage guide](docs/dev/CODE_COVERAGE.md)) |

An Intel Xeon processor with AVX-512 is recommended for best performance. The Vamana index runs on x86-64 CPUs from any vendor. LeanVec and LVQ compression are supported only on Intel CPUs; on other CPUs, creating a compressed index fails with an error.

**Linux x86-64 only.** The extension and its SVS dependency are only supported on Linux x86-64; there is no ARM, macOS or Windows support.

## Building

See the [build guide](docs/build_guide/README.md) for the full sequence, prerequisites, and an all-in-one build script.

Coverage instrumentation is opt-in and off by default; build with `make COVERAGE=1` to enable it. See the [coverage guide](docs/dev/CODE_COVERAGE.md).

## Quick Start

Before you start, set the required server settings (for example `wal_level = logical`) and restart the server. See [Required PostgreSQL settings](docs/build_guide/README.md#required-postgresql-settings).

In the launcher database (`svs.launcher_database`, default `postgres`), create the extensions and enroll your database:

```sql
CREATE EXTENSION vector;
CREATE EXTENSION svs;
INSERT INTO vamana_databases (datname) VALUES ('mydb');
```

Then, in each database that hosts indexes (`mydb` here):

```sql
CREATE EXTENSION vector;
CREATE EXTENSION svs;

CREATE TABLE items (id serial PRIMARY KEY, embedding vector(768));

-- Create a Vamana index
CREATE INDEX ON items USING vamana (embedding vector_l2_ops);

-- Nearest-neighbor search
SELECT id FROM items ORDER BY embedding <-> '[0.1, 0.2, ...]' LIMIT 10;
```

Vamana is a graph-based ANN algorithm, similar in spirit to HNSW but using a single flat graph and a robust-pruning rule that keeps recall high even at low search-window sizes. LeanVec and LVQ are two compression modes that trade memory for a small amount of recall — LeanVec projects vectors into a lower-dimensional space before quantizing and suits large, high-dimensional datasets; LVQ quantizes vectors in their original space, with no projection to fit, and suits smaller datasets or constrained build times.

For index options, compression tuning, session parameters, the background worker, operational guidance, monitoring, and troubleshooting, see the [user guide](docs/USER_GUIDE.md).

## Architecture

The extension implements a PostgreSQL index access method backed by a per-database background worker that owns the SVS graph in its own process-private memory, communicating with backends over IPC. Writes are synchronous for visibility and use an undo log plus WAL/replication-slot replay for crash recovery and durability. See the [architecture doc](docs/dev/ARCHITECTURE.md) for the full design, including ACID compliance, checkpointing, and GUC reference.

## Running Tests

Set `SVS_INSTALL` (SVS install prefix) and `PG_CONFIG` (path to `pg_config`) if they are not in the default locations. The `all-in-one` build in the [build guide](docs/build_guide/README.md) does not set them in your shell (its config variable is `SVS_INSTALL_DIR`). The PostgreSQL it builds has no `--enable-tap-tests`, so `make prove_installcheck` needs a PostgreSQL built with TAP tests enabled.

Build and install the extension:

```bash
make SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
make install SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
```

Then start the server with the settings in [Required PostgreSQL settings](docs/build_guide/README.md#required-postgresql-settings). The tests need a running server.

<sub>**Note:** `installcheck` and `prove_installcheck` refuse to run if the installed `svs.so` differs from the one just built. Run `make install` first if you see that error.</sub>

### SQL regression tests

```bash
make installcheck SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
```

### Perl TAP tests (background worker, persistence)

```bash
make prove_installcheck SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
```

### Hardware dependent tests

`installcheck` and `prove_installcheck` exclude tests that build real LeanVec or LVQ compressed indexes (`halfvec_compression`, `vector_compression`, `39_persistence_compression.pl`, `44_build_memory_calibration_compression.pl`). These need AVX-512 hardware, which most CI runners lack. Run them separately, on hardware that supports it:

```bash
make installcheck-hw SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
make prove_installcheck-hw SVS_INSTALL=/path/to/svs_install PG_CONFIG=/path/to/pg_config
```

Test files are in `test/sql/` and `test/t/`.

## Known Limitations and Performance

See [Known Limitations](docs/dev/ARCHITECTURE.md#84-known-limitations) for performance considerations and current limits, such as searches waiting during writes.
