#!/bin/bash
# One-command launcher: build the iOS app for the simulator, boot a simulator,
# install, and launch it already connected to the hot-reload server. This
# exists because `bazel run` of an ios_application can't inject the
# ISO_HOT_RELOAD_SERVER env into the app - only `simctl launch` can (via
# SIMCTL_CHILD_*), which is what this does.
#
# Usage (from `bazel run //...:run`):
#   bazel run //apple/example_partial_wasm_ios_application:run
# Point at a non-default server with ISO_HOT_RELOAD_SERVER=... bazel run ...:run
set -euo pipefail

: "${BUILD_WORKSPACE_DIRECTORY:?run via 'bazel run', not directly}"
cd "$BUILD_WORKSPACE_DIRECTORY"

SERVER="${ISO_HOT_RELOAD_SERVER:-http://localhost:8787}"
IOS="//apple/example_partial_wasm_ios_application:example_partial_wasm_ios_application"
BUNDLE_ID="com.LoganShire.Isomer.WasmView"

echo "==> Building the iOS app for the simulator..."
bazel build "$IOS" --ios_multi_cpus=sim_arm64
# Resolve the .ipa under bazel-out directly (the bazel-bin convenience symlink
# points at whatever config built last, which may not be ios-sim).
IPA="$(bazel cquery --output=files "$IOS" --ios_multi_cpus=sim_arm64 2>/dev/null | grep '\.ipa$' | head -1)"
[ -n "$IPA" ] || { echo "could not locate built .ipa"; exit 1; }

# Reuse a booted simulator if there is one, else boot the first available iPhone.
DEV="$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)"
if [ -z "$DEV" ]; then
    DEV="$(xcrun simctl list devices available | grep -E '    iPhone' | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')"
    echo "==> Booting simulator $DEV..."
    xcrun simctl boot "$DEV"
fi
open -a Simulator

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
unzip -oq "$IPA" -d "$STAGE"
APP="$(find "$STAGE/Payload" -maxdepth 1 -name '*.app' | head -1)"

echo "==> Installing..."
xcrun simctl install "$DEV" "$APP"
xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Launching, connected to $SERVER"
echo "    (start the server in another shell: bazel run //apple/example_partial_wasm_ios_application:hot_reload_server)"
SIMCTL_CHILD_ISO_HOT_RELOAD_SERVER="$SERVER" xcrun simctl launch "$DEV" "$BUNDLE_ID"
