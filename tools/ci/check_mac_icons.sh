#!/bin/bash
# Every Mac app among a folder's zips has icons in the dark appearance
# (NSAppearanceNameDarkAqua, by `assetutil --info` of its Assets.car), or
# this fails and nothing is published: a flat icon, with no dark or tinted
# appearance, is never published. The apps are built on Linux with
# rules_applecross, whose actool compiles an Icon Composer icon's layers and
# appearances as Xcode does (examples/.bazelrc's apple_on_linux accepts its
# flattened images, which aren't Xcode's); this checks what it made with
# Xcode's assetutil on a Mac, and in CI's Linux containers by the
# appearance names the catalog stores (no Mac needed).
# The Storybook's Mac app has an Icon Composer icon. Copied from AttilaTheFun/reviews' tools/ci/check_mac_icons.sh.
#
#   tools/ci/check_mac_icons.sh <dir>
set -euo pipefail
dir="${1:?usage: tools/ci/check_mac_icons.sh <dir>}"
work="$(mktemp -d)"

trap 'rm -rf "$work"' EXIT
status=0
zips=0
# A Mac's Xcode reads the asset catalog (assetutil); elsewhere (CI's Linux
# containers) the catalog's appearance names are read as they are stored,
# plain strings in Assets.car: a flat icon has no NSAppearanceNameDarkAqua.
if [ "$(uname -s)" = Darwin ]; then
    dark_renditions() { xcrun --sdk macosx assetutil --info "$1" | grep -c NSAppearanceNameDarkAqua; }
    unpack() { ditto -x -k "$1" "$2"; }
else
    dark_renditions() { LC_ALL=C grep -a -c NSAppearanceNameDarkAqua "$1"; }
    # unzip, or Python's where an image has none (only Assets.car is read).
    unpack() { if command -v unzip > /dev/null; then unzip -q -o "$1" -d "$2"; else python3 -m zipfile -e "$1" "$2"; fi; }
fi

for zip in "$dir"/*.zip; do
    [ -e "$zip" ] || continue
    zips=$((zips + 1))
    rm -rf "$work/unzipped" && mkdir "$work/unzipped"
    unpack "$zip" "$work/unzipped"
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
        dark="$(dark_renditions "$car")" || true
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
