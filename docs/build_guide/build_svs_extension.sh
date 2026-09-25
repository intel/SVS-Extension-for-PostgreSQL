#!/bin/bash

# Build and install the standalone svs PostgreSQL extension.
# Prerequisites:
#   1. PostgreSQL installed (install_postgres.sh or existing installation)
#   2. Vanilla pgvector installed (build_pgvector_vanilla.sh)
#   3. SVS library installed (build_svs.sh)

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ ! -f "$PG_CONFIG" ]]; then
    echo "Error: pg_config not found at $PG_CONFIG" >&2
    echo "Set PGSQL_INSTALL_DIR in config and run install_postgres.sh, or set PG_CONFIG to an existing installation." >&2
    exit 1
fi

if [[ ! -f "$SVS_INSTALL_DIR/lib/libsvs_c_api.so" ]]; then
    echo "Error: SVS library not found at $SVS_INSTALL_DIR/lib/libsvs_c_api.so" >&2
    echo "Run build_svs.sh first." >&2
    exit 1
fi

if [[ -n "$SVS_EXT_REPO" ]]; then
    if [[ -d "$SVS_EXT_DIR" ]]; then
        echo "Directory $SVS_EXT_DIR already exists. Skipping clone..." >&2
    else
        if [[ -z "$SVS_EXT_BRANCH" ]]; then
            echo "Error: SVS_EXT_BRANCH is not set in config." >&2
            exit 1
        fi
        git clone --branch "$SVS_EXT_BRANCH" "$SVS_EXT_REPO" "$SVS_EXT_DIR"
    fi
fi

export PG_CONFIG

cd "$SVS_EXT_DIR"
make -j"$(nproc)" SVS_INSTALL="$SVS_INSTALL_DIR"
make install SVS_INSTALL="$SVS_INSTALL_DIR"
