#!/bin/bash
# Phase C1 for Android: libcmark-gfm for Android arm64 (a small swift-frontend
# dependency), with the NDK Bazel fetched.
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
NDK="${ISO_NDK:-$(ls -d ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin 2>/dev/null | head -1)}"
API="${ISO_ANDROID_API:-28}"
mkdir -p build/android-cmark
cmake -S cmark -B build/android-cmark -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=android-$API \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMARK_TESTS=OFF
"$NINJA" -C build/android-cmark libcmark-gfm.a libcmark-gfm-extensions.a || \
    "$NINJA" -C build/android-cmark
echo "PHASE C1 OK"
find build/android-cmark -name "*.a" | head -4
