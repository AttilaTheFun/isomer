#!/bin/bash
# Phase C2: swift-frontend for iOS arm64 — host tools only, cross-compiled
# against the Phase B iOS LLVM/clang build. The compiler's own Swift sources
# (ASTGen etc.) compile with the 6.3.2-RELEASE base toolchain targeting iOS
# (BOOTSTRAPPING_MODE=CROSSCOMPILE). No stdlib, no overlays — the wasm
# stdlib the DEVICE app targets ships as data (the SwiftWasm artifactbundle).
set -euo pipefail
cd "$(dirname "$0")"
NINJA=~/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
PLATFORM="${ISO_PLATFORM:-iphoneos}"
SDK="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
if [ "$PLATFORM" = "iphonesimulator" ]; then
    SUFFIX="ios-sim"
    TRIPLE="arm64-apple-ios16.0-simulator"
    HOST_VARIANT="iphonesimulator"
    HOST_VARIANT_SDK="IOS_SIMULATOR"
else
    SUFFIX="ios"
    TRIPLE="arm64-apple-ios16.0"
    HOST_VARIANT="iphoneos"
    HOST_VARIANT_SDK="IOS"
fi
BASE_TC=~/Developer/swiftwasm-source/build/Packaging/base-toolchain/swift-6.3.2-RELEASE/usr/bin
mkdir -p build/$SUFFIX-swift
cmake -S swift -B build/$SUFFIX-swift -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_Swift_COMPILER="$(xcrun -f swiftc)" \
    -DCMAKE_Swift_FLAGS="-target $TRIPLE" \
    -DUUID_INCLUDE_DIR="$SDK/usr/include" \
    -DUUID_LIBRARY="$SDK/usr/lib/libSystem.tbd" \
    -DLLVM_DIR="$PWD/build/$SUFFIX-llvm/lib/cmake/llvm" \
    -DClang_DIR="$PWD/build/$SUFFIX-llvm/lib/cmake/clang" \
    -DSWIFT_NATIVE_LLVM_TOOLS_PATH="$PWD/build/host-tblgen/bin" \
    -DLLVM_TABLEGEN="$PWD/build/host-tblgen/bin/llvm-tblgen" \
    -DSWIFT_NATIVE_CLANG_TOOLS_PATH="$BASE_TC" \
    -DSWIFT_NATIVE_SWIFT_TOOLS_PATH="$PWD/native-tools" \
    -DSWIFT_HOST_VARIANT="$HOST_VARIANT" \
    -DSWIFT_HOST_VARIANT_SDK="$HOST_VARIANT_SDK" \
    -DSWIFT_HOST_VARIANT_ARCH=arm64 \
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
    -DSWIFT_PATH_TO_CMARK_BUILD="$PWD/build/$SUFFIX-cmark" \
    -DSWIFT_PATH_TO_SWIFT_SYNTAX_SOURCE="$PWD/swift-syntax" \
    -DBOOTSTRAPPING_MODE=CROSSCOMPILE-WITH-HOSTLIBS \
    -DSWIFT_EXEC_FOR_SWIFT_MODULES="$PWD/xcode-shim/bin/swiftc" \
    -DSWIFT_ENABLE_DISPATCH=OFF \
    -DSWIFT_USE_LINKER=""
"$NINJA" -C build/$SUFFIX-swift swift-frontend
echo "PHASE C2 OK"
