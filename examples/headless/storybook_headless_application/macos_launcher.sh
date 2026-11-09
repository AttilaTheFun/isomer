#!/bin/bash
# The Mac Storybook, headful, for StorybookHeadlessTests: the app (built
# with --@isomer//drive:headful, so its accessibility driver dials out) run
# with ISO_DRIVER and ISO_DRIVER_NAME in its environment, light and with its
# own home, until this is stopped.
#
#   macos_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_MAC_APP, the .app.
set -euo pipefail
url="${1:?usage: macos_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_MAC_APP:?ISOMER_MAC_APP: the Mac app}"
binary="$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
home="$(mktemp -d)"
env "${environment[@]}" CFFIXED_USER_HOME="$home" "$binary" -AppleInterfaceStyle Light \
    -ApplePersistenceIgnoreState YES > "$home/app.log" 2>&1 &
pid=$!
stop() { kill "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true; rm -rf "$home"; exit 0; }
trap stop TERM INT
wait "$pid"
