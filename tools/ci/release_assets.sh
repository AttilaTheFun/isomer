#!/bin/bash
# A release's assets, from the Build workflow's `release` job (when the
# owner publishes a GitHub release: a v0.40.N tag on a main commit), beside
# the source GitHub archives itself and the site (isomer-site.tar.gz,
# attached to the draft, which pages.yml deploys):
#   - proof.tar.gz: its commit's proof (screens/, before/, diffs/,
#     proof.json: the `proof` artifact of the newest run of this workflow on
#     that commit), so that the next release's proof compares with it after
#     the artifact's 90 days (tools/ci/proof.sh);
#   - the Mac apps' production disk images, made by promotion
#     (tools/ci/promote_from_ci.sh --dmg-dir): <App>-<version>.dmg;
#   - the Android apps, built for production: <App>-<version>.apk;
#   - the iPhone apps for the simulator (an ipa is a zip: unzip it and
#     `xcrun simctl install booted Payload/<App>.app`):
#     <App>-<version>-iOS-Simulator.zip. Until the apps are on the App
#     Store, whose production ipa then goes here instead.
#
#   tools/ci/release_assets.sh proof <tag> <dir>   # <dir>/proof.tar.gz, or fails: no release without its proof
#   tools/ci/release_assets.sh upload <tag> <dir>…  # each dir's packages, named as above, onto the release
#
# With gh (installed when missing, as root or by sudo) and GH_TOKEN, the
# job's: `contents: write` for the upload, `actions: read` for the proof.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
mode="${1:?usage: release_assets.sh proof <tag> <dir> | upload <tag> <dir>…}"
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
    echo "release_assets: $tag's proof from run $run, $(ls "$work/proof/screens" | wc -l | tr -d ' ') pictures"
    ;;
upload)
    [ $# -gt 0 ] || { echo "release_assets: upload takes the folders" >&2; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    app() {
        case "$1" in
            *storybook*) echo Storybook ;;
            *playground*) echo Playground ;;
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
                proof.tar.gz | *.dmg) asset="$name" ;;
                *.apk) asset="$(app "$lower")-$version.apk" ;;
                *_sim_application.ipa) asset="$(app "$lower")-$version-iOS-Simulator.zip" ;;
                *) echo "release_assets: $name isn't a release's asset, left out"; continue ;;
            esac
            case "$asset" in -*) echo "::error::$name: which app?"; exit 1 ;; esac
            cp "$file" "$work/$asset"
            assets+=("$work/$asset")
        done
    done
    [ ${#assets[@]} -gt 0 ] || { echo "::error::no assets"; exit 1; }
    gh release upload "$tag" --repo "$repo" --clobber "${assets[@]}"
    for asset in "${assets[@]}"; do echo "release_assets: $tag: $(basename "$asset")"; done
    ;;
*)
    echo "usage: release_assets.sh proof <tag> <dir> | upload <tag> <dir>…" >&2
    exit 1
    ;;
esac
