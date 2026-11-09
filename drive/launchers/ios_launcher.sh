#!/bin/bash
# An iPhone app on a booted simulator, headful, for a test's HeadlessApp
# (docs/drive.md): built with --@isomer//drive:headful, so its driver dials
# out, launched with ISO_DRIVER and ISO_DRIVER_NAME (simctl's
# SIMCTL_CHILD_), until this is stopped. Pictures (a test's `picture`) are
# simctl's, masked (the simulator's own status bar is held at 9:41 by
# whoever made the simulator).
#
#   ios_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_SIMULATOR (a booted simulator's
# UDID) and ISOMER_BUNDLE_ID (the app installed on it). ISO_HEADLESS_WIDTH
# and ISO_HEADLESS_HEIGHT are a headless window's, not a phone's: left out.
set -uo pipefail
. "$(dirname "$0")/requests.sh"
url="${1:?usage: ios_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
udid="${ISOMER_SIMULATOR:?ISOMER_SIMULATOR: a booted simulator}"
bundle="${ISOMER_BUNDLE_ID:?ISOMER_BUNDLE_ID: the app installed on it}"
environment=(SIMCTL_CHILD_ISO_DRIVER="$url" SIMCTL_CHILD_ISO_DRIVER_NAME="$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("SIMCTL_CHILD_$pair") ;;
    esac
done
stop() { xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true; exit 0; }
trap stop TERM INT
env "${environment[@]}" xcrun simctl launch --terminate-running-process "$udid" "$bundle" > /dev/null || exit 1
take() { xcrun simctl io "$udid" screenshot --mask=black "$1" > /dev/null 2>&1; }
serve_requests take
