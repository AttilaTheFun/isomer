#!/bin/bash
# A release's assets beyond its signed builds, from the Build workflow's
# `release` job (when the owner publishes a GitHub release: a v0.47.N tag on
# a main commit). The signed builds (<App>-<version>-<platform>.<ext> and
# builds.json, the Mac's disk image among them) are attached by
# attach_release.sh, as Applications reads them (the private
# AttilaTheFun/applications' docs/RELEASE_ASSETS.md); the site
# (isomer-site.tar.gz, which pages.yml deploys) by draft_release.sh. These
# are the rest:
#   - proof.tar.gz: its commit's proof (screens/, before/, diffs/,
#     proof.json: the `proof` artifact of the newest run of this workflow on
#     that commit), so that the next release's proof compares with it after
#     the artifact's 90 days (tools/ci/proof.sh);
#   - the iPhone app for the simulator (an ipa is a zip: unzip it and
#     `xcrun simctl install booted Payload/<App>.app`):
#     <App>-<version>-iOS-Simulator.zip. Until the apps are on the App
#     Store, whose production ipa then goes here instead.
#
#   tools/ci/release_extras.sh proof <tag> <dir>   # <dir>/proof.tar.gz, or fails: no release without its proof
#   tools/ci/release_extras.sh upload <tag> <dir>…  # each dir's simulator apps, named as above, onto the release
#
# With gh (installed when missing, as root or by sudo) and GH_TOKEN, the
# job's: `contents: write` for the upload, `actions: read` for the proof.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# gh, installed where the image lacks it.
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"
mode="${1:?usage: release_extras.sh proof <tag> <dir> | upload <tag> <dir>…}"
tag="${2:?<tag>}"
shift 2
repo="${GITHUB_REPOSITORY:-AttilaTheFun/isomer}"
version="${tag#v}"

if ! command -v gh > /dev/null; then
    root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends gh > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends gh > /dev/null; }
fi

case "$mode" in
proof)
    out="$(mkdir -p "${1:?<dir>}" && cd "$1" && pwd)"
    commit="$(git -C "$ROOT" rev-list -n 1 "$tag")"
    # The newest run of this workflow on the commit with a proof.
    run="$(gh api --paginate "repos/$repo/actions/artifacts?name=proof&per_page=100" \
        --jq ".artifacts[] | select(.expired | not) | select(.workflow_run.head_sha == \"$commit\") | .workflow_run.id" |
        sort -nr | head -1)"
    [ -n "$run" ] || { echo "::error::no proof of $tag's commit $commit (run the Build workflow on it by hand first)"; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    gh run download "$run" --repo "$repo" --name proof --dir "$work/proof"
    [ -f "$work/proof/proof.json" ] || { echo "::error::run $run's proof has no proof.json"; exit 1; }
    tar -czf "$out/proof.tar.gz" -C "$work/proof" .
    echo "release_extras: $tag's proof from run $run, $(ls "$work/proof/screens" | wc -l | tr -d ' ') pictures"
    ;;
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
                proof.tar.gz) asset="$name" ;;
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
    echo "usage: release_extras.sh proof <tag> <dir> | upload <tag> <dir>…" >&2
    exit 1
    ;;
esac
