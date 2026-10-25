# CMake toolchain file: build HOST tools for wasm32-wasip1 with the swift.org
# 6.3.2 clang (which has the wasm backend) against the SwiftWasm SDK's WASI
# sysroot. Set ISO_WASM_SDK (the artifactbundle's wasm32-unknown-wasip1 dir)
# and ISO_BASE_TC (the swift.org toolchain's usr/bin) in the environment.
set(CMAKE_SYSTEM_NAME WASI)
set(CMAKE_SYSTEM_VERSION 1)
set(CMAKE_SYSTEM_PROCESSOR wasm32)
set(_sdk "$ENV{ISO_WASM_SDK}")
set(_tc "$ENV{ISO_BASE_TC}")
set(CMAKE_C_COMPILER "${_tc}/clang")
set(CMAKE_CXX_COMPILER "${_tc}/clang++")
set(CMAKE_ASM_COMPILER "${_tc}/clang")
set(CMAKE_ASM_COMPILER_TARGET wasm32-unknown-wasip1)
set(CMAKE_AR "${_tc}/llvm-ar")
set(CMAKE_RANLIB "${_tc}/llvm-ranlib")
set(CMAKE_C_COMPILER_TARGET wasm32-unknown-wasip1)
set(CMAKE_CXX_COMPILER_TARGET wasm32-unknown-wasip1)
set(CMAKE_SYSROOT "${_sdk}/WASI.sdk")
set(_resource "${_sdk}/swift.xctoolchain/usr/lib/swift_static/clang")
set(_emul "-D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_PROCESS_CLOCKS -D_WASI_EMULATED_GETPID")
set(CMAKE_C_FLAGS_INIT "-resource-dir ${_resource} ${_emul}")
# shims/: a libc++ __config_site with the threading API ON (over wasi-libc's
# single-threaded pthread stubs) plus POSIX declarations wasi-libc hides; see README.
set(CMAKE_CXX_FLAGS_INIT "-resource-dir ${_resource} ${_emul} -fno-exceptions -fno-rtti -isystem ${CMAKE_CURRENT_LIST_DIR}/shims")
# ISO_WASI_LINK_EXTRA: the stubs object + libc++'s threading archive
# (build/wasi-stubs, build/wasi-cxxthreads — built by build_phase_1_wasi_llvm.sh).
set(CMAKE_EXE_LINKER_FLAGS_INIT "-resource-dir ${_resource} -lwasi-emulated-signal -lwasi-emulated-mman -lwasi-emulated-process-clocks -lwasi-emulated-getpid -Wl,-z,stack-size=8388608 -Wl,--max-memory=4294967296 $ENV{ISO_WASI_LINK_EXTRA}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
# wasm has no shared libraries.
set(CMAKE_EXECUTABLE_SUFFIX ".wasm")
set(BUILD_SHARED_LIBS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE OFF)
