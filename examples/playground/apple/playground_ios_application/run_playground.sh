#!/bin/bash
# One-command Playground launcher: build for the simulator, boot, install,
# and launch with the HOST SwiftWasm toolchain paths injected via
# SIMCTL_CHILD_* — the simulator compile backend posix_spawns those binaries
# (a sim app is an unhardened macOS process). Usage:
#   bazel run //playground/apple/playground_ios_application:run
set -euo pipefail

: "${BUILD_WORKSPACE_DIRECTORY:?run via 'bazel run', not directly}"
cd "$BUILD_WORKSPACE_DIRECTORY"

APP="//playground/apple/playground_ios_application"
BUNDLE_ID="com.LoganShire.Isomer"

echo "==> Building the Playground app for the simulator..."
IOS_FLAGS=(--ios_multi_cpus=sim_arm64)
# The EMBEDDED toolchain (compiler linked INTO the app — the device backend,
# run identically on the sim) when staged via build_embedded_toolchain.sh.
if [ -d "$(dirname "$0")/embedded_toolchain/iphonesimulator/lib" ] || \
   [ -d apple/playground_ios_application/embedded_toolchain/iphonesimulator/lib ]; then
    echo "    (embedded toolchain staged - the app compiles fully in-process)"
    IOS_FLAGS+=(--define iso_playground_embedded=1)
fi
bazel build "$APP" "${IOS_FLAGS[@]}"
# Force-fetch the wasm toolchain repos (a cold cache would otherwise leave
# the paths below dangling) — cheap when cached.
bazel build //playground/apple/playground_ios_application:playground_sdk >/dev/null 2>&1 || true

OUTPUT_BASE="$(bazel info output_base)"
TOOLCHAIN_BIN="$OUTPUT_BASE/external/rules_swift++swift+swift_toolchain_xcode/usr/bin"
SDK_ROOT="$(find "$OUTPUT_BASE/external/rules_swift++swift+swift_toolchain_wasm_sdk_xcode" \
    -maxdepth 1 -name '*_wasm.artifactbundle' | head -1)"
WASM_DIR="$(find "$SDK_ROOT" -maxdepth 2 -name 'wasm32-unknown-wasip1' -type d | head -1)"
WASI_SDK="$WASM_DIR/WASI.sdk"
SWIFT_STATIC="$WASM_DIR/swift.xctoolchain/usr/lib/swift_static"
[ -x "$TOOLCHAIN_BIN/swiftc" ] || { echo "host swiftc not found at $TOOLCHAIN_BIN"; exit 1; }
[ -d "$WASI_SDK" ] || { echo "WASI.sdk not found under $SDK_ROOT"; exit 1; }

IPA="$(bazel cquery --output=files "$APP" "${IOS_FLAGS[@]}" 2>/dev/null | grep '\.ipa$' | head -1)"
[ -n "$IPA" ] || { echo "could not locate built .ipa"; exit 1; }

DEV="$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)"
if [ -z "$DEV" ]; then
    DEV="$(xcrun simctl list devices available | grep -E '    iPhone|    iPad' | head -1 | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}')"
    echo "==> Booting simulator $DEV..."
    xcrun simctl boot "$DEV"
fi
open -a Simulator 2>/dev/null || true

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
unzip -oq "$IPA" -d "$STAGE"
BUNDLE="$(find "$STAGE/Payload" -maxdepth 1 -name '*.app' | head -1)"

echo "==> Installing..."
xcrun simctl install "$DEV" "$BUNDLE"
# Some simctl builds silently keep the OLD app bundle when the version
# strings match (while still migrating the data container). Verify the
# installed binary is the one we just built; if not, uninstall (this resets
# the playground's saved files) and install fresh.
INSTALLED="$(xcrun simctl get_app_container "$DEV" "$BUNDLE_ID" app 2>/dev/null || true)"
if [ -n "$INSTALLED" ] && ! cmp -s "$BUNDLE/playground_ios_application" "$INSTALLED/playground_ios_application"; then
    echo "    (stale install detected - reinstalling; saved playground files reset)"
    xcrun simctl uninstall "$DEV" "$BUNDLE_ID"
    xcrun simctl install "$DEV" "$BUNDLE"
fi
xcrun simctl terminate "$DEV" "$BUNDLE_ID" >/dev/null 2>&1 || true

echo "==> Launching with the host toolchain at $TOOLCHAIN_BIN"
SIMCTL_CHILD_ISO_PLAYGROUND_TOOLCHAIN_BIN="$TOOLCHAIN_BIN" \
SIMCTL_CHILD_ISO_PLAYGROUND_WASI_SDK="$WASI_SDK" \
SIMCTL_CHILD_ISO_PLAYGROUND_SWIFT_STATIC="$SWIFT_STATIC" \
    xcrun simctl launch "$DEV" "$BUNDLE_ID"
