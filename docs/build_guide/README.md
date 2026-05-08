# Build Guide

## Requirements

- Linux x86-64
- GCC 11+
- CMake >= 3.24 (see note below)
- Git
- OpenMP (`libgomp`, included with GCC)

### Note: CMake version

CMake 3.24 is required by SVS's `FetchContent` URL handling.

> **Note:** This requirement is expected to be removed soon once the upstream `FetchContent` dependency is eliminated, enabling compatibility with older CMake versions.

If your system ships an older version, you can upgrade via pip:

```bash
pip install cmake --upgrade
```

Or via Kitware's APT repository:

```bash
wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc | sudo apt-key add -
sudo apt-add-repository 'deb https://apt.kitware.com/ubuntu/ jammy main'
sudo apt-get update && sudo apt-get install cmake
```



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

Builds the SVS C API library and installs it to `SVS_INSTALL_DIR`.

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
