#!/bin/bash
# the private AttilaTheFun/applications' tools/ci/promote_from_ci.sh.
# Makes a release production by promotion: asks Applications Server to
# promote the Alphas main's CI published of the release's commit (the
# builds the owner tested), which it copies, stamps Production (their
# BuildVariant) and signs again for production, the Mac's notarized. Nothing
# is built. The release job's OIDC token is the permission: its release
# branch's push (or a v* tag's) by a releaser, of a repository configured
# there (docs/CI.md).
# Any repository's workflow copies this file and connect_from_ci.sh beside
# it; it needs bash, curl and openssl, on a Mac or Linux.
#
#   tools/ci/promote_from_ci.sh [--notes-file <notes.md>] [--dmg-dir <dir>]
#
# --dmg-dir: each promoted Mac app's disk image, which the server makes as
# it promotes it (the app and a link to /Applications, signed, notarized
# and stapled), downloaded there as <Name>-<version>.dmg, for the release
# job to hand out with its release.
#
# From the job's environment, as publish_from_ci.sh has them: the job's
# `permissions: id-token: write`, APPLICATIONS_CI_CODE and, if not
# `applications-server`, APPLICATIONS_AUDIENCE. It fails when the server
# keeps no Alpha of the commit (an Alpha is kept a week once it is not its
# app's newest), or when an Android app's would be all there is: the
# server does not sign Android apps, so an Android release still builds.
set -euo pipefail

fail() { echo "promote_from_ci: $*" >&2; exit 1; }

notes_file=""
dmg_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) notes_file="${2:?--notes-file takes the release notes file}"; shift 2 ;;
    --dmg-dir) dmg_dir="${2:?--dmg-dir takes a folder}"; shift 2 ;;
    *) fail "usage: tools/ci/promote_from_ci.sh [--notes-file <notes.md>] [--dmg-dir <dir>]" ;;
  esac
done
[ -z "$dmg_dir" ] || mkdir -p "$dmg_dir"
[ -z "$notes_file" ] || [ -f "$notes_file" ] || fail "no such file: $notes_file"

work="$(mktemp -d)"
chmod 700 "$work"
# An end before the last line is a failure, whatever macOS's bash 3.2
# says (publish_from_ci.sh).
finished=""
trap 'code=$?; rm -rf "$work"; [ -n "$finished" ] || [ "$code" -ne 0 ] || code=1; exit $code' EXIT

. "$(dirname "$0")/connect_from_ci.sh"
connect_from_ci

{
  printf 'Authorization: Bearer %s\n' "$token"
  [ -z "$notes_file" ] || printf 'X-Applications-Notes: %s\n' "$(base64 < "$notes_file" | tr -d '\n')"
} > "$work/headers"

echo "Promoting ${GITHUB_SHA:-the commit}'s Alphas on ${server}…"
# Signing and notarizing take minutes; the answer waits for them.
status="$(curl -sS --cacert "$work/ca.pem" --connect-timeout 10 --max-time 3600 -H @"$work/headers" -X POST --data-binary '' \
  -o "$work/answer" -w '%{http_code}' "$server/api/promote")" || fail "the server was not reached"
if [ "$status" != "201" ]; then
  said="$(sed -n 's/.*"error":"\(.*\)"}.*/\1/p' "$work/answer")"
  fail "nothing was promoted ($status): ${said:-$(cat "$work/answer")}"
fi
# One line a build: the answer is a JSON array of them, each one's keys
# sorted, so its last is its version.
awk '{ gsub(/"version":"[^"]*"/, "&\n"); print }' "$work/answer" | grep '"bundleID"' > "$work/builds" || true
while IFS= read -r build; do
  field() { printf '%s' "$build" | sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p"; }
  echo "Promoted $(field name) $(field version) ($(field bundleID), $(field platform)): build $(field id)"
  if [ -n "$dmg_dir" ] && [ "$(field platform)" = macos ]; then
    dmg="$dmg_dir/$(field name | tr ' ' '-')-$(field version).dmg"
    status="$(curl -sS --cacert "$work/ca.pem" --connect-timeout 10 --max-time 1800 -o "$dmg" -w '%{http_code}' \
      "$server/builds/$(field id)/$(field downloadKey)/app.dmg")" || fail "$(field name)'s disk image was not downloaded"
    [ "$status" = 200 ] || { rm -f "$dmg"; fail "$(field name) $(field version) has no disk image here ($status): a server from before disk images?"; }
    echo "Downloaded its disk image: $dmg"
  fi
done < "$work/builds"
finished=1
