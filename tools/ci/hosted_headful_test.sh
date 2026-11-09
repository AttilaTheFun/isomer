#!/bin/bash
# The Storybook's tests (examples' StorybookHeadlessTests, the source the
# container runs headless) run headful on GitHub's own VMs, the one kind of
# job that runs outside a container: against the apps CI's container built
# with their drivers in (--@isomer//drive:headful, .ci/platforms/headful),
# each started by its launcher and dialling out to the test's own hub.
#
#   tools/ci/hosted_headful_test.sh apple <the iPhone simulator .ipa> <the Mac .zip> <out>
#       (xcode-27) a simulator made for the run, then the Mac's own screen
#   tools/ci/hosted_headful_test.sh android <the x86_64 .apk> <out>
#       (Ubuntu with KVM) tools/ci/hosted_android_emulator.sh's phone
#
# Only the tests are built here, by Bazel with its hermetic toolchains (the
# test and IsomerHeadless: no app); their outputs (the launchers' logs) are
# kept in <out>.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
platform="${1:?usage: hosted_headful_test.sh apple <.ipa> <.zip> <out> | android <.apk> <out>}"
shift
work="$(mktemp -d)"
udid=""
cleanup() {
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" > /dev/null 2>&1
        xcrun simctl delete "$udid" > /dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT
package=//headless/storybook_headless_application
failures=0
# One test target, its outputs kept.
run() {
    local target="$1" out="$2"
    shift 2
    # Downloads retried: a GitHub release's 504 once failed a whole job.
    # The repository cache the job keeps in GitHub's cache (build.yml).
    (cd "$ROOT/examples" && bazel test --test_output=errors --experimental_repository_downloader_retries=5 \
        --repository_cache="$HOME/.cache/isomer-bazel-repository" \
        "$@" "$package:$target") || failures=$((failures + 1))
    local logs
    logs="$(cd "$ROOT/examples" && bazel info bazel-testlogs 2> /dev/null)/headless/storybook_headless_application/$target"
    mkdir -p "$out/$target" && cp -R "$logs/." "$out/$target/" 2> /dev/null
}

case "$platform" in
apple)
    ipa="$(absolute "${1:?<.ipa>}")"
    zip="$(absolute "${2:?<.zip>}")"
    mkdir -p "${3:?<out>}"
    out="$(cd "$3" && pwd)"
    # The iPhone: a simulator of the run's own, the app installed.
    runtime="$(xcrun simctl list runtimes iOS available | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1)"
    [ -n "$runtime" ] || { echo "hosted_headful_test: no iOS runtime" >&2; exit 1; }
    udid="$(xcrun simctl create "isomer-headful-$$" "${HOSTED_IOS_DEVICE:-iPhone 17}" "$runtime")" || exit 1
    xcrun simctl boot "$udid" && xcrun simctl bootstatus "$udid" -b > /dev/null || exit 1
    xcrun simctl ui "$udid" appearance light
    mkdir -p "$work/ios" && unzip -q "$ipa" -d "$work/ios" && xcrun simctl install "$udid" "$work/ios/Payload/"*.app || exit 1
    run storybook_headful_ios_test "$out" --test_env=ISOMER_SIMULATOR="$udid"
    xcrun simctl shutdown "$udid" > /dev/null 2>&1
    # The Mac: this VM's own screen.
    ditto -x -k "$zip" "$work/mac" || exit 1
    defaults write com.apple.CrashReporter DialogType -string none
    run storybook_headful_macos_test "$out" --test_env=ISOMER_MAC_APP="$(ls -d "$work/mac/"*.app | head -1)"
    ;;
android)
    apk="$(absolute "${1:?<.apk>}")"
    mkdir -p "${2:?<out>}"
    out="$(cd "$2" && pwd)"
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
    adb="$sdk/platform-tools/adb"
    # The test links swift.org's Foundation, whose networking wants libcurl's
    # and libxml2's development libraries, which Ubuntu's runner lacks.
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        libcurl4-openssl-dev libxml2-dev > /dev/null ||
        { sudo apt-get update -qq > /dev/null &&
          sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
              libcurl4-openssl-dev libxml2-dev > /dev/null; }
    # The job's phone if one is up already (the picture tests leave theirs
    # running), else one booted here.
    serial="$("$adb" devices | awk '$2 == "device" && $1 ~ /^emulator-/ { print $1; exit }')"
    if [ -z "$serial" ]; then
        "$ROOT/tools/ci/hosted_android_emulator.sh" "$out/emulator.log" "$work/serial" < /dev/null > /dev/null || exit 1
        serial="$(cat "$work/serial")"
    fi
    "$adb" -s "$serial" install -r "$apk" > /dev/null || exit 1
    run storybook_headful_android_test "$out" --test_env=ADB="$adb" --test_env=ANDROID_SERIAL="$serial"
    ;;
*)
    echo "hosted_headful_test: apple or android, not $platform" >&2
    exit 2
    ;;
esac
echo "hosted_headful_test: $platform: $failures failed"
[ "$failures" -eq 0 ]
