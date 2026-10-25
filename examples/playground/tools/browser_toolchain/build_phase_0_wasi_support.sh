#!/bin/bash
# Phase 0: the two link-time pieces every wasm-hosted tool needs.
#  - build/wasi-stubs/wasi_stubs.o: process/dl/rlimit/uuid symbols wasi-libc
#    lacks (stubs/wasi_stubs.c), linked as an object into every executable.
#  - build/wasi-cxxthreads/libiso_cxxthreads.a: libc++'s own threading sources
#    (mutex, condition_variable, shared_mutex, future, thread, call_once)
#    compiled with the threading API ON over wasi-libc's single-threaded
#    pthread stubs, matching shims/__config_site (the SDK's libc++.a was built
#    with _LIBCPP_HAS_THREADS=0 and omits these out-of-line members).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
cd "$ISO_WORKSPACE"
CC="$ISO_BASE_TC/clang"
CXX="$ISO_BASE_TC/clang++"
COMMON=(--target=wasm32-unknown-wasip1 --sysroot="$ISO_WASM_SDK/WASI.sdk"
        -resource-dir "$ISO_WASM_SDK/swift.xctoolchain/usr/lib/swift_static/clang"
        -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID
        -isystem "$HERE/shims" -O2)
mkdir -p build/wasi-stubs build/wasi-cxxthreads
"$CC" "${COMMON[@]}" -c "$HERE/stubs/wasi_stubs.c" -o build/wasi-stubs/wasi_stubs.o
rm -f build/wasi-stubs/libwasistubs.a
"$ISO_BASE_TC/llvm-ar" rcs build/wasi-stubs/libwasistubs.a build/wasi-stubs/wasi_stubs.o
L="$ISO_WORKSPACE/llvm-project/libcxx"
for f in mutex condition_variable condition_variable_destructor mutex_destructor shared_mutex future thread call_once; do
    "$CXX" "${COMMON[@]}" -fno-exceptions -fno-rtti -std=c++23 -D_LIBCPP_BUILDING_LIBRARY -DLIBCXX_BUILDING_LIBCXXABI \
        -I "$L/src" -c "$L/src/$f.cpp" -o "build/wasi-cxxthreads/$f.o"
done
rm -f build/wasi-cxxthreads/libiso_cxxthreads.a
"$ISO_BASE_TC/llvm-ar" rcs build/wasi-cxxthreads/libiso_cxxthreads.a build/wasi-cxxthreads/*.o
echo "PHASE 0 OK"
