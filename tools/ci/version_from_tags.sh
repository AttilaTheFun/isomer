#!/bin/bash
# Stamps a proposal job's builds with their version before they are built,
# from the repository's own releases (docs/RELEASE_ASSETS.md, "Versions"),
# with no server asked: MAJOR.MINOR.N, where MAJOR.MINOR is the committed
# line (the first Info.plist's CFBundleShortVersionString) and N is
# - the version of a release already on this commit (a proposal run again
#   on it), drafts included, known by the commit the release was made at
#   (its target_commitish: the sha CI's draft_release.sh gives; a release
#   made at a branch's name isn't recognized, and gets the next N); else
# - one past the highest `v<line>.N` among the repository's releases (a
#   draft has its tag's name before its tag) and tags; else 1.
# Every Info.plist's CFBundleShortVersionString is stamped with it, in the
# checkout, never committed. CFBundleVersion stays as committed.
#
#   tools/ci/version_from_tags.sh <Info.plist>…
#
# From the job's environment: GH_TOKEN, the job's (drafts are listed only
# with `contents: write`), GITHUB_REPOSITORY and GITHUB_SHA. bash, awk and
# gh (gh_ready.sh, beside this file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail() { echo "version_from_tags: $*" >&2; exit 1; }

[ $# -ge 1 ] || fail "usage: tools/ci/version_from_tags.sh <Info.plist>…"
repo="${GITHUB_REPOSITORY:?}"
commit="${GITHUB_SHA:?}"
: "${GH_TOKEN:?GH_TOKEN, the job token with contents: write}"
for plist in "$@"; do
  [ -f "$plist" ] || fail "no such file: $plist"
  grep -q '<key>CFBundleShortVersionString</key>' "$plist" || fail "$plist is no XML Info.plist with a CFBundleShortVersionString"
done

# An Info.plist's CFBundleShortVersionString: the first <string> after its
# key, on the key's line or a later one. Given a version: the file, with
# that string made the version and the rest as it was.
plist_version() {
  awk -v version="${2:-}" '
    BEGIN { key = "<key>CFBundleShortVersionString</key>" }
    !found && (at = index($0, key)) { found = 1; head = substr($0, 1, at + length(key) - 1); $0 = substr($0, at + length(key)) }
    found && !done && match($0, /<string>[^<]*<\/string>/) {
      done = 1
      if (version == "") { print substr($0, RSTART + 8, RLENGTH - 17); exit }
      $0 = substr($0, 1, RSTART - 1) "<string>" version "</string>" substr($0, RSTART + RLENGTH)
    }
    version != "" { print head $0; head = "" }
    END { exit done ? 0 : 1 }' "$1"
}

committed="$(plist_version "$1")" || fail "$1's CFBundleShortVersionString has no <string>"
line="$(printf '%s' "$committed" | awk -F. 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 "." $2 }')"
[ -n "$line" ] || fail "$1's CFBundleShortVersionString, \"$committed\", is not MAJOR.MINOR.0"

# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"
# Apart, so a failed API call fails the script (set -e on a bare
# assignment): every release's tag name and commit, a line each, and every
# tag's name.
releases="$(gh api --paginate "repos/$repo/releases?per_page=100" --jq '.[] | "\(.tag_name)\t\(.target_commitish)"')"
tags="$(gh api --paginate "repos/$repo/tags?per_page=100" --jq '.[].name')"

version="$(printf '%s\n%s\n' "$releases" "$tags" | awk -F'\t' -v line="$line" -v commit="$commit" '
  BEGIN { prefix = "v" line "." }
  index($1, prefix) == 1 {
    n = substr($1, length(prefix) + 1)
    if (n !~ /^[0-9]+$/) next
    n += 0
    if (n > highest) highest = n
    if ($2 == commit && n > mine) mine = n
  }
  END { print line "." (mine ? mine : highest + 1) }')"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for plist in "$@"; do
  plist_version "$plist" "$version" > "$work/stamped" || fail "$plist's CFBundleShortVersionString was not stamped"
  cat "$work/stamped" > "$plist"
done
echo "version_from_tags: $version (of the $line line, for $commit): stamped into $*"
