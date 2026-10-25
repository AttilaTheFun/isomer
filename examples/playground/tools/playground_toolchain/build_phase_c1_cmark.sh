#!/bin/bash
# Phase C1: libcmark-gfm for iOS arm64 (a small swift-frontend dependency).
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
PLATFORM="${ISO_PLATFORM:-iphoneos}"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
SUFFIX="ios"; [ "$PLATFORM" = "iphonesimulator" ] && SUFFIX="ios-sim"
mkdir -p build/$SUFFIX-cmark
cmake -S cmark -B build/$SUFFIX-cmark -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMARK_TESTS=OFF
"$NINJA" -C build/$SUFFIX-cmark libcmark-gfm.a libcmark-gfm-extensions.a || \
    "$NINJA" -C build/$SUFFIX-cmark
echo "PHASE C1 OK"
find build/$SUFFIX-cmark -name "*.a" | head -4
