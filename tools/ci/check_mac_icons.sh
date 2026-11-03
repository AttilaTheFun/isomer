#!/bin/bash
# Every Mac app among a folder's zips has icons in the dark appearance
# (NSAppearanceNameDarkAqua, by `assetutil --info` of its Assets.car), or
# this fails and nothing is published: a flat icon, with no dark or tinted
# appearance, is never published. The apps are built on Linux with
# rules_applecross, whose actool compiles an Icon Composer icon's layers and
# appearances as Xcode does (examples/.bazelrc's apple_on_linux accepts its
# flattened images, which aren't Xcode's); this checks what it made, on the
# runner's Mac, which has Xcode's assetutil. The Storybook's and the
# Playground's Mac apps both have Icon Composer icons (their artwork's
# .icon). Copied from AttilaTheFun/reviews' tools/ci/check_mac_icons.sh.
#
#   tools/ci/check_mac_icons.sh <dir>
set -euo pipefail
dir="${1:?usage: tools/ci/check_mac_icons.sh <dir>}"
work="$(mktemp -d)"
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
