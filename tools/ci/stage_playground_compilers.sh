#!/bin/bash
# The Playground's compilers that Bazel doesn't make, staged from OS
# Server's files (by SHA-256, as the Apple SDK archive is: `oss files add`
# on its Mac, then the SHA-256 changed here) into the checkout's gitignored
# folders, where the apps' BUILD files find them
# (examples/playground/AGENTS.md, "The staged compilers"):
#
#   ios-simulator  apple/playground_ios_application/embedded_toolchain/
#                  {iphonesimulator,data}: the compiler linked into the
#                  simulator's app (--define iso_playground_embedded=1)
#   ios-device     apple/playground_ios_application/embedded_toolchain/
#                  {iphoneos,data}: the same for the iPhone and iPad (the
#                  device build); data is the same as the simulator's, so
#                  either may be staged after the other
#   macos          apple/playground_macos_application/staged_toolchain/:
#                  the Mac's compiler (a playground_toolchain/ tree a Mac's
#                  Bazel assembled, arm64), which its Resources take instead
#                  of the building machine's (shared/compiler/toolchain.bzl),
#                  as a Mac app built on Linux must
#   android        android/playground_android_application/toolchain/: the
#                  compiler the APK carries
#   web            web/playground_web_application/staged_toolchain/: the
#                  browser's compiler, as stage_bundle.sh writes it
#                  (manifest.json, bundle.bin.gz, the gzipped binaries), which
#                  package_site.sh --toolchain-from takes; its compiler,
#                  linker and macro plugins are reused, the rest staged fresh
#
#   tools/ci/stage_playground_compilers.sh <name>…
#
# The proof stages the simulator's, Android's, the Mac's and the browser's
# (tools/ci/proof.sh); the
# publishing jobs the device's, the Mac's and Android's. A folder already
# staged from the same archive is kept; one staged by hand (a checkout of an
# agent's: no .sha256 in it, nor, for the iPhone's, in either platform's
# folder) is kept as it is. Needs `oss` on the PATH, a client of the server
# that has the files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_SIMULATOR_TOOLCHAIN=1eb52eb470019b2ac3066a93955e562afe19d295e4b30585c73cd5892c048c4d
IOS_DEVICE_TOOLCHAIN=d864eaa5b9f259305bf19adc6a3584093c847df896624bb09bb7a9a1d84c1157
MACOS_TOOLCHAIN=7141924e3dfcfbacf63751f2327f256a2d35050e13979665c8612f297629a54a
ANDROID_TOOLCHAIN=c8feabf8c6f379f4da714b9d1ed7915bfdc2cf9d02c90465bafb05278581f8b4
WEB_TOOLCHAIN=70d0bc49c7cb2cbb9b8aa93370a6154b0343ab84d02bdfbc38e8e2292c3e8b38
playground="$ROOT/examples/playground"

[ $# -gt 0 ] || { echo "usage: tools/ci/stage_playground_compilers.sh ios-simulator|ios-device|macos|android|web…" >&2; exit 2; }
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/playground-compilers.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# An archive from OS Server's files, unpacked into <into>, which it makes
# <folder>. <hand> (default <folder>) with no .sha256 in it or its folders
# was staged by hand, and is kept.
stage() {
    local sha="$1" folder="$2" into="$3" hand="${4:-$2}"
    if [ "$(cat "$folder/.sha256" 2> /dev/null)" = "$sha" ]; then return 0; fi
    if [ -d "$hand" ] && [ -z "$(find "$hand" -maxdepth 2 -name .sha256 -print -quit)" ]; then return 0; fi
    rm -rf "$folder"
    oss storage get "$sha" "$work/$sha.tar.gz" > /dev/null
    [ "$(shasum -a 256 "$work/$sha.tar.gz" | cut -d' ' -f1)" = "$sha" ] || { echo "::error::$sha's bytes don't match it"; exit 1; }
    tar -xzf "$work/$sha.tar.gz" -C "$into"
    rm "$work/$sha.tar.gz"
    echo "$sha" > "$folder/.sha256"
}

ios="$playground/apple/playground_ios_application"
for name in "$@"; do
    case "$name" in
        # One embedded_toolchain/, a folder a platform: each platform's
        # archive replaces its own folder (and writes data, the same in both).
        ios-simulator)
            stage "$IOS_SIMULATOR_TOOLCHAIN" "$ios/embedded_toolchain/iphonesimulator" "$ios" "$ios/embedded_toolchain" ;;
        ios-device)
            stage "$IOS_DEVICE_TOOLCHAIN" "$ios/embedded_toolchain/iphoneos" "$ios" "$ios/embedded_toolchain" ;;
        macos)
            stage "$MACOS_TOOLCHAIN" "$playground/apple/playground_macos_application/staged_toolchain" \
                "$playground/apple/playground_macos_application" ;;
        android)
            stage "$ANDROID_TOOLCHAIN" "$playground/android/playground_android_application/toolchain" \
                "$playground/android/playground_android_application" ;;
        web)
            stage "$WEB_TOOLCHAIN" "$playground/web/playground_web_application/staged_toolchain" \
                "$playground/web/playground_web_application" ;;
        *) echo "stage_playground_compilers: no compiler named $name (ios-simulator, ios-device, macos, android, web)" >&2; exit 2 ;;
    esac
    echo "stage_playground_compilers: $name staged"
done
