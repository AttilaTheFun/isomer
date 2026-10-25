#!/bin/bash
# Phase B for Android: LLVM + clang + lld cross-compiled for Android arm64 as
# STATIC LIBRARIES with the NDK (the iOS phase B's Android twin; only the
# WebAssembly backend, no tools — the Playground app links the libraries and
# calls the entry points in-process). The NDK is the one Bazel fetched for the
# Android builds (hermetic_android_toolchains), unless ISO_NDK says otherwise.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
NDK="${ISO_NDK:-$(ls -d ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin 2>/dev/null | head -1)}"
[ -d "$NDK/build/cmake" ] || { echo "no NDK at $NDK (set ISO_NDK)" >&2; exit 1; }
API="${ISO_ANDROID_API:-28}"
SUFFIX="android"
mkdir -p build/$SUFFIX-llvm
cmake -S llvm-project/llvm -B build/$SUFFIX-llvm -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-$API \
    -DANDROID_STL=c++_static \
    -DLLVM_HOST_TRIPLE="aarch64-linux-android$API" \
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
    -DLLVM_ENABLE_PIC=ON \
    -DCLANG_TOOL_C_INDEX_TEST_BUILD=OFF \
    -DCLANG_ENABLE_ARCMT=OFF \
    -DCLANG_ENABLE_STATIC_ANALYZER=OFF
"$NINJA" -C build/$SUFFIX-llvm -k 0 || true
"$NINJA" -C build/$SUFFIX-llvm lldWasm clangFrontend clangCodeGen
echo "PHASE B OK"
ls build/$SUFFIX-llvm/lib/*.a | head -5
