#!/bin/bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/config"

# SVS ships its C API as a ready-to-use prebuilt tree (lib/ + include/svs/c/);
# just download and extract it, no compiler involved. Clear any previous
# install first so a stale file from an older SVS_TAG can't linger.
rm -rf "$SVS_INSTALL_DIR"
mkdir -p "$SVS_INSTALL_DIR"
curl -fsSL "$SVS_URL" | tar xz -C "$SVS_INSTALL_DIR"
