#!/bin/bash
# Phase C2 for Android: swift-frontend for Android arm64 — host tools only,
# cross-compiled against the Phase B Android LLVM/clang build with the NDK.
# The compiler's own Swift sources compile with the 6.3.2-RELEASE base
# toolchain targeting Android (BOOTSTRAPPING_MODE=CROSSCOMPILE-WITH-HOSTLIBS:
# the Android Swift SDK bundle's runtime is the host runtime, the same
# libswiftCore.so the app ships). No stdlib, no overlays — the wasm stdlib the
# device app targets ships as data.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
NDK="${ISO_NDK:-$(ls -d ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin 2>/dev/null | head -1)}"
API="${ISO_ANDROID_API:-28}"
TRIPLE="aarch64-unknown-linux-android$API"
BASE_TC=~/Developer/swiftwasm-source/build/Packaging/base-toolchain/swift-6.3.2-RELEASE/usr/bin
# The Android Swift SDK bundle Bazel fetched (rules_swift's swift extension).
ANDROID_SDK="${ISO_ANDROID_SWIFT_SDK:-$(ls -d ~/Library/Caches/bazel/_bazel_*/*/external/rules_swift++swift+swift_toolchain_android_sdk_xcode/swift-6.3.2-RELEASE_android.artifactbundle 2>/dev/null | head -1)}"
SWIFT_RESOURCES="$ANDROID_SDK/swift-android/swift-resources/usr/lib/swift-aarch64"
[ -d "$SWIFT_RESOURCES/android" ] || { echo "no Android Swift SDK at $ANDROID_SDK" >&2; exit 1; }
PREBUILT="$NDK/toolchains/llvm/prebuilt/darwin-x86_64"
# The sysroot swiftc links against: the NDK's, plus Swift's runtime objects
# where the driver looks for them (what the SDK bundle's setup-android-sdk.sh
# assembles as ndk-sysroot; Bazel's copy of the bundle has none, and stays
# untouched).
SYSROOT="$PWD/android-sysroot"
if [ ! -d "$SYSROOT" ]; then
    mkdir -p "$SYSROOT/usr/lib"
    ln -s "$PREBUILT/sysroot/usr/include" "$SYSROOT/usr/include"
    for triple in "$PREBUILT"/sysroot/usr/lib/*; do ln -s "$triple" "$SYSROOT/usr/lib/$(basename "$triple")"; done
    for folder in swift swift_static; do
        for rt in "$ANDROID_SDK"/swift-android/swift-resources/usr/lib/${folder}-*/android/*/swiftrt.o; do
            arch="$(basename "$(dirname "$rt")")"
            mkdir -p "$SYSROOT/usr/lib/$folder/android/$arch"
            ln -s "$rt" "$SYSROOT/usr/lib/$folder/android/$arch/swiftrt.o"
        done
    done
fi
# The Swift resource dir for the Android host: the bundle's swift-aarch64
# entries, with the `clang` builtin-header link the bundle lacks on a Mac
# (its own points at a Linux NDK) — the clang importer finds <stddef.h>
# through it.
RESOURCES="$PWD/android-swift-resources"
if [ ! -d "$RESOURCES" ]; then
    mkdir -p "$RESOURCES"
    for entry in "$SWIFT_RESOURCES"/*; do ln -s "$entry" "$RESOURCES/$(basename "$entry")"; done
    rm -f "$RESOURCES/clang"
    ln -s "$(ls -d "$PREBUILT"/lib/clang/* | head -1)" "$RESOURCES/clang"
fi
# SwiftCompilerSources includes "swift/shims/*.h" through
# <swiftc's bin>/../lib: the shim's lib/swift is the resource dir.
mkdir -p android-shim/lib
[ -e android-shim/lib/swift ] || ln -s "$RESOURCES" android-shim/lib/swift
# Android has no libuuid: swift/lib/Basic wants uuid_generate_random and
# five friends, which android-uuid/ (uuid.c, built with the NDK) supplies.
if [ ! -f android-uuid/lib/libuuid.a ]; then
    mkdir -p android-uuid/lib
    "$PREBUILT/bin/aarch64-linux-android$API-clang" -O2 -fPIC -Iandroid-uuid/include -c android-uuid/uuid.c -o android-uuid/uuid.o
    "$PREBUILT/bin/llvm-ar" rcs android-uuid/lib/libuuid.a android-uuid/uuid.o
fi
mkdir -p build/android-swift
cmake -S swift -B build/android-swift -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-$API \
    -DANDROID_STL=c++_static \
    -DCMAKE_EXE_LINKER_FLAGS="-L$PWD/android-swift-resources/android $PWD/android-voidify/voidify.o" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$PWD/android-swift-resources/android" \
    -DCMAKE_Swift_COMPILER="$PWD/android-shim/bin/swiftc" \
    -DCMAKE_Swift_COMPILER_TARGET="$TRIPLE" \
    -DCMAKE_Swift_FLAGS="-target $TRIPLE" \
    -DLLVM_DIR="$PWD/build/android-llvm/lib/cmake/llvm" \
    -DClang_DIR="$PWD/build/android-llvm/lib/cmake/clang" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$PWD/build/host-tblgen/bin" \
    -DLLVM_TABLEGEN="$PWD/build/host-tblgen/bin/llvm-tblgen" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$BASE_TC" \
    -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$PWD/native-tools" \
    -DSWIFT_HOST_VARIANT=android \
    -DSWIFT_HOST_VARIANT_SDK=ANDROID \
    -DSWIFT_HOST_VARIANT_ARCH=aarch64 \
    -DUUID_INCLUDE_DIR="$PWD/android-uuid/include" \
    -DUUID_LIBRARY="$PWD/android-uuid/lib/libuuid.a" \
    -DSWIFT_ANDROID_NDK_PATH="$NDK" \
    -DSWIFT_ANDROID_API_LEVEL="$API" \
    -DSWIFT_INCLUDE_TESTS=OFF \
    -DSWIFT_INCLUDE_DOCS=OFF \
    -DSWIFT_BUILD_STDLIB=OFF \
    -DSWIFT_BUILD_DYNAMIC_STDLIB=OFF \
    -DSWIFT_BUILD_STATIC_STDLIB=OFF \
    -DSWIFT_BUILD_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_DYNAMIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_STATIC_SDK_OVERLAY=OFF \
    -DSWIFT_BUILD_REMOTE_MIRROR=OFF \
    -DSWIFT_BUILD_SOURCEKIT=OFF \
    -DSWIFT_ENABLE_SOURCEKIT_TESTS=OFF \
    -DSWIFT_PATH_TO_CMARK_SOURCE="$PWD/cmark" \
    -DSWIFT_PATH_TO_CMARK_BUILD="$PWD/build/android-cmark" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$PWD/swift-syntax" \
    -DSWIFT_BUILD_SWIFT_SYNTAX=TRUE \
    -DSWIFT_PATH_TO_STRING_PROCESSING_SOURCE="$PWD/swift-experimental-string-processing" \
    -DBOOTSTRAPPING_MODE=CROSSCOMPILE-WITH-HOSTLIBS \
    -DSWIFT_EXEC_FOR_SWIFT_MODULES="$PWD/android-shim/bin/swiftc" \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_USE_LINKER=lld
# The link expects the host stdlib's swiftrt.o in the build tree (a
# with-hostlibs build has no stdlib of its own): the SDK bundle's.
mkdir -p build/android-swift/lib/swift/android/aarch64
cp "$SWIFT_RESOURCES/android/aarch64/swiftrt.o" build/android-swift/lib/swift/android/aarch64/
# libc++'s std::__voidify instantiations the Swift-written modules reference
# (android-voidify/voidify.cpp), linked into swift-frontend. With exceptions
# on: the references carry libc++'s `ne` ABI tag, -fno-exceptions gives `nn`.
"$PREBUILT/bin/aarch64-linux-android$API-clang++" -std=c++17 -O2 -fPIC -fno-rtti \
    -Iswift/include -Ibuild/android-swift/include -Illvm-project/llvm/include -Ibuild/android-llvm/include \
    -Illvm-project/clang/include -Ibuild/android-llvm/tools/clang/include \
    -c android-voidify/voidify.cpp -o android-voidify/voidify.o
"$NINJA" -C build/android-swift swift-frontend
echo "PHASE C2 OK"
