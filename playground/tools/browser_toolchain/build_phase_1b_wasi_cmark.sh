#!/bin/bash
# Phase 1b: cmark for the wasm host (swift-frontend links it for doc comments).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
cd "$ISO_WORKSPACE"
mkdir -p build/wasi-cmark
cmake -S cmark -B build/wasi-cmark -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/wasi-toolchain.cmake" \
    -DUNIX=1 \
    -DCMARK_TESTS=OFF -DCMARK_SHARED=OFF -DCMARK_STATIC=ON \
    -DBUILD_TESTING=OFF
"$NINJA" -C build/wasi-cmark -j"$JOBS"
echo "PHASE 1b OK"; ls build/wasi-cmark/src/*.a
