#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ -d "$PGSQL_SRC_DIR" ]]; then
    echo "Directory $PGSQL_SRC_DIR already exists. Skipping clone..." >&2
else
    git clone "$PGSQL_REPO" "$PGSQL_SRC_DIR"
fi

mkdir -p "$PGSQL_INSTALL_DIR"

cd "$PGSQL_SRC_DIR"
git checkout "$PGSQL_VERSION"
# PG_CONFIGURE_EXTRA_ARGS is unset by default so callers that don't need
# extra configure flags (e.g. codeql.yml) see no change in behavior.
./configure --prefix="$PGSQL_INSTALL_DIR" ${PG_CONFIGURE_EXTRA_ARGS:-}
make -j"$(nproc)"
make install

make -C "$PGSQL_SRC_DIR/src/bin/pg_config" && make -C "$PGSQL_SRC_DIR/src/bin/pg_config" install
make -C "$PGSQL_SRC_DIR/contrib/pg_prewarm" && make -C "$PGSQL_SRC_DIR/contrib/pg_prewarm" install
