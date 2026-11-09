#!/bin/bash
# The iPhone Storybook, headful, for StorybookHeadlessTests: the app (built
# with --@isomer//drive:headful, so its accessibility driver dials out) on a
# booted simulator, launched with ISO_DRIVER and ISO_DRIVER_NAME (simctl's
# SIMCTL_CHILD_), until this is stopped.
#
#   ios_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_SIMULATOR (a booted simulator's UDID)
# and ISOMER_BUNDLE_ID (the app installed on it; the Storybook's by default).
# ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT are the headless window's, not a
# phone's: left out.
set -euo pipefail
url="${1:?usage: ios_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
udid="${ISOMER_SIMULATOR:?ISOMER_SIMULATOR: a booted simulator}"
bundle="${ISOMER_BUNDLE_ID:-com.LoganShire.IsomerStorybook}"
environment=(SIMCTL_CHILD_ISO_DRIVER="$url" SIMCTL_CHILD_ISO_DRIVER_NAME="$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("SIMCTL_CHILD_$pair") ;;
    esac
done
stop() { xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true; exit 0; }
trap stop TERM INT
env "${environment[@]}" xcrun simctl launch --terminate-running-process "$udid" "$bundle" > /dev/null
# The app runs until the test stops this.
while true; do sleep 1; done
