#!/bin/bash
# Phase B of the on-device Playground compiler: LLVM + clang + lld
# cross-compiled for iOS arm64 as STATIC LIBRARIES (the a-Shell
# architecture, modernized). Only the WebAssembly backend — the device
# compiles wasm32, never arm64. Tools are skipped; the app links the
# libraries and calls the entry points in-process.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
PLATFORM="${ISO_PLATFORM:-iphoneos}"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
if [ "$PLATFORM" = "iphonesimulator" ]; then
    SUFFIX="ios-sim"
    TRIPLE="arm64-apple-ios16.0-simulator"
else
    SUFFIX="ios"
    TRIPLE="arm64-apple-ios16.0"
fi
mkdir -p build/$SUFFIX-llvm
cmake -S llvm-project/llvm -B build/$SUFFIX-llvm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DLLVM_HOST_TRIPLE="$TRIPLE" \
    -DLLVM_DEFAULT_TARGET_TRIPLE=wasm32-unknown-wasip1 \
    -DLLVM_TARGETS_TO_BUILD=WebAssembly \
    -DLLVM_ENABLE_PROJECTS="clang;lld" \
    -DLLVM_TABLEGEN="$PWD/build/host-tblgen/bin/llvm-tblgen" \
    -DCLANG_TABLEGEN="$PWD/build/host-tblgen/bin/clang-tblgen" \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF \
    -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_INCLUDE_UTILS=OFF \
    -DLLVM_BUILD_TOOLS=OFF \
    -DCLANG_BUILD_TOOLS=ON \
    -DLLVM_ENABLE_ZSTD=OFF \
    -DLLVM_ENABLE_LIBXML2=OFF \
    -DLLVM_ENABLE_ZLIB=OFF \
    -DLLVM_ENABLE_TERMINFO=OFF \
    -DLLVM_ENABLE_LIBEDIT=OFF \
    -DLLVM_ENABLE_THREADS=ON \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF
# The library surface swift-frontend + an in-process wasm-ld need.
"$NINJA" -C build/$SUFFIX-llvm -k 0 || true
"$NINJA" -C build/$SUFFIX-llvm lldWasm clangFrontend clangCodeGen
echo "PHASE B OK"
ls build/$SUFFIX-llvm/lib/*.a | head -5
