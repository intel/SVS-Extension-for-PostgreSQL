#!/bin/bash

# Build and install vanilla pgvector (no SVS integration).
# Provides the vector/halfvec types that the svs extension depends on.
# Prerequisites: install_postgres.sh must have run first.

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ ! -f "$PG_CONFIG" ]]; then
    echo "Error: pg_config not found at $PG_CONFIG" >&2
    echo "Set PGSQL_INSTALL_DIR in config and run install_postgres.sh, or set PG_CONFIG to an existing installation." >&2
    exit 1
fi

if [[ -d "$PGV_VANILLA_DIR" ]]; then
    echo "Directory $PGV_VANILLA_DIR already exists. Skipping clone..." >&2
else
    git clone --branch "$PGV_VANILLA_TAG" "$PGV_VANILLA_REPO" "$PGV_VANILLA_DIR"
fi

export PG_CONFIG

cd "$PGV_VANILLA_DIR"
make -j"$(nproc)"
make install
