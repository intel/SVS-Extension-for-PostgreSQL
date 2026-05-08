#!/bin/bash

# Build everything needed to run the svs extension:
#   1. PostgreSQL (skipped if PG_CONFIG already points to an existing binary)
#   2. SVS library
#   3. Vanilla pgvector (provides vector/halfvec types)
#   4. svs extension

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/config"

if [[ ! -f "$PG_CONFIG" ]]; then
    bash "$SCRIPT_DIR/install_postgres.sh"
fi

bash "$SCRIPT_DIR/build_svs.sh"
bash "$SCRIPT_DIR/build_pgvector_vanilla.sh"
bash "$SCRIPT_DIR/build_svs_extension.sh"
