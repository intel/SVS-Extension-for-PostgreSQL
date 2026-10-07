#!/bin/bash

set -e

source "$(dirname "${BASH_SOURCE[0]}")/config"

if [[ -d "$SVS_SRC_DIR" ]]; then
    echo "Directory $SVS_SRC_DIR already exists. Skipping clone..." >&2
else
    git clone --recurse-submodules --branch "$SVS_BRANCH" "$SVS_REPO" "$SVS_SRC_DIR"
fi

# SVS_COMMIT pins bindings/c to the exact commit SVS_URL's tarball was built
# from, overriding SVS_BRANCH's floating tip so the two can't drift apart.
if [[ -n "$SVS_COMMIT" ]]; then
    (cd "$SVS_SRC_DIR" && git checkout "$SVS_COMMIT" && git submodule update --init --recursive)
fi

# Configure from scratch. SVS_URL is a CACHE STRING and the fetched tree
# persists in _deps/svs-src, so a stale cache would keep the previous SVS_URL
# (and its archive) even after you change it, making the change look like it
# had no effect.
rm -rf "$SVS_BUILD_DIR"

SVS_URL_ARGS=()
[[ -n "$SVS_URL" ]] && SVS_URL_ARGS=(-DSVS_URL="$SVS_URL")

cmake -S "${SVS_SRC_DIR}/bindings/c" \
      -B "$SVS_BUILD_DIR" \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DSVS_RUNTIME_ENABLE_LVQ_LEANVEC=ON \
      "${SVS_URL_ARGS[@]}" \
      -DCMAKE_INSTALL_PREFIX="$SVS_INSTALL_DIR"

cmake --build "$SVS_BUILD_DIR" -j"$(nproc)"
cmake --install "$SVS_BUILD_DIR"
