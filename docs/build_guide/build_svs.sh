#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ -d "$SVS_SRC_DIR" ]]; then
    echo "Directory $SVS_SRC_DIR already exists. Skipping clone..." >&2
else
    git clone --recurse-submodules --branch "$SVS_BRANCH" "$SVS_REPO" "$SVS_SRC_DIR"
fi

# Configure from scratch. SVS_URL is a CACHE STRING and the fetched tree persists
# in _deps/svs-src, so a stale cache would pin the previous LVQ/LeanVec setting and
# archive, making a changed SVS_LVQ_LEANVEC look like it had no effect.
rm -rf "$SVS_BUILD_DIR"

cmake -S "${SVS_SRC_DIR}/bindings/c" \
      -B "$SVS_BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DSVS_RUNTIME_ENABLE_LVQ_LEANVEC="$SVS_LVQ_LEANVEC" \
      -DCMAKE_INSTALL_PREFIX="$SVS_INSTALL_DIR"

cmake --build "$SVS_BUILD_DIR" -j"$(nproc)"
cmake --install "$SVS_BUILD_DIR"
