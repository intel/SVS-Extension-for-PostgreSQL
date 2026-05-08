#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ -d "$SVS_SRC_DIR" ]]; then
    echo "Directory $SVS_SRC_DIR already exists. Skipping clone..." >&2
else
    git clone --recurse-submodules --branch "$SVS_BRANCH" "$SVS_REPO" "$SVS_SRC_DIR"
fi

mkdir -p "$SVS_BUILD_DIR"

cmake -S "${SVS_SRC_DIR}/bindings/c" \
      -B "$SVS_BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DSVS_RUNTIME_ENABLE_LVQ_LEANVEC=ON \
      -DCMAKE_INSTALL_PREFIX="$SVS_INSTALL_DIR"

cmake --build "$SVS_BUILD_DIR" -j"$(nproc)"
cmake --install "$SVS_BUILD_DIR"
