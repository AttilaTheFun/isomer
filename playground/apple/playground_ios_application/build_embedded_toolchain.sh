#!/bin/bash
# Stages the EMBEDDED Swift toolchain the Playground app links to compile
# ON DEVICE (and, identically, in the simulator): the swift-frontend + lld
# static libraries cross-compiled for iOS by the ~/Developer/ios-toolchain
# campaign (build_phase_a/b/c1/c2 scripts there), plus extern-C entry shims
# and the wasm SDK data (WASI sysroot + static stdlib).
#
#   ISO_IOS_TOOLCHAIN=~/Developer/ios-toolchain \
#   ISO_PLATFORM=iphonesimulator|iphoneos \
#       ./build_embedded_toolchain.sh
#
# Output (gitignored): embedded_toolchain/<platform>/{lib/*.a, obj/*.o}
# and embedded_toolchain/data/{WASI.sdk, swift_static} (shared).
# The app calls `iso_swiftc_main` (-> swift::mainEntry) and
# `iso_wasm_ld_main` (-> lld's main, argv[0] "wasm-ld") in-process — no
# subprocess anywhere, which is what iOS requires.
set -euo pipefail
cd "$(dirname "$0")"

TC="${ISO_IOS_TOOLCHAIN:-$HOME/Developer/ios-toolchain}"
PLATFORM="${ISO_PLATFORM:-iphonesimulator}"
if [ "$PLATFORM" = "iphonesimulator" ]; then
    SUFFIX="ios-sim"
    TRIPLE="arm64-apple-ios16.0-simulator"
else
    SUFFIX="ios"
    TRIPLE="arm64-apple-ios16.0"
fi
SWIFT_BUILD="$TC/build/$SUFFIX-swift"
LLVM_BUILD="$TC/build/$SUFFIX-llvm"
SDKPATH="$(xcrun --sdk "$PLATFORM" --show-sdk-path)"
DEST="embedded_toolchain/$PLATFORM"

[ -d "$SWIFT_BUILD" ] || { echo "run the ios-toolchain campaign first ($SWIFT_BUILD missing)"; exit 1; }

rm -rf "$DEST"
mkdir -p "$DEST/lib" "$DEST/obj"

# Every archive on swift-frontend's own link line (the closed set).
python3 - "$SWIFT_BUILD" "$DEST/lib" <<'PYEOF'
import re, shutil, sys, pathlib
build, dest = sys.argv[1], pathlib.Path(sys.argv[2])
text = open(f"{build}/build.ninja").read()
m = re.search(
    r"build bin/swift-frontend[^\n]*:\s*CXX_EXECUTABLE_LINKER[^\n]*\n((?:  [A-Z_]+ = [^\n]*\n)+)",
    text)
libs = re.search(r"  LINK_LIBRARIES = ([^\n]*)", m.group(0)).group(1)
seen = set()
count = 0
for token in libs.split():
    if not token.endswith(".a"):
        continue
    path = pathlib.Path(token if token.startswith("/") else f"{build}/{token}")
    if not path.exists() or path.name in seen:
        continue
    seen.add(path.name)
    shutil.copy(path, dest / path.name)
    count += 1
print(f"staged {count} archives")
PYEOF

# The lld archives (swift-frontend's closure doesn't include them).
cp "$LLVM_BUILD/lib/liblldCommon.a" "$LLVM_BUILD/lib/liblldWasm.a" "$DEST/lib/"

# MACRO SUPPORT: the syntax-enabled frontend dynamically links the compiler's
# SwiftSyntax dylibs; ship them beside the in-process plugin server and the
# prebuilt macro plugins (libSwiftMacros/libObservationMacros — @TaskLocal,
# @DebugDescription, @Observable, ...). The app links the compiler dylibs
# (-L/-l + rpath into the bundle) and passes the server + plugin paths to the
# frontend; the server dlopens plugin dylibs IN-PROCESS — still no spawning.
mkdir -p "$DEST/host/plugins"
cp "$SWIFT_BUILD"/lib/swift/host/compiler/lib_Compiler*.dylib "$DEST/host/"
cp "$SWIFT_BUILD"/lib/swift/host/libSwiftInProcPluginServer.dylib \
   "$SWIFT_BUILD"/lib/swift/host/libSwift*.dylib "$DEST/host/" 2>/dev/null || true
cp "$SWIFT_BUILD"/lib/swift/host/plugins/*.dylib "$DEST/host/plugins/"
# iOS only loads SIGNED code from Frameworks/: wrap every host dylib as an
# embedded framework (rules_apple imports + signs them).
"$(dirname "$0")/frameworkize_host.sh" "$DEST/host" "$PLATFORM"

# The entry shims: swift::mainEntry + a wasm-only lldMain wrapper.
LLD_SRC="$TC/llvm-project/lld"
cat > "$DEST/obj/iso_entry.cpp" <<'EOF'
// Extern-C entries the Playground app calls in-process.
#include "lld/Common/Driver.h"
#include "llvm/Support/raw_ostream.h"
#include <vector>

LLD_HAS_DRIVER(wasm)

namespace swift {
int mainEntry(int argc_, const char **argv_);
}

extern "C" int iso_swiftc_main(int argc, const char **argv) {
    return swift::mainEntry(argc, argv);
}

extern "C" int iso_wasm_ld_main(int argc, const char **argv) {
    std::vector<const char *> args(argv, argv + argc);
    auto result = lld::lldMain(args, llvm::outs(), llvm::errs(),
                               {{lld::Wasm, &lld::wasm::link}});
    return result.retCode;
}
EOF
xcrun --sdk "$PLATFORM" clang++ -std=c++17 -O2 -fno-rtti -target "$TRIPLE" \
    -I "$LLD_SRC/include" -I "$TC/llvm-project/llvm/include" -I "$LLVM_BUILD/include" \
    -c "$DEST/obj/iso_entry.cpp" -o "$DEST/obj/iso_entry.o"

# The wasm SDK data (shared across platforms): sysroot + static stdlib. The
# app bundles these as resources; paths flow into the frontend argv.
if [ ! -d embedded_toolchain/data/WASI.sdk ]; then
    BUNDLE="$(find "$(cd "$(dirname "$0")/../.." && pwd)" -maxdepth 0 2>/dev/null)"
    WASM_DIR="${ISO_WASM_SDK_DIR:-}"
    if [ -z "$WASM_DIR" ]; then
        OUTPUT_BASE="$(cd ../.. && bazel info output_base)"
        SDK_ROOT="$(find "$OUTPUT_BASE/external/rules_swift++swift+swift_toolchain_wasm_sdk_xcode" \
            -maxdepth 1 -name '*_wasm.artifactbundle' | head -1)"
        WASM_DIR="$(find "$SDK_ROOT" -maxdepth 2 -name 'wasm32-unknown-wasip1' -type d | head -1)"
    fi
    mkdir -p embedded_toolchain/data
    cp -RL "$WASM_DIR/WASI.sdk" embedded_toolchain/data/WASI.sdk
    cp -RL "$WASM_DIR/swift.xctoolchain/usr/lib/swift_static" embedded_toolchain/data/swift_static
fi

echo "staged: $DEST + embedded_toolchain/data"
du -sh "$DEST/lib" embedded_toolchain/data
