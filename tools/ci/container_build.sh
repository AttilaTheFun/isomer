#!/bin/bash
# CI's build of every platform in a Linux container, on a self-hosted
# runner's Mac: a container leased from that Mac's OS Server (`oss machine
# run container --inside`), in the image a Visor session runs in, so CI
# builds where an agent works. The Apple targets take Xcode 27.0's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository.
#
#   tools/ci/container_build.sh [<bazel build args>…]   # default: every platform's Storybook
#   tools/ci/container_build.sh package <dir> <bazel build args>…
#                                     # the build, then the targets' packages
#                                     # (.ipa, a Mac app's .zip, the signed
#                                     # .apk) copied to <dir>, in this checkout,
#                                     # for CI to publish
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   ISOMER_CI_IMAGE  the image (default: Visor's agent image, tools/ci/agent_image)
#   ISOMER_CI_VOLUME Bazel's tree, kept between builds (default: isomer-ci;
#                    `:keep`, so OS Server keeps it when the lease ends)
#
# With no arguments (CI's run) the tests run after the build, in the same
# container: the core's (the mock renderer's and the snapshots', isomer's own
# module), the GL backend's on Mesa's EGL, and each platform's Storybook that
# runs here (//tests/platforms in the examples: the web in headless Chrome,
# Linux under Xvfb), their output in the log; and the apps tested elsewhere
# are put in .ci/platforms for tools/ci/platform_tests.sh: the iPhone's and
# the Mac's (slots of OS Server's primary macOS VM), Android's (a phone in a
# container) and Windows' (built here for Windows on Arm,
# --config=windows_on_linux, and run under Wine in a container). Any build or
# test failing fails the run.
#
# package (the publishing jobs', as AttilaTheFun/reviews' container_build.sh
# has it): Bazel's tree is the container's (a volume), so what CI publishes
# is copied out into the checkout, the one folder of the Mac's the
# container sees, found by cquery with the build's own flags, from the
# execution root. Flags as --name=value (--compilation_mode=opt, not -c
# opt): every argument that doesn't start with "-" is taken for a target.
# An Android app's files are its signed .apk (published as signed by its
# build: Applications Server keeps no Android key), its unsigned one and its
# deploy jar; only the first is copied.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${ISOMER_CI_IMAGE:-$(cat "$ROOT/tools/ci/agent_image")}"
VOLUME="${ISOMER_CI_VOLUME:-isomer-ci}"
SDK_SHA256="251c252f7f41bcd3e08655e49e182686682d705945f4a2807049b9051c606ebb"

# `--inside` came in OS Server 0.12.0. An older oss takes it for an option it
# doesn't know and runs the build on this Mac instead: refused here. (The
# command line is inside the app: its version is the app's.)
oss_app="$(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("oss")))' | sed 's|/Contents/Helpers/oss$||')"
oss_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$oss_app/Contents/Info.plist" 2>/dev/null || echo 0)"
if ! python3 -c 'import sys; v = [int(x) for x in sys.argv[1].split(".")[:3]] + [0, 0]; sys.exit(0 if v[:3] >= [0, 12, 0] else 1)' "$oss_version"; then
    echo "container_build.sh: needs OS Server 0.12.0 or later on this Mac (oss machine run --inside); it has $oss_version" >&2
    exit 1
fi

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    host="$("$tailscale" status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi

# The placeholders in MODULE.bazel, to this Mac's OS Server.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
rewrite windows-sdks\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

mode=build
out=""
if [ "${1:-}" = package ]; then
    [ $# -ge 3 ] || { echo "usage: tools/ci/container_build.sh package <dir> <bazel build args…>" >&2; exit 1; }
    mkdir -p "$2"
    out="$(cd "$2" && pwd)"
    case "$out/" in
        "$ROOT"/*) ;;
        *) echo "container_build.sh: package's folder must be in this checkout ($ROOT)" >&2; exit 1 ;;
    esac
    rm -f "$out"/*
    chmod 775 "$out"
    mode=package
    shift 2
elif [ $# -eq 0 ]; then
    mode=checks
    set -- --ios_multi_cpus=sim_arm64 \
        //apple/storybook_ios_application:storybook_ios_sim_application \
        //apple/storybook_macos_application:storybook_macos_application \
        //web/storybook_web_application:storybook_web_application \
        //android/storybook_android_application:storybook_android_application \
        //android/storybook_android_application:storybook_android_application_apk \
        //linux/storybook_linux_application:storybook_linux_application
fi

# In the container: the build in the examples' module, then (CI's run) the
# checks in isomer's, or (package) the packages copied out, each Bazel
# reading the cache (--cache writes the container's ~/.bazelrc).
steps='
root=$1 mode=$2 out=$3; shift 3
cd "$root/examples"
flags=(--config=apple_on_linux "--downloader_config=$root/.ci/downloader.cfg")
bazel build --keep_going "${flags[@]}" "$@"
built=$?
if [ "$mode" = package ]; then
    [ $built -eq 0 ] || exit $built
    options=()
    query=""
    # cquery takes one expression: the targets as a union of them.
    for argument in "$@"; do
        case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac
    done
    exec_root="$(bazel info "${flags[@]}" "${options[@]}" execution_root)" || exit
    files="$(bazel cquery "${flags[@]}" "${options[@]}" "$query" --output=files 2> /dev/null)" || exit
    for file in $files; do
        case "$file" in
            *_unsigned.apk) ;;
            *.ipa | *.zip | *.apk) cp "$exec_root/$file" "$out/" || exit ;;
        esac
    done
    ls -l "$out"
    exit 0
fi
[ "$mode" = checks ] || exit $built
start=$SECONDS
# What the tests here need beyond the image: Xvfb, Mesa'"'"'s drivers, and the
# libraries Chrome for Testing loads.
if ! command -v Xvfb >/dev/null || [ ! -e /usr/lib/aarch64-linux-gnu/libnss3.so ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends xvfb libnss3 \
        libgl1-mesa-dri libegl-mesa0 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxrandr2 libpango-1.0-0 libcairo2 libcups2t64 libdrm2 fonts-dejavu-core >/dev/null ||
        { apt-get update -qq >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
            --no-install-recommends xvfb libnss3 libgl1-mesa-dri libegl-mesa0 libasound2t64 \
            libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 \
            libcups2t64 libdrm2 fonts-dejavu-core >/dev/null; }
fi
# Windows on Arm, built here.
windows=(--config=windows_on_linux --platforms=@isomer//tools/platforms:windows_arm64)
bazel build "${flags[@]}" "${windows[@]}" //windows/storybook_windows_application
built_windows=$?
bazel test "${flags[@]}" --test_output=errors //tests/platforms:all //tests/foundation_networking:networking_test
tested_here=$?
cd "$root"
bazel test --test_output=errors //tests/renderer:mock_renderer_test //tests/snapshot:snapshot_test \
    //swift_gpu/linux:gl_backend_test
checked=$?
echo "container_build.sh: the tests took $((SECONDS - start)) s"

# The apps tested elsewhere, for tools/ci/platform_tests.sh.
cd "$root/examples"
platforms="$root/.ci/platforms"
rm -rf "$platforms" && mkdir -p "$platforms/windows" && chmod -R 777 "$platforms"
exec_root="$(bazel info "${flags[@]}" execution_root)"
files() { bazel cquery "${flags[@]}" "$@" --output=files 2> /dev/null; }
for f in $(files --ios_multi_cpus=sim_arm64 //apple/storybook_ios_application:storybook_ios_sim_application) \
         $(files //apple/storybook_macos_application) $(files //android/storybook_android_application:storybook_android_application_apk); do
    case "$f" in *_unsigned.apk) ;; *.ipa | *.zip | *.apk) cp "$exec_root/$f" "$platforms/" ;; esac
done
for f in $(files "${windows[@]}" //windows/storybook_windows_application); do
    case "$f" in *.exe) cp "$exec_root/$f" "$platforms/windows/" ;; esac
done
cp "$(bazel info "${flags[@]}" output_base)"/external/+swift_windows_sdk_repository+swift_windows_sdk/swift-windows-sdk/runtime/aarch64/*.dll \
    "$platforms/windows/" 2>/dev/null
cp -R "$root/examples/storybook/assets" "$platforms/windows/assets"
chmod -R a+rwX "$platforms"
ls -l "$platforms"
for result in $built $built_windows $tested_here $checked; do [ "$result" -ne 0 ] && exit "$result"; done
exit 0
'

cd "$ROOT/examples"
exec oss machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$@"
