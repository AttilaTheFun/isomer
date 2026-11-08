#!/bin/bash
# Every Mac app among a folder's zips has icons in the dark appearance
# (NSAppearanceNameDarkAqua, by `assetutil --info` of its Assets.car), or
# this fails and nothing is published: a flat icon, with no dark or tinted
# appearance, is never published. The apps are built on Linux with
# rules_applecross, whose actool compiles an Icon Composer icon's layers and
# appearances as Xcode does (examples/.bazelrc's apple_on_linux accepts its
# flattened images, which aren't Xcode's); this checks what it made with
# Xcode's assetutil: on a Mac, there; elsewhere (CI's Linux containers, the
# isomer-jit runners), on a slot of OS Server's primary Mac
# (tools/ci/mac_slot.sh), where this same script runs on the zips, sent up.
# The Storybook's Mac app has an Icon Composer icon. Copied from AttilaTheFun/reviews' tools/ci/check_mac_icons.sh.
#
#   tools/ci/check_mac_icons.sh <dir>
set -euo pipefail
dir="${1:?usage: tools/ci/check_mac_icons.sh <dir>}"
work="$(mktemp -d)"

if [ "$(uname -s)" != Darwin ]; then
    ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
    OSS="$(command -v oss)" || { echo "::error::check_mac_icons: no Mac here and no oss to lease a slot of one"; exit 1; }
    . "$ROOT/tools/ci/mac_slot.sh"
    trap 'status=$?; mac_slot_release; rm -rf "$work"; exit $status' EXIT
    zips=("$dir"/*.zip)
    [ -e "${zips[0]}" ] || { echo "::error::no zip in $dir"; exit 1; }
    mac_slot_lease
    mac_slot_upload "$0" ci/icons/check_mac_icons.sh
    for zip in "${zips[@]}"; do mac_slot_upload "$zip" "ci/icons/zips/$(basename "$zip")"; done
    mac_slot_exec /bin/bash ci/icons/check_mac_icons.sh ci/icons/zips
    exit
fi

trap 'rm -rf "$work"' EXIT
status=0
zips=0
for zip in "$dir"/*.zip; do
    [ -e "$zip" ] || continue
    zips=$((zips + 1))
    rm -rf "$work/unzipped" && mkdir "$work/unzipped"
    ditto -x -k "$zip" "$work/unzipped"
    apps=0
    for app in "$work/unzipped"/*.app; do
        [ -e "$app" ] || continue
        apps=$((apps + 1))
        name="$(basename "$app")"
        car="$app/Contents/Resources/Assets.car"
        if [ ! -f "$car" ]; then
            echo "::error::$name has no Assets.car: no icon compiled by actool"
            status=1
            continue
        fi
        dark="$(xcrun --sdk macosx assetutil --info "$car" | grep -c NSAppearanceNameDarkAqua)" || true
        if [ "${dark:-0}" -gt 0 ]; then
            echo "$name: $dark renditions in the dark appearance (NSAppearanceNameDarkAqua)"
        else
            echo "::error::$name's icon has no dark appearance (no NSAppearanceNameDarkAqua in its Assets.car): a flat icon"
            status=1
        fi
    done
    if [ "$apps" -eq 0 ]; then
        echo "::error::$(basename "$zip") holds no Mac app"
        status=1
    fi
done
[ "$zips" -gt 0 ] || { echo "::error::no zip in $dir"; status=1; }
exit "$status"
