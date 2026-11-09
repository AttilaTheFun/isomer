#!/bin/bash
# A release's assets beyond its signed builds and its proof, from the Build
# workflow's `release` job (when the owner publishes a GitHub release: a
# v0.48.N tag on a main commit). The signed builds (<App>-<version>-<platform>.<ext>
# and builds.json, the Mac's disk image among them) are attached by
# attach_release.sh, as Applications reads them (the private
# AttilaTheFun/applications' docs/RELEASE_ASSETS.md); the proof (proof.zip,
# Reviews' format 2) and the site (isomer-site.tar.gz, which pages.yml
# deploys) by the proposal, to its draft. This attaches the rest: the
# iPhone app for the simulator (an ipa is a zip: unzip it and `xcrun simctl
# install booted Payload/<App>.app`), <App>-<version>-iOS-Simulator.zip,
# until the apps are on the App Store.
#
#   tools/ci/release_extras.sh upload <tag> <dir>…  # each dir's simulator apps, named as above, onto the release
#
# With gh (installed when missing, as root or by sudo) and GH_TOKEN, the
# job's: `contents: write` for the upload.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# gh, installed where the image lacks it.
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"
mode="${1:?usage: release_extras.sh upload <tag> <dir>…}"
tag="${2:?<tag>}"
shift 2
repo="${GITHUB_REPOSITORY:-AttilaTheFun/isomer}"
version="${tag#v}"

case "$mode" in
upload)
    [ $# -gt 0 ] || { echo "release_extras: upload takes the folders" >&2; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    app() {
        case "$1" in
            *storybook*) echo Storybook ;;
            *) echo "" ;;
        esac
    }
    assets=()
    for dir in "$@"; do
        for file in "$dir"/*; do
            [ -f "$file" ] || continue
            name="$(basename "$file")"
            lower="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
            case "$name" in
                *_sim_application.ipa) asset="$(app "$lower")-$version-iOS-Simulator.zip" ;;
                *) echo "release_extras: $name isn't a release's asset, left out"; continue ;;
            esac
            case "$asset" in -*) echo "::error::$name: which app?"; exit 1 ;; esac
            cp "$file" "$work/$asset"
            assets+=("$work/$asset")
        done
    done
    [ ${#assets[@]} -gt 0 ] || { echo "::error::no assets"; exit 1; }
    gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
    for asset in "${assets[@]}"; do echo "release_extras: $tag: $(basename "$asset")"; done
    ;;
*)
    echo "usage: release_extras.sh upload <tag> <dir>…" >&2
    exit 1
    ;;
esac
