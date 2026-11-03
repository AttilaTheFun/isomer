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
#
#   tools/ci/stage_playground_compilers.sh <name>…
#
# The proof stages the simulator's and Android's (tools/ci/proof.sh); the
# publishing jobs the device's, the Mac's and Android's. A folder already
# staged from the same archive is kept; one staged by hand (a checkout of an
# agent's: no .sha256 in it, nor, for the iPhone's, in either platform's
# folder) is kept as it is. Needs `oss` on the PATH, a client of the server
# that has the files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IOS_SIMULATOR_TOOLCHAIN=4e23b747153a2f3b75fa91a0f9ca14bcd5a58d68af71c8d9be14ceea47386f05
IOS_DEVICE_TOOLCHAIN=dc86db6749b40e97b5bd2f249a446edda2f38d2052ad6bdb897b9fe127a1ef72
MACOS_TOOLCHAIN=64fcf4e249214e8249ba0e6651caed6f711f93872e9e3189c464cd2320b13cc1
ANDROID_TOOLCHAIN=0b52a5d3322042317f661ab762cf3b123af5e2ce52cf192c95de31e9779f52c8
playground="$ROOT/examples/playground"

[ $# -gt 0 ] || { echo "usage: tools/ci/stage_playground_compilers.sh ios-simulator|ios-device|macos|android…" >&2; exit 2; }
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
        *) echo "stage_playground_compilers: no compiler named $name (ios-simulator, ios-device, macos, android)" >&2; exit 2 ;;
    esac
    echo "stage_playground_compilers: $name staged"
done
