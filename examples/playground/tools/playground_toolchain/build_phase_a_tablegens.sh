#!/bin/bash
# Phase A of the on-device Playground compiler: HOST llvm/clang tablegens
# (needed to cross-compile LLVM for iOS). Minimal native build — just the
# tablegen targets, Release, no assertions.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
mkdir -p build/host-tblgen
cmake -S llvm-project/llvm -B build/host-tblgen -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DLLVM_ENABLE_PROJECTS="clang" \
    -DLLVM_TARGETS_TO_BUILD="WebAssembly" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF
"$NINJA" -C build/host-tblgen llvm-tblgen clang-tblgen
ls -la build/host-tblgen/bin/
