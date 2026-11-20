#!/bin/bash
# The Storybook's tests (examples' StorybookHeadlessTests, the source the
# container runs headless) run headful on GitHub's own VMs, the one kind of
# job that runs outside a container: against the apps CI's container built
# with their drivers in (--@isomer//drive:headful, .ci/platforms/headful),
# each started by its launcher and dialling out to the test's own hub.
#
#   tools/ci/hosted_headful_test.sh apple <the iPhone simulator .ipa> <the Mac .zip> <out>
#       (xcode-27) a simulator made for the run, then the Mac's own screen;
#       HEADFUL_APPLE_PARTS picks some of them (default "ios hosted macos":
#       the tests driving the iPhone app, the tests hosted in it, the Mac's),
#       so CI runs them on Macs of their own at once
#   tools/ci/hosted_headful_test.sh android <the x86_64 .apk> <out>
#       (Ubuntu with KVM) tools/ci/hosted_android_emulator.sh's phone
#   tools/ci/hosted_headful_test.sh windows <the windows-headful folder> <out>
#       (windows-11-arm, Git's bash) the app and its tests as CI's container
#       built them, the tests run here as they are
#
# The iPhone's and the Mac's tests come built too when CI's container made
# them (storybook_headful_apple_runner beside the .ipa); otherwise, and on
# the Android VM, only the tests are built here, by Bazel with its hermetic
# toolchains (the test and IsomerHeadless: no app); no Swift
# toolchain builds for Windows on Windows here, so CI's container builds
# Windows' tests too. Their outputs (the launchers' logs) are kept in <out>.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
platform="${1:?usage: hosted_headful_test.sh apple <.ipa> <.zip> <out> | android <.apk> <out> | windows <dir> <out>}"
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
# CI's mirrors: GitHub's at Bazel's mirror, Maven Central's at Google's.
cp "$ROOT/tools/ci/downloader.cfg" "$work/downloader.cfg"
package=//headless/storybook_headless_application
failures=0
# The iPhone's and the Mac's tests as CI's container built them, a Mac
# command beside the apps (storybook_headful_apple_runner): run as they are,
# Swift Testing's frameworks from this Mac's Xcode. Without one, built here.
apple_runner() {
    local name="$1" out="$2"
    shift 2
    local developer platform log status attempt=0 filters=() failed=() test
    developer="$(xcode-select -p)"
    platform="$developer/Platforms/MacOSX.platform/Developer"
    mkdir -p "$out/$name"
    chmod +x "$runner"
    log="$out/$name/test.log"
    # A simulator that went down before (under the tests before these) up first.
    [ -z "$udid" ] || hosted_sim_healthy || hosted_sim_recover "$out"
    while :; do
        # ISOMER_SIMULATOR the simulator as it is now (another after a recovery).
        env DYLD_FRAMEWORK_PATH="$platform/Library/Frameworks:$platform/Library/PrivateFrameworks" \
            DYLD_LIBRARY_PATH="$platform/usr/lib" TEST_UNDECLARED_OUTPUTS_DIR="$out/$name" "$@" \
            ${udid:+ISOMER_SIMULATOR="$udid"} "$runner" ${filters[@]+"${filters[@]}"} > "$log" 2>&1
        status=$?
        cat "$log"
        [ "$status" -ne 0 ] || return 0
        # The simulator taken down under the tests by GitHub's image
        # (tools/ci/hosted_simulator.sh): up again, and the tests that failed
        # run again (Swift Testing's --filter), at most twice. A test that
        # fails with the simulator up still fails.
        [ -n "$udid" ] && [ "$attempt" -lt 2 ] || break
        # A launcher's simctl call that gave no answer (ios_launcher.sh's
        # `bounded`) is CoreSimulator's trouble too: started again, and
        # the tests that failed run again.
        if hosted_sim_healthy && ! grep -qE "CoreSimulatorService: Connection interrupted|device is not booted|ios_launcher: .* gave no answer in [0-9]+ s" "$log"; then
            break
        fi
        hosted_sim_recover "$out" || break
        failed=($(sed -n 's/^✘ Test \([A-Za-z0-9_]*\)(.*) failed after .*/\1/p' "$log"))
        [ ${#failed[@]} -gt 0 ] || break
        filters=()
        for test in "${failed[@]}"; do filters+=(--filter "$test"); done
        attempt=$((attempt + 1))
        log="$out/$name/test.again-$attempt.log"
        echo "hosted_headful_test: $name: ${#failed[@]} tests again on the simulator started again"
    done
    failures=$((failures + 1))
}
# The tests hosted in the iPhone app as CI's container built them (their
# XCTest bundle and the app hosting it, beside the .ipa in hosted/): run
# with an xctestrun as rules_apple's runner writes one, by xcodebuild, on
# the job's simulator.
hosted_xctest() {
    local out="$1" name=storybook_hosted_ios_test root="$work/hosted"
    mkdir -p "$root" "$out/$name"
    unzip -q "$(ls "$hosted_dir"/*.ipa | head -1)" -d "$root/ipa" && unzip -q "$(ls "$hosted_dir"/*.zip | head -1)" -d "$root" ||
        { failures=$((failures + 1)); return; }
    local app bundle host executable identifier developer
    app="$(ls -d "$root/ipa/Payload/"*.app | head -1)"
    host="$(basename "$app" .app)"
    mv "$app" "$root/"
    bundle="$(basename "$(ls -d "$root/"*.xctest | head -1)" .xctest)"
    executable="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$root/$host.app/Info.plist")"
    identifier="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$root/$host.app/Info.plist")"
    developer="$(xcode-select -p)/Platforms/iPhoneSimulator.platform/Developer"
    cat > "$root/$name.xctestrun" <<XCTESTRUN
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>$bundle</key>
  <dict>
    <key>ProductModuleName</key><string>$bundle</string>
    <key>TestBundlePath</key><string>__TESTROOT__/$bundle.xctest</string>
    <key>IsAppHostedTestBundle</key><true/>
    <key>TestHostPath</key><string>__TESTROOT__/$host.app</string>
    <key>TestHostBundleIdentifier</key><string>$identifier</string>
    <key>IsUITestBundle</key><false/>
    <key>IsXCTRunnerHostedTestBundle</key><false/>
    <key>DependentProductPaths</key>
    <array><string>__TESTROOT__/$bundle.xctest</string><string>__TESTROOT__/$host.app</string></array>
    <key>TestingEnvironmentVariables</key>
    <dict>
      <key>DYLD_INSERT_LIBRARIES</key><string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib/libXCTestBundleInject.dylib</string>
      <key>XCInjectBundleInto</key><string>__TESTHOST__/$host.app/$executable</string>
      <key>DYLD_FRAMEWORK_PATH</key><string>$developer/Library/Frameworks</string>
      <key>DYLD_LIBRARY_PATH</key><string>__PLATFORMS__/iPhoneSimulator.platform/Developer/usr/lib</string>
    </dict>
  </dict>
  <key>__xctestrun_metadata__</key>
  <dict><key>FormatVersion</key><integer>1</integer></dict>
</dict>
</plist>
XCTESTRUN
    xcodebuild test-without-building -xctestrun "$root/$name.xctestrun" -destination "id=$udid" \
        -resultBundlePath "$out/$name/result.xcresult" > "$out/$name/test.log" 2>&1
    local status=$?
    grep -E "Test run with|✘|passed after|failed after|TEST (SUCCEEDED|FAILED)" "$out/$name/test.log" | tail -40
    [ "$status" -eq 0 ] || { tail -30 "$out/$name/test.log"; failures=$((failures + 1)); }
}
# One test target, its outputs kept.
run() {
    local target="$1" out="$2"
    shift 2
    # Downloads retried: a GitHub release's 504 once failed a whole job.
    # The repository cache the job keeps in GitHub's cache (build.yml), and
    # GitHub's downloads tried at Bazel's mirror after GitHub.
    (cd "$ROOT/examples" && bazel test --test_output=errors --experimental_repository_downloader_retries=5 \
        --repository_cache="$HOME/.cache/isomer-bazel-repository" --downloader_config="$work/downloader.cfg" \
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
    parts=" ${HEADFUL_APPLE_PARTS:-ios hosted macos} "
    runner="$(dirname "$ipa")/storybook_headful_apple_runner"
    [ -f "$runner" ] || runner=""
    hosted_dir="$(dirname "$ipa")/hosted"
    [ -d "$hosted_dir" ] || hosted_dir=""
    if [[ $parts == *" ios "* || $parts == *" hosted "* ]]; then
        # The iPhone: a simulator of the run's own, the apps installed
        # (tools/ci/hosted_simulator.sh, which starts it again should
        # GitHub's image take it down).
        . "$ROOT/tools/ci/hosted_simulator.sh"
        probe="$(dirname "$ipa")/probe"
        mkdir -p "$work/ios" && unzip -q "$ipa" -d "$work/ios" || exit 1
        prepare_ios() {
            local app_ipa
            xcrun simctl ui "$udid" appearance light
            xcrun simctl install "$udid" "$work/ios/Payload/"*.app || return 1
            [[ $parts == *" ios "* && -f "$probe/driver_probe_headful_apple_runner" ]] || return 0
            for app_ipa in "$probe"/*.ipa; do
                rm -rf "$work/probe" && mkdir -p "$work/probe" && unzip -q "$app_ipa" -d "$work/probe" &&
                    xcrun simctl install "$udid" "$work/probe/Payload/"*.app || return 1
            done
        }
        hosted_sim_start "isomer-headful-$$" prepare_ios || exit 1
    fi
    if [[ $parts == *" ios "* ]]; then
        if [ -n "$runner" ]; then
            apple_runner storybook_headful_ios_test "$out" \
                ISOMER_BUNDLE_ID=com.LoganShire.IsomerStorybook ISOMER_HEADFUL_LAUNCHER="$ROOT/drive/launchers/ios_launcher.sh"
        else
            run storybook_headful_ios_test "$out" --test_env=ISOMER_SIMULATOR="$udid"
        fi
        # The driver probe's tests (Apple's driver's own checks), when CI's
        # container built the probe and its runner: upright, and turned to
        # landscape by the app itself on this upright simulator.
        if [ -f "$probe/driver_probe_headful_apple_runner" ]; then
            runner="$probe/driver_probe_headful_apple_runner" apple_runner driver_probe_headful_ios_test "$out" \
                ISOMER_BUNDLE_ID=com.LoganShire.IsomerExamples.DriverProbe \
                ISOMER_LANDSCAPE_BUNDLE_ID=com.LoganShire.IsomerExamples.DriverProbeLandscape \
                ISOMER_HEADFUL_LAUNCHER="$ROOT/drive/launchers/ios_launcher.sh"
        fi
    fi
    if [[ $parts == *" hosted "* ]]; then
        # The same tests hosted in the app: an XCTest bundle in the headful
        # iPhone Storybook, built here, driving it in its own process with no
        # network. On this simulator: one rules_apple's runner made beside it
        # took over a minute to boot on GitHub's runner, xcodebuild hung, and
        # the Mac's tests after it timed out.
        if [ -n "$hosted_dir" ]; then
            hosted_sim_healthy || hosted_sim_recover "$out"
            hosted_xctest "$out"
        else
            run storybook_hosted_ios_test "$out" --@isomer//drive:headful --ios_multi_cpus=sim_arm64 \
                --test_env=ISOMER_SIMULATOR="$udid"
        fi
    fi
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" > /dev/null 2>&1
        xcrun simctl delete "$udid" > /dev/null 2>&1
        udid=""
    fi
    if [[ $parts == *" macos "* ]]; then
        # The Mac: this VM's own screen.
        ditto -x -k "$zip" "$work/mac" || exit 1
        defaults write com.apple.CrashReporter DialogType -string none
        app="$(ls -d "$work/mac/"*.app | head -1)"
        if [ -n "$runner" ]; then
            apple_runner storybook_headful_macos_test "$out" ISOMER_MAC_APP="$app" \
                ISOMER_BUNDLE_ID=com.LoganShire.IsomerStorybook ISOMER_HEADFUL_LAUNCHER="$ROOT/drive/launchers/macos_launcher.sh"
        else
            run storybook_headful_macos_test "$out" --test_env=ISOMER_MAC_APP="$app"
        fi
        # The driver probe's tests on the Mac, when CI's container built the
        # Mac's probe and its runner: the Mac's accessibility driver's checks.
        probe="$(dirname "$ipa")/probe"
        probe_zip="$(ls "$probe"/*.zip 2> /dev/null | head -1)"
        if [ -f "$probe/driver_probe_headful_apple_runner" ] && [ -n "$probe_zip" ]; then
            ditto -x -k "$probe_zip" "$work/probe-mac" || exit 1
            runner="$probe/driver_probe_headful_apple_runner" apple_runner driver_probe_headful_macos_test "$out" \
                ISOMER_MAC_APP="$(ls -d "$work/probe-mac/"*.app | head -1)" \
                ISOMER_BUNDLE_ID=com.LoganShire.IsomerExamples.DriverProbe \
                ISOMER_HEADFUL_LAUNCHER="$ROOT/drive/launchers/macos_launcher.sh"
        fi
    fi
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
    # The job's phone (an emulator or Waydroid's) if one is up already (the picture tests leave theirs
    # running), else one booted here.
    serial="$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
    if [ -z "$serial" ]; then
        "$ROOT/tools/ci/hosted_android_emulator.sh" "$out/emulator.log" "$work/serial" < /dev/null > /dev/null || exit 1
        serial="$(cat "$work/serial")"
    fi
    "$adb" -s "$serial" install -r "$apk" > /dev/null || exit 1
    run storybook_headful_android_test "$out" --test_env=ADB="$adb" --test_env=ANDROID_SERIAL="$serial"
    ;;
windows)
    dir="$(cd "${1:?<the windows-headful folder>}" && pwd)"
    mkdir -p "${2:?<out>}"
    out="$(cd "$2" && pwd)"
    # Paths as Windows writes them with forward slashes (C:/...): MSYS would
    # rewrite a /c/... path in the environment of the native test, which
    # hands it back to bash in the launcher.
    mixed() { cygpath -m "$1"; }
    test="$(ls "$dir"/*storybook_headful_windows_test*.exe | head -1)"
    app="$(ls "$dir"/storybook_windows_application*.exe | head -1)"
    [ -f "$test" ] && [ -f "$app" ] || { echo "hosted_headful_test: no test or app in $dir" >&2; exit 1; }
    mkdir -p "$out/storybook_headful_windows_test"
    (cd "$dir" && env ISOMER_HEADFUL_LAUNCHER="$(mixed "$dir/windows_launcher.sh")" \
        ISOMER_WINDOWS_APP="$(mixed "$app")" ISOMER_BASH="$(cygpath -w "$(command -v bash)")" \
        TEST_UNDECLARED_OUTPUTS_DIR="$(mixed "$out/storybook_headful_windows_test")" \
        "$test" > "$out/storybook_headful_windows_test/test.log" 2>&1)
    status=$?
    cat "$out/storybook_headful_windows_test/test.log"
    [ "$status" -eq 0 ] || failures=$((failures + 1))
    ;;
*)
    echo "hosted_headful_test: apple, android or windows, not $platform" >&2
    exit 2
    ;;
esac
echo "hosted_headful_test: $platform: $failures failed"
[ "$failures" -eq 0 ]
