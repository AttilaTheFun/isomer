#!/bin/bash
# Attaches a folder of signed builds (publish_from_ci.sh's or
# promote_from_ci.sh's --download) to the repository's release `<tag>`, a
# draft or published: every file but builds.lines, builds.json last, so a
# reader that finds builds.json finds the files it names. An asset of the
# same name is replaced (a proposal run again on its commit). What
# Applications lists (the private AttilaTheFun/applications' docs/RELEASE_ASSETS.md).
#
#   tools/ci/attach_release.sh <tag> <dir>
#
# From the job's environment: GH_TOKEN, the job's, with `contents: write`;
# GITHUB_REPOSITORY. bash, curl and gh (gh_ready.sh, beside this file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
tag="${1:?usage: tools/ci/attach_release.sh <tag> <dir>}"
dir="${2:?usage: tools/ci/attach_release.sh <tag> <dir>}"
repo="${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?GH_TOKEN, the job token with contents: write}"
[ -f "$dir/builds.json" ] || { echo "attach_release: $dir has no builds.json" >&2; exit 1; }
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

# A draft has no tag yet: it is found by its tag's name among the releases.
# A draft just made may not be listed for a few seconds: asked again, up to
# a minute.
release=""
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
  release="$(gh api "repos/$repo/releases?per_page=100" --jq ".[] | select(.tag_name == \"$tag\") | .id" | head -1)"
  [ -z "$release" ] || break
  [ "$attempt" = 12 ] || sleep 5
done
[ -n "$release" ] || { echo "attach_release: no release $tag in $repo" >&2; exit 1; }

work="$(mktemp -d)"
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
# The token in a file, never on a command line.
printf 'Authorization: Bearer %s\nX-GitHub-Api-Version: 2022-11-28\n' "$GH_TOKEN" > "$work/headers"

attach() {
  local file="$1" name type existing status
  name="$(basename "$file")"
  case "$name" in
    *.json) type=application/json ;;
    *.apk) type=application/vnd.android.package-archive ;;
    *) type=application/octet-stream ;;
  esac
  existing="$(gh api "repos/$repo/releases/$release/assets?per_page=100" --jq ".[] | select(.name == \"$name\") | .id")"
  [ -z "$existing" ] || gh api -X DELETE "repos/$repo/releases/assets/$existing" > /dev/null
  status="$(curl -sS -H @"$work/headers" -H "Content-Type: $type" --data-binary @"$file" --max-time 1800 \
    -o "$work/answer" -w '%{http_code}' "https://uploads.github.com/repos/$repo/releases/$release/assets?name=$name")" ||
    { echo "attach_release: $name was not sent" >&2; exit 1; }
  [ "$status" = 201 ] || { echo "attach_release: $name was not attached ($status): $(head -c 300 "$work/answer")" >&2; exit 1; }
  echo "attach_release: $name attached to $tag"
}

for file in "$dir"/*; do
  case "$(basename "$file")" in builds.json|builds.lines|builds.lines.new) continue ;; esac
  [ -f "$file" ] && attach "$file"
done
attach "$dir/builds.json"
