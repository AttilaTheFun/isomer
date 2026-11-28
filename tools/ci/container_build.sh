#!/bin/bash
# CI's build of every platform, on GitHub's own runners, each platform where
# its tools run (ISOMER_PLATFORMS):
# - web, linux and android: together, in one job and one Bazel output base,
#   on GitHub's x86_64 Ubuntu runner, in Swift's own image with the Linux
#   apps' libraries added (tools/ci/job_tools.sh): Google's Android SDK and
#   NDK tools, and the hermetic JDK for Linux, are x86_64 programs, which
#   GitHub's arm64 runners have nothing to run (no Rosetta), and the
#   project's own image (ghcr.io/attilathefun/visor-agent, which an agent's
#   arm64 container runs this in) is built for arm64 alone;
# - apple: on Nimbus' self-hosted Linux runners (the owner, 2026-11-27: no
#   paid GitHub runners), with rules_applecross (.bazelrc's apple_on_linux)
#   and Xcode 27.2's SDK served by Nimbus (ISOMER_APPLE_ON_LINUX=1, which
#   .github/actions/nimbus_bazel sets): Apple's SDKs may not be
#   redistributed, so no GitHub runner takes the archive; or on a Mac, with
#   its own Xcode;
# - windows: on Linux, with ISOMER_WINDOWS_SDKS alone (Microsoft's sysroot,
#   which may not be redistributed either: tools/windows/README.md); CI
#   builds Windows on Windows instead (tools/ci/windows_build.ps1).
# Bazel's settings (its caches in GitHub's cache, the downloads, the SDKs)
# are tools/ci/ci_bazel.sh's, written before this runs.
#
#   tools/ci/container_build.sh [<bazel build args>…]   # default: the platforms' Storybooks and checks
#   tools/ci/container_build.sh all   # everything the checks build, built,
#                                     # nothing run or copied: main's populate
#                                     # (the one writer of GitHub's cache)
#   tools/ci/container_build.sh pr    # the same build, then every test that
#                                     # runs without a GUI: the core's, the
#                                     # web's in headless Chrome, the headless
#                                     # UI tests (examples' //headless and
#                                     # //remote): a pull request's checks
#                                     # (the owner, 2026-11-08: headless tests
#                                     # before a merge, builds after one)
#   tools/ci/container_build.sh headful  # the tests that draw (web, linux)
#   tools/ci/container_build.sh package <dir> <bazel build args>…
#                                     # the build, then the targets' packages
#                                     # (.ipa, a Mac app's .zip, the .apk, the
#                                     # site's .tar.gz) copied to <dir>, in
#                                     # this checkout, for CI to sign and publish
#
#   ISOMER_PLATFORMS  which of apple, android, web, linux and windows (default:
#                    a Mac's apple; a Linux machine's web, linux and android,
#                    with windows when ISOMER_WINDOWS_SDKS names its SDKs)
#   ISOMER_EXECUTION_LOGS  a folder for Bazel's execution logs (compact),
#                    to compare two runs' action keys when the cache misses
#   ISOMER_ANDROID_X86_64  pr and all: the Android test APK for x86_64 too
#
# With no arguments (verify's run) the tests run after the build: the core's
# (the mock renderer's and the snapshots', isomer's own module) and the
# web's Storybook in headless Chrome (//tests/platforms in the examples),
# their output in the log. Linux's Storybook test (under Xvfb) and the GL
# backend's check (on Mesa's EGL) are built, not run, for now (2026-11-05:
# CI runs the tier-1 platforms). The apps tested on GitHub's other machines
# are put in .ci/platforms: the iPhone's and the Mac's (apple, for the
# `xcode-27` Macs), Android's for x86_64 (android, for the Ubuntu runner's
# emulator) and Windows' (windows, for windows-11-arm). Any build or test
# failing fails the run.
#
# package (the publishing jobs'): the targets' files, found by cquery with
# the build's own flags, copied out of the execution root into the checkout.
# Flags as --name=value (--compilation_mode=opt, not -c opt): every argument
# that doesn't start with "-" is taken for a target. An Android app's files
# are its .apk (signed by its build with a debug key, which
# build_tools' `sign android` replaces with the release key), its unsigned one
# and its deploy jar; only the first is copied. A .tar.gz (the web site) is
# copied as is.
set -euo pipefail
# Bash 3.2 too: GitHub's Macs have no other (no mapfile, no ${!name}).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [ "$(uname -s)" = Darwin ]; then
    default=apple
else
    default="web linux android${ISOMER_WINDOWS_SDKS:+ windows}"
fi
platforms=" ${ISOMER_PLATFORMS:-$default} "
for platform in $platforms; do
    case "$platform" in
        apple | android | web | linux | windows) ;;
        *) echo "container_build.sh: no platform $platform (ISOMER_PLATFORMS: apple, android, web, linux, windows)" >&2; exit 2 ;;
    esac
    if [ "$(uname -s)" = Darwin ] && [ "$platform" != apple ]; then
        echo "container_build.sh: a Mac builds the Apple platforms alone here; $platform is built on Linux" >&2; exit 2
    fi
    if [ "$(uname -s)" != Darwin ] && [ "$platform" = apple ] && [ "${ISOMER_APPLE_ON_LINUX:-}" != 1 ]; then
        echo "container_build.sh: the Apple platforms are built on a Mac, or on Linux with Xcode's SDK served (ISOMER_APPLE_ON_LINUX=1: a Nimbus runner)" >&2; exit 2
    fi
done
if [ "$(uname -s)" != Darwin ]; then
    [[ $platforms != *" windows "* ]] || [ -n "${ISOMER_WINDOWS_SDKS:-}" ] ||
        { echo "container_build.sh: Windows on Linux takes Microsoft's sysroot: name it in ISOMER_WINDOWS_SDKS (tools/ci/ci_bazel.sh)" >&2; exit 2; }
fi
has() { [[ $platforms == *" $1 "* ]]; }
echo "container_build.sh: the platforms here:$platforms"

# An app in each of its modes (docs/modes.md), each by its own name in this
# build: isomer_application's example, the selection probe, on the iPhone,
# the Mac, Android and the web, compiled, in a web view and remote.
probe=//shared/selection_probe_application
apps=()
add_probes() { local app; for app in "$@"; do apps+=("$probe:selection_probe_$app"); done; }

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
elif [ $# -eq 0 ] || [ "$*" = all ] || [ "$*" = pr ] || [ "$*" = headful ]; then
    mode=checks
    [ $# -eq 0 ] || mode="$*"
    if [ "$mode" = headful ] && ! has web && ! has linux; then
        echo "container_build.sh: headful runs the web and Linux tests: ISOMER_PLATFORMS names neither" >&2; exit 2
    fi
    # Each platform's Storybook, and its apps in their modes. The iPhone
    # Storybook on Isomer's frameworks too: the proof's parity app, the one
    # build of Apple's tree renderer (apple/libraries/swift_ui_tree), which
    # nothing else here compiles.
    if has apple; then
        apps+=(//apple/storybook_ios_application:storybook_ios_sim_application
               //apple/storybook_isomer_ios_application
               //apple/storybook_macos_application:storybook_macos_application
               //headless/storybook_headless_application:storybook_headful_apple_runner
               //apple/remote_ios_application
               //apple/webview_ios_application)
        add_probes ios_compiled ios_webview ios_remote macos_compiled macos_webview macos_remote
    fi
    if has web; then
        apps+=(//web/storybook_web_application:storybook_web_application)
        add_probes web
    fi
    if has android; then
        apps+=(//android/storybook_android_application:storybook_android_application
               //android/storybook_android_application:storybook_android_application_apk
               //android/webview_android_application:webview_android_application_apk
               //android/wasm_page_android_application:wasm_page_android_application_apk)
        add_probes android_compiled_apk android_webview_apk android_remote_apk
        # The release jobs' tools (build_tools' sign and proof-diff, and
        # what they run), built where the release jobs build them: a pull
        # request that breaks them fails here, not at a release.
        apps+=(//tools/ci_tools:all)
    fi
    has linux && apps+=(//linux/storybook_linux_application:storybook_linux_application)
    set -- --ios_multi_cpus=sim_arm64 ${apps[@]+"${apps[@]}"}
fi

# The build in the examples' module, then (the checks) the tests in
# isomer's and the examples', or (package) the packages copied out.
steps='
root=$1 mode=$2 out=$3 platforms=$4; shift 4
has() { [[ $platforms == *" $1 "* ]]; }
cd "$root/examples"
# An execution log an invocation, named for what it builds (ISOMER_EXECUTION_LOGS).
logs="${ISOMER_EXECUTION_LOGS:-}"
[ -z "$logs" ] || mkdir -p "$logs"
log_of() { [ -z "$logs" ] || printf -- "--execution_log_compact_file=%s/%s.zst" "$logs" "$1"; }
built=0
targets=0
for argument in "$@"; do case "$argument" in -*) ;; *) targets=1 ;; esac; done
if [ $targets -eq 1 ]; then
    bazel build --keep_going $(log_of build) "$@"
    built=$?
fi
if [ "$mode" = package ]; then
    [ $built -eq 0 ] || exit $built
    options=()
    query=""
    # cquery takes one expression: the targets as a union of them.
    for argument in "$@"; do
        case "$argument" in -*) options+=("$argument") ;; *) query="${query:+$query + }$argument" ;; esac
    done
    exec_root="$(bazel info "${options[@]}" execution_root)" || exit
    files="$(bazel cquery "${options[@]}" "$query" --output=files 2> /dev/null)" || exit
    for file in $files; do
        case "$file" in
            *_unsigned.apk) ;;
            *.ipa | *.zip | *.apk | *.tar.gz) cp "$exec_root/$file" "$out/" || exit ;;
        esac
    done
    ls -l "$out"
    exit 0
fi
[ "$mode" = checks ] || [ "$mode" = all ] || [ "$mode" = pr ] || [ "$mode" = headful ] || exit $built
start=$SECONDS
results=()
# The mode setting (--@isomer//:mode, docs/modes.md) picks each platform
# app of an isomer_application: each mode built above by its own name, the
# setting checked here by analysis alone (a flag on the command line puts
# every output in a folder of its own, which the cache has not seen), the
# platform names resolving to that mode.
picked=0
if [ "$mode" != headful ]; then
    mode_platforms=()
    has apple && mode_platforms+=(ios macos)
    has android && mode_platforms+=(android_apk)
    for app_mode in webview remote; do
        for platform in ${mode_platforms[@]+"${mode_platforms[@]}"}; do
            target=//shared/selection_probe_application:selection_probe_$platform
            want="${target%_apk}_${app_mode}"
            [ "$platform" = android_apk ] && want="${want}_apk"
            deps="$(bazel cquery --@isomer//:mode=$app_mode --ios_multi_cpus=sim_arm64 \
                "deps($target, 1)" --output=label 2> /dev/null)" || { picked=1; continue; }
            if ! grep -q "^$want " <<< "$deps"; then
                echo "container_build.sh: --@isomer//:mode=$app_mode builds $target as something other than $want:" >&2
                echo "$deps" >&2
                picked=1
            fi
        done
    done
fi
results+=($built $picked)
# all: the tests built, not run (main: builds alone, to fill the cache).
run_tests() { if [ "$mode" = all ]; then bazel build "$@"; else bazel test "$@"; fi; }
# What the tests on Linux need beyond the image: Xvfb, the Mesa drivers,
# and the libraries Chrome for Testing loads.
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
need=0
if has web || has linux; then
    { [ "$mode" != all ] && ! command -v Xvfb >/dev/null; } && need=1
    [ -e /usr/lib/aarch64-linux-gnu/libnss3.so ] || [ -e /usr/lib/x86_64-linux-gnu/libnss3.so ] || need=1
fi
if [ $need -eq 1 ]; then
    packages=(xvfb libnss3 libgl1-mesa-dri libegl-mesa0 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1
              libxrandr2 libpango-1.0-0 libcairo2 libcups2t64 libdrm2 fonts-dejavu-core)
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" >/dev/null ||
        { root_do apt-get update -qq >/dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" >/dev/null; }
fi
# headful (container-verify, at verify only): the tests that draw. The web
# Storybook in headless Chrome, its test stories pictured; and the apps
# with their drivers built in, driven as the iPhone and the Mac are: the web
# Storybook in Chrome, dialling out to the isomer CLI hub and to the hub of
# the Storybook tests run headful (the same tests as //headless), and the
# Linux Storybook under Xvfb, the same tests again.
if [ "$mode" = headful ]; then
    bazel test --test_output=errors //tests/platforms:storybook_web_test
    drawn=$?
    bazel test --@isomer//drive:headful $(log_of headful) --test_output=errors //remote:headful_web_test \
        //headless/storybook_headless_application:storybook_headful_web_test \
        //headless/storybook_headless_application:storybook_headful_linux_test
    headful=$?
    echo "container_build.sh: the tests took $((SECONDS - start)) s"
    for result in $built $drawn $headful; do [ "$result" -ne 0 ] && exit "$result"; done
    exit 0
fi
# Windows on Arm, built on Linux (only with the Microsoft sysroot).
windows=(--config=windows_tests_on_linux --platforms=@isomer//tools/platforms:windows_arm64)
if has windows; then
    bazel build "${windows[@]}" //windows/storybook_windows_application
    results+=($?)
    # The plain app, kept now: the headful build below writes the same
    # path (a flag given on the command line leaves Bazel output folders as
    # they are), and the platform tests want the app with no driver in it.
    windows_plain="$root/.ci/windows-plain"
    rm -rf "$windows_plain" && mkdir -p "$windows_plain"
    for f in $(bazel cquery "${windows[@]}" //windows/storybook_windows_application --output=files 2> /dev/null); do
        case "$f" in *.exe) cp "$(bazel info execution_root)/$f" "$windows_plain/" ;; esac
    done
    # And the Windows Storybook with its driver built in (its headful
    # build), with the Storybook tests built for Windows to drive it there.
    bazel build "${windows[@]}" --@isomer//drive:headful //windows/storybook_windows_application \
        //headless/storybook_headless_application:storybook_headful_windows_test
    results+=($?)
    # The WasmKit host runtime for Windows: an app may host reactors there;
    # mixed mode over it, and the wasm cell (the Windows wasm example links
    # it; nothing built here does).
    bazel build "${windows[@]}" @isomer//shared/wasm_host:wasmkit_runtime @isomer//shared/wasm_host:mixed_runtime \
        @isomer//windows/libraries/swift_ui_wasm:host
    results+=($?)
fi
if has android; then
    # The WasmKit host runtime for Android too: an app may host reactors
    # there (the Playground does), though no app here does; and mixed mode
    # over it (its thread on the Foundation of the Swift SDK there).
    bazel build --platforms=@isomer//tools/platforms:android_arm64 @isomer//shared/wasm_host:wasmkit_runtime \
        @isomer//shared/wasm_host:mixed_runtime
    results+=($?)
    # The Windows Electron package, zipped by the jar of the hermetic JDK
    # (x86_64 on Linux, so built beside Android).
    bazel build //electron/example_full_react_electron_application:example_windows_package
    results+=($?)
    # The checks that build for Android (some for wasm beside it; the
    # library evolution test builds a resilient library against Isomer built
    # with --@isomer//:library_evolution, for Android and the web).
    run_tests --test_output=errors //tests/foundation_networking:networking_test //tests/cxx_interop:cxx_interop_test \
        //tests/android_app_attributes:android_app_attributes_test //tests/android_aar:android_aar_test \
        //tests/swift6_app:swift6_app_test //tests/android_libcxx_shared:android_libcxx_shared_test \
        //tests/prebuilt_swift_library:prebuilt_swift_library_test \
        //tests/library_evolution:library_evolution_test
    results+=($?)
fi
if has apple && [ "$(uname -s)" = Darwin ]; then
    # Mixed mode on the Mac (docs/side_modules.md): the Storybook as a side
    # module over its runtime module, native code beside WasmKit, and
    # interpreted throughout (ISO_MIXED_NATIVE=0), each rendering what its
    # reactor renders, byte for byte. Nothing drawn. On a Mac alone: on Linux
    # (a Nimbus runner) the analysis of them finds a cycle through the wasm
    # build of the side module, so the apple job runs them in its macOS VM.
    run_tests --test_output=errors //tests/side_modules:mixed_render_test //tests/side_modules:mixed_interpreted_render_test
    results+=($?)
fi
if has web; then
    # The tests that draw nothing run here; those that do (the web Storybook
    # in Chrome, the headful apps) in headful mode, container-verify, at
    # verify. The web-view session test drives a page in Chrome that draws
    # nothing. Beside them the builds of the threads SDK (wasm32-wasip1-threads,
    # run under the WASI Threads of WasmKit): the SQLite check, and the
    # threaded tap counter frame for frame with the single-threaded one. And a
    # text field key reaching a wasm page under WasmKit (iso_hot_key_event),
    # and the parsed modules WasmKit keeps, dropped with the last view.
    run_tests --test_output=errors //tests/sqlite_wasi:sqlite_file_test //tests/webview_session:session_test \
        //tests/sqlite_wasi:sqlite_file_threads_test //tests/wasm_engines:wasmkit_threads_test \
        //tests/wasm_key_event:wasm_key_event_test //tests/wasm_engines:wasmkit_modules_test
    results+=($?)
fi
if has linux; then
    # The tier-1 platforms run (the web here); the Linux tests are built
    # but, for now (2026-11-05), not run.
    bazel build //tests/platforms:all
    results+=($?)
    # The headless tests: the Storybook built for the headless host and
    # driven through its runtime (//headless in the examples), nothing
    # drawn, and served over every transport (//remote: gRPC, WebSockets,
    # Unix sockets, the CLI, the web thin client in headless Chrome). With
    # them the selection probe served headless, what its apps draw in
    # remote mode. The Apple targets among them (the hosted iPhone tests,
    # the Mac runner of the headful tests) belong to the Apple build.
    apple_headless=()
    has apple || apple_headless=(-//headless/storybook_headless_application:storybook_hosted_ios_test
                                 -//headless/storybook_headless_application:storybook_headful_apple_runner)
    run_tests --@isomer//headless $(log_of headless) --test_output=errors -- //headless/... //remote/... \
        //shared/selection_probe_application:selection_probe_server ${apple_headless[@]+"${apple_headless[@]}"}
    results+=($?)
    # The headful apps and their tests built (run in headful mode).
    bazel build --@isomer//drive:headful $(log_of headful) //remote:headful_web_test \
        //headless/storybook_headless_application:storybook_headful_web_test \
        //headless/storybook_headless_application:storybook_headful_linux_test
    results+=($?)
    cd "$root"
    # The Linux wasm cell too (the Linux Playground links it; nothing
    # here does), and mixed mode on Linux (its thread on corelibs Foundation).
    bazel build //swift_gpu/linux:gl_backend_test //linux/libraries/swift_ui_wasm //shared/wasm_host:mixed_runtime
    results+=($?)
    # And the checks built for wasm, each a WASI command run in headless
    # Chrome (//tools/wasm/wasi_run_browser): Foundation, Combine, OSLog,
    # the Metal translator, and a program built out of band against a
    # wasm_sdk_bundle (the Playground SDK, the Swift SDK Foundation in it).
    run_tests --test_output=errors //tests/renderer:mock_renderer_test //tests/snapshot:snapshot_test //tests/hub:hub_test \
        //foundation/tests:foundation_test //foundation/tests:internationalization_test \
        //foundation/tests:internationalization_trimmed_test //frameworks/combine/tests:combine_test \
        //frameworks/os_log/tests:os_log_test //metal/isomer_metal/tests:translator_test \
        //tools/wasm/sdk_bundle_test
    results+=($?)
    cd "$root/examples"
fi
echo "container_build.sh: the tests took $((SECONDS - start)) s"

# all and pr: the x86_64 APK and the AndroidX override built too, and done.
if [ "$mode" = all ] || [ "$mode" = pr ]; then
    if has android; then
        if [ -n "${ISOMER_ANDROID_X86_64:-}" ]; then
            bazel build --android_platforms=@rules_android//:x86_64 \
                //android/storybook_android_application:storybook_android_application_apk
            results+=($?)
        fi
        # An app with AndroidX of its own points Isomer at its set
        # (docs/android_maven.md): the Android Storybook built through one.
        bazel build --@isomer//android/maven:androidx=//tests/android_maven:androidx_for_isomer \
            //android/storybook_android_application:storybook_android_application_apk
        results+=($?)
    fi
    df -h / /mnt 2> /dev/null || df -h /
    for result in "${results[@]}"; do [ "$result" -ne 0 ] && exit "$result"; done
    exit 0
fi
# The apps tested elsewhere, on the other GitHub machines: the workflow
# uploads each folder as an artifact.
platforms_out="$root/.ci/platforms"
rm -rf "$platforms_out" && mkdir -p "$platforms_out/headful" && chmod -R 777 "$platforms_out"
exec_root="$(bazel info execution_root)"
files() { bazel cquery "$@" --output=files 2> /dev/null; }
if has apple; then
    # The iPhone and Mac Storybooks, and the web-view iPhone app (the
    # Storybook as wasm in a web view, drawn by the tree renderer), for
    # tools/ci/hosted_apple_test.sh.
    for f in $(files --ios_multi_cpus=sim_arm64 //apple/storybook_ios_application:storybook_ios_sim_application) \
             $(files --ios_multi_cpus=sim_arm64 //apple/webview_ios_application) \
             $(files //apple/storybook_macos_application); do
        case "$f" in *.ipa | *.zip) cp "$exec_root/$f" "$platforms_out/" ;; esac
    done
    # The same apps with their drivers built in (--@isomer//drive:headful),
    # for the Storybook tests run headful (tools/ci/hosted_headful_test.sh).
    headful=(--@isomer//drive:headful)
    bazel build "${headful[@]}" --ios_multi_cpus=sim_arm64 \
        //apple/storybook_ios_application:storybook_ios_sim_application //apple/storybook_macos_application
    results+=($?)
    for f in $(files "${headful[@]}" --ios_multi_cpus=sim_arm64 //apple/storybook_ios_application:storybook_ios_sim_application) \
             $(files "${headful[@]}" //apple/storybook_macos_application); do
        case "$f" in *.ipa | *.zip) cp "$exec_root/$f" "$platforms_out/headful/" ;; esac
    done
    # And the tests that drive them, a Mac command, run on the Mac as they are.
    runner=//headless/storybook_headless_application:storybook_headful_apple_runner
    if bazel build "$runner"; then
        for f in $(files "$runner"); do cp "$exec_root/$f" "$platforms_out/headful/storybook_headful_apple_runner"; done
    else
        results+=(1)
    fi
    # The driver probe on the SwiftUI of Apple (views shaped as those of an
    # app), upright and turned to landscape by itself, and on the Mac, and
    # its tests, a Mac command as for the Storybook: the checks of the Apple
    # driver itself.
    probe_apps=(//apple/driver_probe_ios_application:driver_probe_ios_application
                //apple/driver_probe_ios_application:driver_probe_landscape_ios_application)
    probe_mac=//apple/driver_probe_macos_application
    probe_runner=//headless/driver_probe:driver_probe_headful_apple_runner
    if bazel build "${headful[@]}" --ios_multi_cpus=sim_arm64 "${probe_apps[@]}" && bazel build "${headful[@]}" "$probe_mac" &&
        bazel build "$probe_runner"; then
        mkdir -p "$platforms_out/headful/probe"
        for app in "${probe_apps[@]}"; do
            for f in $(files "${headful[@]}" --ios_multi_cpus=sim_arm64 "$app"); do
                case "$f" in *.ipa) cp "$exec_root/$f" "$platforms_out/headful/probe/" ;; esac
            done
        done
        for f in $(files "${headful[@]}" "$probe_mac"); do
            case "$f" in *.zip) cp "$exec_root/$f" "$platforms_out/headful/probe/" ;; esac
        done
        for f in $(files "$probe_runner"); do cp "$exec_root/$f" "$platforms_out/headful/probe/driver_probe_headful_apple_runner"; done
    else
        results+=(1)
    fi
    # And the tests hosted in the iPhone app: their XCTest bundle and the
    # app built to host them (headful, for the simulator), which the Mac
    # runs with an xctestrun of its own (tools/ci/hosted_headful_test.sh),
    # as rules_apple runs them.
    hosted=(--@isomer//drive:headful --ios_multi_cpus=sim_arm64)
    if bazel build "${hosted[@]}" //headless/storybook_headless_application:storybook_hosted_ios_test \
        //apple/storybook_ios_application:storybook_test_host; then
        mkdir -p "$platforms_out/headful/hosted"
        # One query a target (cquery takes one expression); the bundle is
        # the test target internal bundle target archive.
        for f in $(files "${hosted[@]}" //headless/storybook_headless_application:storybook_hosted_ios_test.__internal__.__test_bundle) \
                 $(files "${hosted[@]}" //apple/storybook_ios_application:storybook_test_host); do
            case "$f" in *.zip | *.ipa) cp "$exec_root/$f" "$platforms_out/headful/hosted/" ;; esac
        done
        ls -l "$platforms_out/headful/hosted"
    else
        results+=(1)
    fi
fi
if has android; then
    # The Android Storybook for x86_64, for the emulator on the GitHub
    # Ubuntu runner (tools/ci/hosted_android_test.sh), and with its driver
    # built in, for the Storybook tests run headful there.
    x86=(--android_platforms=@rules_android//:x86_64)
    android=//android/storybook_android_application:storybook_android_application_apk
    mkdir -p "$platforms_out/android-x86_64"
    for flavour in plain headful; do
        extra=()
        [ "$flavour" = plain ] || extra=(--@isomer//drive:headful)
        if bazel build ${extra[@]+"${extra[@]}"} "${x86[@]}" "$android"; then
            for f in $(files ${extra[@]+"${extra[@]}"} "${x86[@]}" "$android"); do
                case "$f" in
                    *_unsigned.apk) ;;
                    *.apk) if [ "$flavour" = plain ]; then cp "$exec_root/$f" "$platforms_out/android-x86_64/storybook.apk"
                           else cp "$exec_root/$f" "$platforms_out/headful/storybook-x86_64.apk"; fi ;;
                esac
            done
        else
            results+=(1)
        fi
    done
    # The Storybook in web-view mode (its site in the APK, Kotlin only; for
    # x86_64 too, as AndroidX brings a native library of its own), for the
    # web-view test after the stories there.
    webview=//android/webview_android_application:webview_android_application_apk
    if bazel build "${x86[@]}" "$webview"; then
        for f in $(files "${x86[@]}" "$webview"); do
            case "$f" in
                *_unsigned.apk) ;;
                *.apk) cp "$exec_root/$f" "$platforms_out/android-x86_64/webview.apk" ;;
            esac
        done
    fi
    [ -f "$platforms_out/android-x86_64/webview.apk" ] || { echo "no web-view APK"; results+=(1); }
fi
if has windows; then
    # The plain app kept before its headful build (above), for
    # tools/ci/hosted_windows_test.ps1.
    mkdir -p "$platforms_out/windows"
    cp "$windows_plain"/*.exe "$platforms_out/windows/" 2> /dev/null || echo "no plain Windows app"
    sdk="$(bazel info output_base)/external/+swift_windows_sdk_repository+swift_windows_sdk/swift-windows-sdk"
    cp "$sdk"/runtime/aarch64/*.dll "$platforms_out/windows/" 2>/dev/null
    cp -R "$root/examples/storybook/assets" "$platforms_out/windows/assets"
    # The headful Windows Storybook and its tests, for the windows job on a
    # GitHub VM: both executables, the Swift runtime and XCTest DLLs, the
    # assets and the launcher.
    mkdir -p "$platforms_out/windows-headful"
    # The test where its build put it, and the headful app beside it in
    # that configuration (the headful flag names its output folder).
    test_exe="$(find -L "$exec_root/bazel-out" -path "*/bin/headless/storybook_headless_application/storybook_headful_windows_test.exe" 2>/dev/null | head -1)"
    if [ -n "$test_exe" ]; then
        cp "$test_exe" "$platforms_out/windows-headful/"
        cp "${test_exe%%/bin/*}/bin/windows/storybook_windows_application/storybook_windows_application.exe" "$platforms_out/windows-headful/" ||
            echo "no headful Windows app beside $test_exe"
    else
        echo "no storybook_headful_windows_test.exe under $exec_root/bazel-out"
    fi
    cp "$sdk"/runtime/aarch64/*.dll "$platforms_out/windows-headful/" 2>/dev/null
    # XCTest and Testing for arm64, with every DLL beside them
    # (_TestingInterop and the rest they load): bin64a in the SDK (bin64
    # is x64, bin32 x86).
    find -L "$sdk/Windows.platform" -path "*/bin64a/*" \( -iname "XCTest.dll" -o -iname "Testing.dll" \) 2>/dev/null |
        while read -r dll; do cp "$(dirname "$dll")"/*.dll "$platforms_out/windows-headful/"; done
    cp -R "$root/examples/storybook/assets" "$platforms_out/windows-headful/assets"
    cp "$root/drive/launchers/windows_launcher.sh" "$platforms_out/windows-headful/"
fi
chmod -R a+rwX "$platforms_out"
ls -lR "$platforms_out" | head -80
df -h / /mnt 2> /dev/null || df -h /
for result in "${results[@]}"; do [ "$result" -ne 0 ] && exit "$result"; done
exit 0
'

cd "$ROOT/examples"
exec bash -c "$steps" container_build "$ROOT" "$mode" "$out" "$platforms" "$@"
