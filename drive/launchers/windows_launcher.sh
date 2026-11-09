#!/bin/bash
# A Windows app (DirectX), headful, for a test's HeadlessApp (docs/drive.md):
# built with --@isomer//drive:headful, run with ISO_DRIVER and
# ISO_DRIVER_NAME in its environment (Git's bash on a Windows machine:
# GitHub's windows-11-arm), until this is stopped. No pictures yet (a test's
# `picture` gets none).
#
#   windows_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_WINDOWS_APP, the app's .exe.
set -uo pipefail
url="${1:?usage: windows_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_WINDOWS_APP:?ISOMER_WINDOWS_APP: the Windows app}"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name")
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
env "${environment[@]}" "$app" > "${TEST_UNDECLARED_OUTPUTS_DIR:-${TEMP:-/tmp}}/$name.log" 2>&1 &
pid=$!
stop() { kill "$pid" 2> /dev/null || taskkill //F //PID "$pid" > /dev/null 2>&1 || true; exit 0; }
trap stop TERM INT
wait "$pid"
