#!/bin/bash
# Phase 2: swift-frontend, HOST = wasm32-wasip1, against the Phase 1 LLVM/clang
# libraries. The compiler's own Swift sources (SwiftCompilerSources; swift-syntax
# when enabled) are compiled by the swift.org 6.3.2 host swiftc TARGETING wasm
# against the SwiftWasm SDK (BOOTSTRAPPING_MODE=CROSSCOMPILE), and the frontend
# links the SDK's static Swift runtime — the copy INSIDE the compiler, distinct
# from the archives it links user code against (same bits, different role).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
cd "$ISO_WORKSPACE"
# A second build directory keeps a variant beside the default one (the
# macro-capable compiler: ISO_SWIFT_SYNTAX=ON ISO_SWIFT_BUILD=build/wasi-swift-syntax).
BUILD="${ISO_SWIFT_BUILD:-build/wasi-swift}"
SWIFT_STATIC="$ISO_WASM_SDK/swift.xctoolchain/usr/lib/swift_static"
# SWIFTLIB_DIR (build/lib/swift) is where the CMake looks for the host Swift
# runtime + swiftrt.o under <sdk>/<arch>/, and the resource dir the compiler
# sources are compiled against (the CMake prepends it; overriding it with the
# SDK's makes clang see the shims module maps twice → "redefinition of module
# 'SwiftShims'"). lib/swift/wasi mirrors the SDK's static stdlib through
# per-entry symlinks (the build writes lib/swift/clang and shims itself, so the
# parents stay real directories), EXCEPT wasi-libc.modulemap: the SDK's
# per-header SwiftWASILibc module cycles with libc++'s std_*_h modules under
# C++ interop, so resource_overlay/ supplies the glibc-shaped single-umbrella
# module (SwiftWASILibc.h).
W=$BUILD/lib/swift/wasi
if [ ! -e "$W/wasm32/SwiftWASILibc.h" ]; then
    rm -rf "$W"; mkdir -p "$W/wasm32"
    for f in "$SWIFT_STATIC"/wasi/*; do n=$(basename "$f"); [ "$n" = wasm32 ] || ln -s "$f" "$W/$n"; done
    for f in "$SWIFT_STATIC"/wasi/wasm32/*; do n=$(basename "$f"); [ "$n" = wasi-libc.modulemap ] || ln -s "$f" "$W/wasm32/$n"; done
    cp "$HERE/resource_overlay/wasm32/wasi-libc.modulemap" "$HERE/resource_overlay/wasm32/SwiftWASILibc.h" "$W/wasm32/"
fi
cmake -S swift -B "$BUILD" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$HERE/wasi-toolchain.cmake" \
    -DUNIX=1 \
    -DCMAKE_Swift_COMPILER="$ISO_BASE_TC/swiftc" \
    -DCMAKE_Swift_FLAGS="-target wasm32-unknown-wasip1 -sdk $ISO_WASM_SDK/WASI.sdk -resource-dir $SWIFT_STATIC -static-stdlib -Xclang-linker -resource-dir -Xclang-linker $SWIFT_STATIC/clang" \
    -DUUID_INCLUDE_DIR="$HERE/shims" \
    -DUUID_LIBRARY="$PWD/build/wasi-stubs/libwasistubs.a" \
    -DSWIFT_HOST_VARIANT=wasi \
    -DSWIFT_HOST_VARIANT_SDK=WASI \
    -DSWIFT_HOST_VARIANT_ARCH=wasm32 \
    -DSWIFT_WASI_SYSROOT_PATH="$ISO_WASM_SDK/WASI.sdk" \
    -DLLVM_DIR="$PWD/build/wasi-llvm/lib/cmake/llvm" \
    -DClang_DIR="$PWD/build/wasi-llvm/lib/cmake/clang" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$PWD/build/host-tblgen/bin" \
    -DLLVM_TABLEGEN="$PWD/build/host-tblgen/bin/llvm-tblgen" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$ISO_BASE_TC" \
    -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$PWD/native-tools" \
    -DSWIFT_INCLUDE_TESTS=OFF \
    -DSWIFT_INCLUDE_DOCS=OFF \
    -DSWIFT_INCLUDE_TOOLS=ON \
    -DSWIFT_BUILD_STDLIB=OFF \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF \
    -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
    -DSWIFT_BUILD_SOURCEKIT=OFF \
    -DSWIFT_ENABLE_SOURCEKIT_TESTS=OFF \
    -DSWIFT_BUILD_SWIFT_SYNTAX="${ISO_SWIFT_SYNTAX:-OFF}" \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$PWD/cmark" \
    -DSWIFT_PATH_TO_CMARK_BUILD="$PWD/build/wasi-cmark" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$PWD/swift-syntax" \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$PWD/swift-experimental-string-processing" \
    -DBOOTSTRAPPING_MODE=CROSSCOMPILE \
    -DSWIFT_EXEC_FOR_SWIFT_MODULES="$ISO_BASE_TC/swiftc" \
    -DSWIFT_COMPILER_SOURCES_SDK_FLAGS="-sdk;$ISO_WASM_SDK/WASI.sdk;-Xcc;-D_WASI_EMULATED_SIGNAL;-Xcc;-D_WASI_EMULATED_MMAN;-Xcc;-D_WASI_EMULATED_PROCESS_CLOCKS;-Xcc;-D_WASI_EMULATED_GETPID;-Xcc;-isystem;-Xcc;$HERE/shims;-Xcc;-fno-exceptions" \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_USE_LINKER="" \
    -DSWIFT_STDLIB_SINGLE_THREADED_CONCURRENCY=TRUE \
    -DSWIFT_THREADING_PACKAGE=none \
    -DCMAKE_EXE_LINKER_FLAGS="-resource-dir $SWIFT_STATIC/clang -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-process-clocks -lwasi-emulated-getpid -Wl,-z,stack-size=8388608 -Wl,--max-memory=4294967296 $ISO_WASI_LINK_EXTRA"
[ -n "${ISO_CONFIGURE_ONLY:-}" ] && { echo "configured only"; exit 0; }
# The compiler sources import SwiftShims from the resource dir; nothing in
# the swift-frontend target orders the shim copy before them.
"$NINJA" -C "$BUILD" -j"$JOBS" copy_shim_headers
"$NINJA" -C "$BUILD" -j"$JOBS" swift-frontend
echo "PHASE 2 OK"; ls -la "$BUILD/bin/"
