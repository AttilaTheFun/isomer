#!/bin/bash
# An Android app, headful, for a test's HeadlessApp (docs/drive.md): built
# with --@isomer//drive:headful, on an emulator or device adb reaches,
# started with ISO_DRIVER and ISO_DRIVER_NAME as its intent's ISO_ extras
# (its environment), until this is stopped. The hub listens on this
# machine's loopback, so its port is reversed onto the device first.
# Pictures (a test's `picture`) are adb's screencap.
#
#   android_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_ANDROID_PACKAGE (the app),
# ISOMER_ANDROID_ACTIVITY (.MainActivity, isomer_android_app's, by
# default), ADB (adb; the PATH's by default), ANDROID_SERIAL (which device,
# when several).
set -uo pipefail
. "$(dirname "$0")/requests.sh"
url="${1:?usage: android_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
adb="${ADB:-adb}"
package="${ISOMER_ANDROID_PACKAGE:?ISOMER_ANDROID_PACKAGE: the app}"
activity="${ISOMER_ANDROID_ACTIVITY:-.MainActivity}"
port="${url##*:}"
port="${port%%/*}"
"$adb" reverse "tcp:$port" "tcp:$port" > /dev/null || exit 1
extras=(-e ISO_DRIVER "$url" -e ISO_DRIVER_NAME "$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) extras+=(-e "${pair%%=*}" "${pair#*=}") ;;
    esac
done
# The device's log since the launch, kept with the test's outputs when this
# stops (an app that never attached says why there).
logs="${TEST_UNDECLARED_OUTPUTS_DIR:-}"
stop() {
    [ -z "$logs" ] || "$adb" logcat -d > "$logs/$name.logcat" 2> /dev/null
    "$adb" shell am force-stop "$package" > /dev/null 2>&1 || true
    exit 0
}
trap stop TERM INT
"$adb" shell am force-stop "$package" > /dev/null 2>&1 || true
"$adb" logcat -c > /dev/null 2>&1 || true
"$adb" shell am start -W -n "$package/$activity" "${extras[@]}" > /dev/null || exit 1
take() { "$adb" exec-out screencap -p > "$1" && [ -s "$1" ]; }
serve_requests take
