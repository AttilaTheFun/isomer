#!/bin/bash
# The owner's line rule (2026-11-09; the private AttilaTheFun/applications' docs/RELEASE_ASSETS.md, "Versions"):
# once a version is published as a production release, the next proposal
# moves to the next minor line. A proposal (`run: prerelease` or
# `run: release`) fails here, before anything is built, when the
# repository already has a published release, not a pre-release, on its
# version's `v<major>.<minor>` line. Pre-releases and drafts on a line not
# yet published are fine. The release job doesn't run it: its own release
# is published by then.
#
#   tools/ci/check_version_line.sh <version>
#
# From the job's environment: GH_TOKEN (contents: read), GITHUB_REPOSITORY.
# bash and gh (gh_ready.sh, beside this file).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
version="${1:?usage: tools/ci/check_version_line.sh <version>}"
repo="${GITHUB_REPOSITORY:?}"
: "${GH_TOKEN:?GH_TOKEN, the job token}"
line="$(printf '%s' "$version" | awk -F. 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 "." $2 }')"
[ -n "$line" ] || { echo "check_version_line: \"$version\" is not MAJOR.MINOR[.BUILD]" >&2; exit 2; }
# shellcheck source=tools/ci/gh_ready.sh
. "$ROOT/tools/ci/gh_ready.sh"

# Every published, non-pre-release tag, then those on the line: v<line> or
# v<line>.<n>. Apart, so a failed API call fails the check (set -e on a bare
# assignment), while grep's "no match" doesn't.
releases="$(gh api --paginate "repos/$repo/releases?per_page=100" \
  --jq ".[] | select((.draft | not) and (.prerelease | not)) | .tag_name")"
published="$(printf '%s\n' "$releases" | grep -E "^v${line//./\\.}(\\.[0-9]+)?\$" || true)"
if [ -n "$published" ]; then
  next="$(printf '%s' "$line" | awk -F. '{ print $1 "." $2 + 1 }')"
  echo "::error::$version is on the $line line, which is already published as a production release ($(printf '%s' "$published" | tr '\n' ' ' | sed 's/ $//')). Move the committed line to $next.0 (CFBundleShortVersionString), and propose again." >&2
  exit 1
fi
echo "check_version_line: the $line line has no production release yet, so $version may be proposed"
