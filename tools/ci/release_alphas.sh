#!/bin/bash
# A published release's Alphas, for its job to promote (sign_from_ci.sh
# --promote): the .ipa and Mac .zip files its proposal attached, as its
# builds.json lists them, downloaded into <dir>. Only Alphas of the
# release's own commit are taken: the builds the owner tested. Fails,
# saying so, when the release has none (a release proposed before the move
# to Shireworks' signing: docs/RELEASE_ASSETS.md, "Re-propose").
#
#   tools/ci/release_alphas.sh <tag> <dir>
#
# From the job's environment: GH_TOKEN, the job's; GITHUB_REPOSITORY and
# GITHUB_SHA (the tag's commit). bash, python3 and gh (gh_ready.sh, beside
# this file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tag="${1:?usage: tools/ci/release_alphas.sh <tag> <dir>}"
dir="${2:?usage: tools/ci/release_alphas.sh <tag> <dir>}"
repo="${GITHUB_REPOSITORY:?}"
commit="${GITHUB_SHA:?}"
: "${GH_TOKEN:?GH_TOKEN, the job token}"
fail() { echo "release_alphas: $*" >&2; exit 1; }
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

mkdir -p "$dir"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh release download "$tag" --repo "$repo" --pattern builds.json --dir "$work" || fail "$tag has no builds.json"
# The files to promote: the Alphas of this commit, an .ipa or a Mac .zip.
python3 -I - "$work/builds.json" "$commit" > "$work/files" << 'PY' || fail "$tag's builds.json was not read"
import json, sys
for build in json.load(open(sys.argv[1])):
    name = build.get("file", "")
    if build.get("variant") == "Alpha" and build.get("commit") == sys.argv[2] and name.endswith((".ipa", ".zip")) and "/" not in name:
        print(name)
PY
[ -s "$work/files" ] || fail "$tag has no Alphas of $commit to promote: propose it again from main (run: release)"
while IFS= read -r file; do
  gh release download "$tag" --repo "$repo" --pattern "$file" --dir "$dir" --clobber || fail "$file was not downloaded"
  echo "release_alphas: $file"
done < "$work/files"
