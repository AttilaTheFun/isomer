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
#   tools/ci/container_build.sh all   # everything the checks build, built,
#                                     # nothing run or copied: main's populate
#                                     # (the Bazel cache's one writer: OS
#                                     # Server grants that job the write)
#   tools/ci/container_build.sh pr    # the same build, then every test that
#                                     # runs without a GUI: the core's, the
#                                     # web's in headless Chrome, the headless
#                                     # UI tests (examples' //headless and
#                                     # //remote): a pull request's container
#                                     # (the owner, 2026-11-08: headless tests
#                                     # before a merge, builds after one)
#   tools/ci/container_build.sh package <dir> <bazel build args>…
#                                     # the build, then the targets' packages
#                                     # (.ipa, a Mac app's .zip, the signed
#                                     # .apk) copied to <dir>, in this checkout,
#                                     # for CI to publish
#
#   ISOMER_EXECUTION_LOGS  a folder for Bazel's execution logs (compact),
#                    to compare two runs' action keys when the cache misses
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   ISOMER_CI_IMAGE  the image (default: Visor's agent image, tools/ci/agent_image)
#   ISOMER_CI_VOLUME Bazel's tree, kept between builds (default: isomer-ci;
#                    `:keep`, so OS Server keeps it when the lease ends)
#
# With no arguments (CI's run) the tests run after the build, in the same
# container: the core's (the mock renderer's and the snapshots', isomer's own
# module) and the web's Storybook in headless Chrome (//tests/platforms in the
# examples), their output in the log. Linux's Storybook test (under Xvfb) and
# the GL backend's check (on Mesa's EGL) are built, not run, for now
# (2026-11-05: CI runs the tier-1 platforms). The apps tested elsewhere are
# put in .ci/platforms for tools/ci/platform_tests.sh: the iPhone's and the
# Mac's (slots of OS Server's primary macOS VM), Android's (an emulator) and
# Windows' (built here for Windows on Arm, --config=windows_on_linux; run
# under Wine only by hand). With ISOMER_ANDROID_X86_64 set (a public
# repository's CI) the Android test APK is also built for x86_64, in
# .ci/platforms/android-x86_64, for the emulator on GitHub's Ubuntu runner.
# Any build or test failing fails the run.
#
# package (the publishing jobs', as AttilaTheFun/reviews' container_build.sh
# has it): Bazel's tree is the container's (a volume), so what CI publishes
# is copied out into the checkout, the one folder of the Mac's the
# container sees, found by cquery with the build's own flags, from the
# execution root. Flags as --name=value (--compilation_mode=opt, not -c
# opt): every argument that doesn't start with "-" is taken for a target.
# An Android app's files are its signed .apk (published as signed by its
# build: Applications Server keeps no Android key), its unsigned one and its
# deploy jar; only the first is copied. A .tar.gz (the web site) is copied
# as is.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${ISOMER_CI_IMAGE:-$(cat "$ROOT/tools/ci/agent_image")}"
VOLUME="${ISOMER_CI_VOLUME:-isomer-ci}"
SDK_SHA256="251c252f7f41bcd3e08655e49e182686682d705945f4a2807049b9051c606ebb"

# In CI the job's own container builds (the isomer-jit runners: OS Server's
# single-use Linux containers, its cache's read token in ~/.netrc and its
# cache in ~/.bazelrc already), in place. On a Mac (OS Server's own, whose
# folders containers may mount) it leases one, as before.
inside=""
[ "$(uname -s)" = Darwin ] || inside=1

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ] && [ -n "${OSS_SERVERS:-}" ]; then
    # The first of the servers' addresses (a URL, or host:port).
    host="${OSS_SERVERS%%[ ,]*}"
    host="${host#*://}"
    host="${host%%[:/]*}"
fi
if [ -z "$host" ] && [ -z "$inside" ]; then
    tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    host="$("$tailscale" status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi
[ -n "$host" ] || { echo "container_build.sh: no host for OS Server's files: set OSS_FILES_HOST (or OSS_SERVERS)" >&2; exit 1; }

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
elif [ $# -eq 0 ] || [ "$*" = all ] || [ "$*" = pr ]; then
    mode=checks
    [ $# -eq 0 ] || mode="$*"
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
# An execution log an invocation, named for what it builds (ISOMER_EXECUTION_LOGS).
logs="${ISOMER_EXECUTION_LOGS:-}"
[ -z "$logs" ] || mkdir -p "$logs"
log_of() { [ -z "$logs" ] || printf -- "--execution_log_compact_file=%s/%s.zst" "$logs" "$1"; }
bazel build --keep_going "${flags[@]}" $(log_of build) "$@"
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
            *.ipa | *.zip | *.apk | *.tar.gz) cp "$exec_root/$file" "$out/" || exit ;;
        esac
    done
    ls -l "$out"
    exit 0
fi
[ "$mode" = checks ] || [ "$mode" = all ] || [ "$mode" = pr ] || exit $built
start=$SECONDS
# all: the tests built, not run (main: builds alone, to fill the cache).
run_tests() { if [ "$mode" = all ]; then bazel build "$@"; else bazel test "$@"; fi; }
# What the tests here need beyond the image: Xvfb, Mesa'"'"'s drivers, and the
# libraries Chrome for Testing loads.
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
if [ "$mode" != all ] && ! command -v Xvfb >/dev/null || [ ! -e /usr/lib/aarch64-linux-gnu/libnss3.so ]; then
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends xvfb libnss3 \
        libgl1-mesa-dri libegl-mesa0 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1 \
        libxrandr2 libpango-1.0-0 libcairo2 libcups2t64 libdrm2 fonts-dejavu-core >/dev/null ||
        { root_do apt-get update -qq >/dev/null && root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
            --no-install-recommends xvfb libnss3 libgl1-mesa-dri libegl-mesa0 libasound2t64 \
            libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 libpango-1.0-0 libcairo2 \
            libcups2t64 libdrm2 fonts-dejavu-core >/dev/null; }
fi
# Windows on Arm, built here.
windows=(--config=windows_on_linux --platforms=@isomer//tools/platforms:windows_arm64)
bazel build "${flags[@]}" "${windows[@]}" //windows/storybook_windows_application
built_windows=$?
# And, with the driver built in, the Windows Storybook and its headful test
# (the Storybook tests, for the windows-11-arm VM of GitHub).
bazel build "${flags[@]}" "${windows[@]}" --@isomer//drive:headful //windows/storybook_windows_application \
    //headless/storybook_headless_application:storybook_headful_windows_test || built_windows=1
# The tier-1 platforms run (the web here); the Linux tests are built but,
# for now (2026-11-05), not run.
bazel build "${flags[@]}" //tests/platforms:all
built_tests=$?
run_tests "${flags[@]}" --test_output=errors //tests/platforms:storybook_web_test //tests/foundation_networking:networking_test \
    //tests/cxx_interop:cxx_interop_test
tested_here=$?
# The headless tests: the Storybook built for the headless host and driven
# through its runtime (//headless in the examples), nothing drawn, and served
# over every transport (//remote: gRPC, WebSockets, Unix sockets, the CLI,
# the web thin client in headless Chrome).
run_tests "${flags[@]}" --@isomer//headless $(log_of headless) --test_output=errors //headless/... //remote/...
headless=$?
# Headful apps driven: the web Storybook with its driver built in, in
# Chrome, dialling out: to the isomer CLI hub, and to the hub of the
# Storybook tests run headful (the same tests as //headless); and the Linux
# Storybook under Xvfb, the same tests again.
run_tests "${flags[@]}" --@isomer//drive:headful $(log_of headful) --test_output=errors //remote:headful_web_test \
    //headless/storybook_headless_application:storybook_headful_web_test \
    //headless/storybook_headless_application:storybook_headful_linux_test
headful=$?
[ $headless -ne 0 ] || headless=$headful
cd "$root"
# The Linux wasm cell too (the Linux Playground links it; nothing
# here does).
bazel build //swift_gpu/linux:gl_backend_test //linux/libraries/swift_ui_wasm
built_gl=$?
run_tests --test_output=errors //tests/renderer:mock_renderer_test //tests/snapshot:snapshot_test
checked=$?
echo "container_build.sh: the tests took $((SECONDS - start)) s"

# all and pr: the x86_64 APK built too, and done.
if [ "$mode" = all ] || [ "$mode" = pr ]; then
    cd "$root/examples"
    built_x86=0
    [ -z "${ISOMER_ANDROID_X86_64:-}" ] || bazel build "${flags[@]}" --android_platforms=@rules_android//:x86_64 \
        //android/storybook_android_application:storybook_android_application_apk || built_x86=1
    for result in $built $built_windows $built_tests $tested_here $headless $built_gl $checked $built_x86; do [ "$result" -ne 0 ] && exit "$result"; done
    exit 0
fi
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
# The Android test APK for x86_64 too (ISOMER_ANDROID_X86_64), for the
# x86_64 emulator on the GitHub runner (tools/ci/hosted_android_test.sh).
built_x86=0
if [ -n "${ISOMER_ANDROID_X86_64:-}" ]; then
    x86=(--android_platforms=@rules_android//:x86_64)
    android=//android/storybook_android_application:storybook_android_application_apk
    if bazel build "${flags[@]}" "${x86[@]}" "$android"; then
        mkdir -p "$platforms/android-x86_64"
        for f in $(files "${x86[@]}" "$android"); do
            case "$f" in *_unsigned.apk) ;; *.apk) cp "$exec_root/$f" "$platforms/android-x86_64/storybook.apk" ;; esac
        done
    else
        built_x86=1
    fi
fi
# The same apps with their drivers built in (--@isomer//drive:headful), for
# the Storybook tests the GUI jobs run headful on GitHub VMs
# (tools/ci/hosted_headful_test.sh): the iPhone simulator app, the Mac app,
# and (ISOMER_ANDROID_X86_64) the x86_64 APK.
headful=(--@isomer//drive:headful)
mkdir -p "$platforms/headful"
bazel build "${flags[@]}" "${headful[@]}" --ios_multi_cpus=sim_arm64 \
    //apple/storybook_ios_application:storybook_ios_sim_application //apple/storybook_macos_application || built_x86=1
for f in $(files "${headful[@]}" --ios_multi_cpus=sim_arm64 //apple/storybook_ios_application:storybook_ios_sim_application) \
         $(files "${headful[@]}" //apple/storybook_macos_application); do
    case "$f" in *.ipa | *.zip) cp "$exec_root/$f" "$platforms/headful/" ;; esac
done
if [ -n "${ISOMER_ANDROID_X86_64:-}" ]; then
    if bazel build "${flags[@]}" "${headful[@]}" "${x86[@]}" "$android"; then
        for f in $(files "${headful[@]}" "${x86[@]}" "$android"); do
            case "$f" in *_unsigned.apk) ;; *.apk) cp "$exec_root/$f" "$platforms/headful/storybook-x86_64.apk" ;; esac
        done
    else
        built_x86=1
    fi
fi
chmod -R a+rwX "$platforms"
ls -l "$platforms" "$platforms/headful"
for result in $built $built_windows $built_tests $tested_here $headless $built_gl $checked $built_x86; do [ "$result" -ne 0 ] && exit "$result"; done
exit 0
'

cd "$ROOT/examples"
if [ -n "$inside" ]; then
    exec bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$@"
fi
exec oss machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$@"
