#!/bin/bash
# Build the Playground with the EMBEDDED compiler for a physical iPhone and
# install it. It does NOT launch the app unless asked: on a phone that is a
# person's own, an agent installs and stops (AGENTS.md). Needs the builder's
# team (ISOMER_TEAM_ID in .bazelrc.user, tools/signing) and its wildcard
# development profile (tools/playground_toolchain/mint_profile makes it on a
# new Mac; it lasts a year). Usage (from playground/, this module's root):
#   [DEVICE=<udid>] apple/playground_ios_application/install_device.sh [launch | autorun=native|nativex2|safari]
# DEVICE picks the phone when more than one is paired (else the first one).
# `launch` starts the app after installing; `autorun=…` starts it with the
# headless hook and streams its console. Both only when the phone's owner
# asks for it.
set -euo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:-}"
AUTORUN=""
case "$MODE" in autorun=*) AUTORUN="${MODE#autorun=}";; esac
# Physical phones list as "available (paired)"; simulators also appear here
# (as "connected") and must NOT be picked — a device build won't install there.
DEV="${DEVICE:-}"
[ -n "$DEV" ] || DEV="$(xcrun devicectl list devices 2>/dev/null | grep -E 'available \(paired\)|connected  ' | grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1 || true)"
[ -n "$DEV" ] || { echo "no connected iPhone (xcrun devicectl list devices)"; exit 1; }
FLAGS=(--ios_multi_cpus=arm64 --define iso_playground_embedded=1 -c opt)
bazel build //apple/playground_ios_application "${FLAGS[@]}"
IPA="$(bazel cquery --output=files //apple/playground_ios_application "${FLAGS[@]}" 2>/dev/null | grep -E '\.ipa$' | head -1)"
xcrun devicectl device install app --device "$DEV" "$IPA"
BUNDLE=com.LoganShire.Playground
xcrun devicectl device info apps --device "$DEV" 2>/dev/null | grep "$BUNDLE" || true
[ -n "$MODE" ] || exit 0
# The first launch after an install is sometimes refused while the device
# finishes verifying the bundle; retry once.
if [ -n "$AUTORUN" ]; then
    export DEVICECTL_CHILD_ISO_PLAYGROUND_AUTORUN="$AUTORUN"
    xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$BUNDLE" \
        || { sleep 5; xcrun devicectl device process launch --device "$DEV" --terminate-existing --console "$BUNDLE"; }
else
    xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE" \
        || { sleep 5; xcrun devicectl device process launch --device "$DEV" --terminate-existing "$BUNDLE"; }
fi
