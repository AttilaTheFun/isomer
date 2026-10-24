#!/bin/bash
# Launches the example application on every platform at once:
#   1. macOS native app          2. iOS simulator
#   3. Android emulator          4. Electron desktop shell (web)
# Usage: bazel run //shared/example_application:run_all
set -euo pipefail

RUNFILES_ROOT="$PWD/.."
# $1/$2 are the app targets' runner executables; the archives sit next to
# them in runfiles with the platform extension appended.
MACOS_ZIP="$RUNFILES_ROOT/$1.zip"
IOS_IPA="$RUNFILES_ROOT/$2.ipa"
APK="$RUNFILES_ROOT/$3"
ADB="$RUNFILES_ROOT/$4"
EMULATOR_SH="$RUNFILES_ROOT/$5"
EMULATOR_BIN="$6"   # rlocationpath, consumed by EMULATOR_SH
SYSIMG="$7"         # rlocationpath, consumed by EMULATOR_SH
ADB_RLOCATION="$8"  # rlocationpath, consumed by EMULATOR_SH
ELECTRON="$(cat "$RUNFILES_ROOT/$9")"
ELECTRON_APP_DIR="$RUNFILES_ROOT/$(dirname "${10}")"
SITE_DIR="$RUNFILES_ROOT/${11}"

WORK=$(mktemp -d -t isomer_run_all)
note() { printf '\033[1m[run_all]\033[0m %s\n' "$*"; }

# ---------------------------------------------------------------- macOS
note "macOS: launching native app"
unzip -qo "$MACOS_ZIP" -d "$WORK/macos"
open "$WORK/macos/"*.app

# ------------------------------------------------------------------ iOS
(
  unzip -qo "$IOS_IPA" -d "$WORK/ios"
  APP_DIR=$(echo "$WORK/ios/Payload/"*.app)
  UDID=$(xcrun simctl list devices booted | grep -Eo '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1 || true)
  if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices available | grep "iPhone" | grep -Eo '[0-9A-F]{8}-[0-9A-F-]{27}' | head -1)
    note "iOS: booting simulator $UDID"
    xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
  fi
  open -a Simulator
  xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
  xcrun simctl install "$UDID" "$APP_DIR"
  xcrun simctl launch "$UDID" dev.isomer.example >/dev/null
  note "iOS: launched in simulator $UDID"
) &
IOS_PID=$!

# -------------------------------------------------------------- Android
(
  "$ADB" start-server >/dev/null 2>&1 || true
  if ! "$ADB" devices | awk 'NR>1 && $2 == "device"' | grep -q .; then
    note "Android: booting hermetic emulator (log: $WORK/emulator.log)"
    "$EMULATOR_SH" "$EMULATOR_BIN" "$SYSIMG" "$ADB_RLOCATION" >"$WORK/emulator.log" 2>&1 &
    "$ADB" wait-for-device
    for _ in $(seq 1 120); do
      if [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ]; then break; fi
      sleep 2
    done
  fi
  "$ADB" install -r "$APK" >/dev/null
  "$ADB" shell am start -n com.LoganShire.IsomerStorybook/.MainActivity >/dev/null
  note "Android: launched on $("$ADB" devices | awk 'NR==2{print $1}')"
) &
ANDROID_PID=$!

# ------------------------------------------------------------- Electron
note "Electron: launching desktop shell"
ISO_SITE_DIR="$SITE_DIR" "$ELECTRON" "$ELECTRON_APP_DIR" >/dev/null 2>&1 &
ELECTRON_PID=$!

wait "$IOS_PID" "$ANDROID_PID" || true
note "All platforms are up. Ctrl-C to stop (simulator/emulator keep running)."
wait "$ELECTRON_PID" || true
