#!/bin/bash
# The cross-platform hot-reload demo, one command:
#
#   bazel run //shared/hot_reload_demo
#
# Boots the iOS simulator AND the hermetic Android emulator, builds + installs
# the embedded-wasm-feature app on both, starts the hot-reload server, and
# launches both apps connected to it. Then:
#
#     edit wasm/hot_demo_feature/HotDemo.swift and save
#
# — both apps re-render the feature live (~10-15s: bazel rebuild + swap; the
# native hosts never restart). Ctrl-C stops the server; apps stay up.
#
# The Android connection uses `adb reverse` (device localhost -> host 8787),
# which works identically on the emulator and a USB-attached physical device —
# plug in a phone, pass its serial as ANDROID_SERIAL, same demo.
set -euo pipefail

# Run via `bazel run` — the demo drives bazel itself (app builds + the
# server's rebuild loop), so it works out of the workspace, not runfiles.
: "${BUILD_WORKSPACE_DIRECTORY:?run via 'bazel run //shared/hot_reload_demo'}"
cd "$BUILD_WORKSPACE_DIRECTORY"
# The simulator to run on (`xcrun simctl list devices`): yours, by its UDID.
SIM_UDID="${SIM_UDID:?set SIM_UDID to the UDID of a simulator, from xcrun simctl list devices}"
PORT="${ISO_HOT_RELOAD_PORT:-8787}"
IOS_BUNDLE_ID="com.LoganShire.Isomer.WasmView"
ANDROID_PKG="dev.isomer.wasmexample"

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }

step "Building both apps + the server"
IOS_FLAGS=(--ios_multi_cpus=sim_arm64)
bazel build \
    //apple/example_partial_wasm_ios_application "${IOS_FLAGS[@]}"
bazel build \
    //android/example_partial_wasm_android_application \
    //apple/example_partial_wasm_macos_application:hot_reload_server

step "Booting devices"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
ADB=$(find ~/Library/Caches/bazel/_bazel_*/cache/repos -path '*platform-tools/darwin/adb' 2>/dev/null | head -1)
adbd() { "$ADB" ${ANDROID_SERIAL:+-s "$ANDROID_SERIAL"} "$@"; }
if ! adbd get-state >/dev/null 2>&1; then
    # This is a watch-it-live demo, so the emulator launches WITH a window —
    # you want to see the Android app re-render alongside the simulator. Set
    # HEADLESS=1 for an unattended run (CI, or a machine with no display).
    echo "    (no Android device — starting the hermetic emulator${HEADLESS:+ headless})"
    bazel run //tools/android/emulator -- ${HEADLESS:+-no-window} >/dev/null 2>&1 &
fi
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null 2>&1
until adbd shell getprop sys.boot_completed 2>/dev/null | grep -q 1; do
    sleep 3
done

step "Installing"
IPA=$(bazel cquery --output=files \
    //apple/example_partial_wasm_ios_application "${IOS_FLAGS[@]}" \
    2>/dev/null | grep '\.ipa$' | head -1)
STAGE=$(mktemp -d)
unzip -qo "$IPA" -d "$STAGE"
xcrun simctl install "$SIM_UDID" "$(find "$STAGE" -name '*.app' -maxdepth 3 | head -1)"
# The SIGNED apk (zipaligned_* is the unsigned intermediate — installs no-op).
adbd install -r \
    bazel-bin/android/example_partial_wasm_android_application/example_partial_wasm_android_application_apk.apk

step "Starting the hot-reload server on :$PORT"
BUILD_WORKSPACE_DIRECTORY="$PWD" ISO_HOT_RELOAD_PORT="$PORT" \
    bazel-bin/apple/example_partial_wasm_macos_application/hot_reload_server &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT
until curl -s -m 2 "http://localhost:$PORT/version" >/dev/null 2>&1; do sleep 2; done

step "Launching both apps"
SIMCTL_CHILD_ISO_HOT_RELOAD_SERVER="http://localhost:$PORT" \
    xcrun simctl launch "$SIM_UDID" "$IOS_BUNDLE_ID"
open -a Simulator 2>/dev/null || true
adbd reverse "tcp:$PORT" "tcp:$PORT"
adbd shell am start -n "$ANDROID_PKG/.MainActivity" \
    --es hotReloadServer "http://localhost:$PORT"

step "READY — edit wasm/hot_demo_feature/HotDemo.swift and save"
echo "    Both apps re-render live. Ctrl-C stops the server."
wait $SERVER_PID
