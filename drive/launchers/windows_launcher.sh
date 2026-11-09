#!/bin/bash
# A Windows app (DirectX), headful, for a test's HeadlessApp (docs/drive.md):
# built with --@isomer//drive:headful, run with ISO_DRIVER and
# ISO_DRIVER_NAME in its environment (Git's bash on a Windows machine:
# GitHub's windows-11-arm), until this is stopped. Windows has no SIGTERM
# for HeadlessApp to send, so it also stops at a file named `stop` in
# ISOMER_LAUNCHER_REQUESTS (HeadlessApp's quit). No pictures yet (a test's
# `picture` gets none).
#
#   windows_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_WINDOWS_APP, the app's .exe, with the
# Swift runtime's DLLs beside it and the Storybook's assets in `assets`
# there (tools/ci/container_build.sh's packaging), which the app reads
# through a runfiles manifest made here, as tools/ci/hosted_windows_test.ps1
# makes one.
set -uo pipefail
url="${1:?usage: windows_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_WINDOWS_APP:?ISOMER_WINDOWS_APP: the Windows app}"
# The app's folder as Windows names it (C:/…), for the manifest.
dir="$(cd "$(dirname "$app")" && { pwd -W 2> /dev/null || pwd; })"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
if [ -d "$(dirname "$app")/assets" ] && [ -z "${RUNFILES_MANIFEST_FILE:-}" ]; then
    manifest="$(mktemp)"
    (cd "$(dirname "$app")" && find assets -type f -name '*.png') | while read -r relative; do
        printf 'storybook/%s %s/%s\n' "$relative" "$dir" "$relative"
    done > "$manifest"
    environment+=(RUNFILES_MANIFEST_FILE="$(cygpath -w "$manifest" 2> /dev/null || echo "$manifest")")
fi
log="${TEST_UNDECLARED_OUTPUTS_DIR:-${TEMP:-/tmp}}/$name.log"
(cd "$(dirname "$app")" && exec env "${environment[@]}" "$app") > "$log" 2>&1 &
pid=$!
stop() {
    kill "$pid" 2> /dev/null
    taskkill //F //IM "$(basename "$app")" > /dev/null 2>&1
    exit 0
}
trap stop TERM INT
while kill -0 "$pid" 2> /dev/null; do
    [ -n "${ISOMER_LAUNCHER_REQUESTS:-}" ] && [ -e "$ISOMER_LAUNCHER_REQUESTS/stop" ] && stop
    # A picture asked for is answered with none, for now.
    if [ -n "${ISOMER_LAUNCHER_REQUESTS:-}" ]; then
        for request in "$ISOMER_LAUNCHER_REQUESTS"/*.request; do
            [ -e "$request" ] && rm -f "$request"
        done
    fi
    sleep 0.2
done
