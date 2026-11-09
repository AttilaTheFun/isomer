#!/bin/bash
# The Android Storybook, headful, for StorybookHeadlessTests: the app (built
# with --@isomer//drive:headful) on an emulator or device adb reaches,
# started with ISO_DRIVER and ISO_DRIVER_NAME as its intent's ISO_ extras
# (its environment), until this is stopped. The hub listens on this
# machine's loopback, so its port is reversed onto the device first.
#
#   android_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ADB (adb; the PATH's by default),
# ANDROID_SERIAL (which device, when several), ISOMER_ANDROID_PACKAGE (the
# Storybook's by default).
set -euo pipefail
url="${1:?usage: android_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
adb="${ADB:-adb}"
package="${ISOMER_ANDROID_PACKAGE:-com.LoganShire.IsomerStorybook}"
port="${url##*:}"
port="${port%%/*}"
"$adb" reverse "tcp:$port" "tcp:$port" > /dev/null
extras=(-e ISO_DRIVER "$url" -e ISO_DRIVER_NAME "$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) extras+=(-e "${pair%%=*}" "${pair#*=}") ;;
    esac
done
stop() { "$adb" shell am force-stop "$package" > /dev/null 2>&1 || true; exit 0; }
trap stop TERM INT
"$adb" shell am force-stop "$package" > /dev/null 2>&1 || true
"$adb" shell am start -W -n "$package/.MainActivity" "${extras[@]}" > /dev/null
while true; do sleep 1; done
