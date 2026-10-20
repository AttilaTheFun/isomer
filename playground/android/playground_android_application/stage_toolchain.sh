#!/bin/bash
# Stages the Android Playground's toolchain, gitignored under toolchain/ and
# packaged by the app when present:
#
#   toolchain/native/   swift-frontend and wasm-ld built for Android arm64 by
#                       the ~/Developer/ios-toolchain campaign's Android phases
#                       (tools/playground_toolchain/build_phase_{b,c1,c2}_android_*.sh),
#                       with the compiler's own Swift libraries, the Swift
#                       runtime it needs and the macro plugins with their server — named lib*.so so the APK's native
#                       library directory holds them, where the app may execute them
#   toolchain/toolchain.zip   the SDK the browser Playground ships
#                       (tools/browser_toolchain/stage_bundle.sh: resource dir,
#                       sysroot, the Isomer modules and archives, manifest.json)
#
#   stage_toolchain.sh [--slice <wasip1 slice>]
#
# The slice defaults to one made of the iOS Playground's bundled SDK data.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
TC="${ISO_IOS_TOOLCHAIN:-$HOME/Developer/ios-toolchain}"
NDK="${ISO_NDK:-$(ls -d ~/Library/Caches/bazel/_bazel_*/*/external/hermetic_android_toolchains++android+androidndk_darwin 2>/dev/null | head -1)}"
STRIP="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-strip"
SLICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --slice) SLICE="$2"; shift 2;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[ -x "$TC/build/android-swift/bin/swift-frontend" ] || { echo "run the Android toolchain phases first ($TC/build/android-swift/bin/swift-frontend missing)" >&2; exit 1; }
if [ -z "$SLICE" ]; then
    DATA="$ROOT/apple/playground_ios_application/embedded_toolchain/data"
    SLICE="$(mktemp -d)/slice"
    mkdir -p "$SLICE/swift.xctoolchain/usr/lib"
    ln -s "$DATA/WASI.sdk" "$SLICE/WASI.sdk"
    ln -s "$DATA/swift_static" "$SLICE/swift.xctoolchain/usr/lib/swift_static"
fi
OUT="$HERE/toolchain"
rm -rf "$OUT"; mkdir -p "$OUT/native" "$OUT/tree"

# The compiler and linker, stripped, plus every shared library they load.
"$STRIP" -o "$OUT/native/libswift-frontend.so" "$TC/build/android-swift/bin/swift-frontend"
"$STRIP" -o "$OUT/native/libwasm-ld.so" "$TC/build/android-llvm/bin/lld"
for lib in "$TC"/build/android-swift/lib/swift/host/compiler/*.so; do
    "$STRIP" -o "$OUT/native/$(basename "$lib")" "$lib"
done
# Macros: the in-process plugin server, the swift-syntax libraries it and the
# plugins load (lib/swift/host/*.so, apart from the compiler's own _Compiler
# copies above), and the prebuilt plugins (ObservationMacros, SwiftMacros).
# The frontend is told where they are (PlaygroundServices.kt's macroArguments).
for lib in "$TC"/build/android-swift/lib/swift/host/*.so "$TC"/build/android-swift/lib/swift/host/plugins/*.so; do
    "$STRIP" -o "$OUT/native/$(basename "$lib")" "$lib"
done
for lib in libswiftCore libswift_Concurrency libswift_Builtin_float libswift_math libdispatch libswiftAndroid libBlocksRuntime; do
    cp "$TC/android-swift-resources/android/$lib.so" "$OUT/native/"
done
cp "$NDK/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib/aarch64-linux-android/libc++_shared.so" "$OUT/native/"

# The SDK, the browser bundle's way (without the bundle blob itself).
cd "$ROOT"
bazel build -c opt //apple/playground_ios_application:playground_sdk
SDK="$ROOT/$(bazel cquery -c opt --output=files //apple/playground_ios_application:playground_sdk 2>/dev/null | head -1)"
STAGE="$(mktemp -d)/stage"
"$ROOT/tools/browser_toolchain/stage_bundle.sh" --frontend "$TC/build/browser-work/opt/swift-frontend.opt.wasm" --linker "$TC/build/browser-work/opt/lld.opt.wasm" --slice "$SLICE" --sdk "$SDK" --out "$STAGE"
cp -R "$STAGE/resource-dir" "$STAGE/sysroot" "$STAGE/sdk" "$STAGE/manifest.json" "$OUT/tree/"
(cd "$OUT/tree" && zip -q -r -X ../toolchain.zip .)
rm -rf "$OUT/tree"
du -sh "$OUT/native" "$OUT/toolchain.zip"
echo "staged"
