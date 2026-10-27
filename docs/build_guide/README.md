# Build Guide

## Requirements

- Linux x86-64
- GCC 11+
- Git
- curl
- OpenMP (`libgomp`, included with GCC)

## Setup

Edit `config` before running any scripts. At minimum set:

- `PGSQL_INSTALL_DIR` — PostgreSQL installation path (or set `PG_CONFIG` directly to skip building PostgreSQL)

All other paths default to subdirectories relative to the `config` file location.

## Steps

### 1. PostgreSQL

Skip if PostgreSQL is already installed. Set `PG_CONFIG` in `config` to point to the existing `pg_config` binary.

Otherwise:

```bash
./install_postgres.sh
```

### 2. SVS

```bash
./build_svs.sh
```

Downloads the prebuilt SVS C API release (`SVS_TAG` in `config`) and extracts it to `SVS_INSTALL_DIR`.

### 3. Vanilla pgvector

```bash
./build_pgvector_vanilla.sh
```

Builds and installs stock pgvector into the PostgreSQL installation. This provides
the `vector` and `halfvec` types that the `svs` extension depends on.

If `PGV_VANILLA_DIR` already contains pgvector source, the clone step is skipped.

### 4. svs extension

```bash
./build_svs_extension.sh
```

Builds and installs the `svs` extension into the PostgreSQL installation.

If `SVS_EXT_REPO` is set in `config`, the extension source is cloned from that
repository. Otherwise the script builds from the source tree at `SVS_EXT_DIR`
(which defaults to the repository root two levels above this directory).

## All-in-one

```bash
./build_all.sh
```

Runs all steps in order. Skips `install_postgres.sh` if `PG_CONFIG` already points
to an existing binary.

## Required PostgreSQL settings

Add these to `postgresql.conf` and restart the server:

```
shared_preload_libraries = 'svs'
wal_level = logical
max_wal_senders = 10
max_replication_slots = 10
```

`wal_level = logical` is required. Without it the launcher stops at startup and no worker starts. Keep `max_wal_senders` at or above the PostgreSQL default of 10.

The extension creates one logical replication slot for each Vamana index. Set `max_replication_slots` to the number of Vamana indexes plus the slots other features use (for example physical replicas), and keep some spare. The default of 10 allows about 10 indexes in the whole cluster.

pgvector must be installed. In each database that hosts Vamana indexes, run `CREATE EXTENSION vector;` before `CREATE EXTENSION svs;`.

Then enroll each database that hosts Vamana indexes. Run this in the launcher database (`svs.launcher_database`, default `postgres`):

```sql
INSERT INTO vamana_databases (datname) VALUES ('mydb');
```

See the [user guide](../USER_GUIDE.md#2-prerequisites) for details.
