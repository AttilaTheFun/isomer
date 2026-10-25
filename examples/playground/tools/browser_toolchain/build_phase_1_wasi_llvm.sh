#!/bin/bash
# Phase 1: LLVM + clang libraries + lld, HOST = wasm32-wasip1 (single-threaded,
# WebAssembly backend only). CMake has no WASI platform, so UNIX=1 is forced
# on the command line (LLVM keys its Unix/Windows split on it). Produces build/wasi-llvm/bin/lld.wasm (= wasm-ld
# by argv[0]) and the static libraries swift-frontend links.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
cd "$ISO_WORKSPACE"
"$HERE/build_phase_0_wasi_support.sh"
mkdir -p build/wasi-llvm
cmake -S llvm-project/llvm -B build/wasi-llvm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/wasi-toolchain.cmake" \
    -DUNIX=1 \
    -DLLVM_HOST_TRIPLE=wasm32-unknown-wasip1 \
    -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-unknown-wasip1 \
    -DLLVM_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TABLEGEN="$PWD/build/host-tblgen/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$PWD/build/host-tblgen/bin/clang-tblgen" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_INCLUDE_DOCS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DLLVM_BUILD_UTILS=OFF \
    -DCLANG_BUILD_TOOLS=OFF \
    -DLLD_BUILD_TOOLS=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_LIBPFM=OFF \
    -DLLVM_ENABLE_THREADS=OFF \
    -DLLVM_ENABLE_PLUGINS=OFF \
    -DLLVM_ENABLE_BACKTRACES=OFF \
    -DLLVM_ENABLE_CRASH_OVERRIDES=OFF \
    -DLLVM_ENABLE_PIC=OFF \
    -DLLVM_ENABLE_UNWIND_TABLES=OFF \
    -DLLVM_ENABLE_EH=OFF \
    -DLLVM_ENABLE_RTTI=OFF \
    -DLLVM_ENABLE_ASSERTIONS=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF
"$NINJA" -C build/wasi-llvm -j"$JOBS" lld
# The libraries swift-frontend links (clang*, LLVM*): everything else.
"$NINJA" -C build/wasi-llvm -j"$JOBS"
echo "PHASE 1 (lld) OK"; ls -la build/wasi-llvm/bin/
