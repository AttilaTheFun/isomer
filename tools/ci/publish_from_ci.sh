#!/bin/bash
# Publishes a GitHub Actions job's builds to Applications Server, which
# signs them: CI holds no signing key and no password. The job proves
# where the builds came from with its OIDC token, which the server checks
# against GitHub's keys and its own settings (its repository's bundle ids;
# a release's tag, published by a releaser, for production) before it
# signs and publishes them (AttilaTheFun/applications' docs/CI.md). Any
# repository's workflow copies this file and connect_from_ci.sh beside it
# (the token and the server, which next_version.sh takes too); it needs
# bash, curl and openssl, on a Mac or Linux. Copied from
# AttilaTheFun/reviews' tools/ci/publish_from_ci.sh.
#
#   tools/ci/publish_from_ci.sh [--notes-file <notes.md>] [--app <app>] <package>…
#
# Each package is an .ipa, a Mac app's .zip or .dmg, or an .apk, as CI
# built it, unsigned (--config=alpha for a commit, --config=prod for a
# release branch's). From the job's environment:
# - the job's `permissions: id-token: write`, which gives it
#   ACTIONS_ID_TOKEN_REQUEST_URL and ACTIONS_ID_TOKEN_REQUEST_TOKEN;
# - APPLICATIONS_CI_CODE: `applications-server code --ci` (a repository
#   secret): the server's addresses and its certificate authority's
#   fingerprint, which the authority the server presents must match;
# - APPLICATIONS_AUDIENCE: the audience the server takes, if not
#   `applications-server` (`applications-server oidc`);
# - APPLICATIONS_COMMIT: the commit built, if not GITHUB_SHA (a pull
#   request's head: its run's GITHUB_SHA is the merge's). The branch and
#   the pull request come from the token itself.
set -euo pipefail

fail() { echo "publish_from_ci: $*" >&2; exit 1; }

notes_file=""
app=""
packages=()
while [ $# -gt 0 ]; do
  case "$1" in
    --notes-file) notes_file="${2:?--notes-file takes the release notes file}"; shift 2 ;;
    --app) app="${2:?--app takes the name of the app}"; shift 2 ;;
    -*) fail "unknown option $1" ;;
    *) packages+=("$1"); shift ;;
  esac
done
[ ${#packages[@]} -gt 0 ] || fail "usage: tools/ci/publish_from_ci.sh [--notes-file <notes.md>] [--app <app>] <package>…"
for package in "${packages[@]}"; do [ -f "$package" ] || fail "no such file: $package"; done
[ -z "$notes_file" ] || [ -f "$notes_file" ] || fail "no such file: $notes_file"

work="$(mktemp -d)"
chmod 700 "$work"
# macOS's bash (3.2) runs this with $? 0, and ends with 0, when an unset
# variable stops the script (set -eu), which hid a publish that never
# happened: an end before the last line is a failure, whatever it says.
finished=""
trap 'code=$?; rm -rf "$work"; [ -n "$finished" ] || [ "$code" -ne 0 ] || code=1; exit $code' EXIT

# The job's token, and the server's address and certificate authority
# (connect_from_ci.sh, beside this file).
. "$(dirname "$0")/connect_from_ci.sh"
connect_from_ci

# What each publish says besides the token: the notes and the app's name
# (base64, as `applications-server publish` sends them) and the commit.
{
  printf 'Authorization: Bearer %s\n' "$token"
  printf 'X-Applications-Commit: %s\n' "${APPLICATIONS_COMMIT:-${GITHUB_SHA:-}}"
  [ -z "$notes_file" ] || printf 'X-Applications-Notes: %s\n' "$(base64 < "$notes_file" | tr -d '\n')"
  [ -z "$app" ] || printf 'X-Applications-App: %s\n' "$(printf '%s' "$app" | base64 | tr -d '\n')"
  # No 100-continue: the server reads the body as it comes.
  printf 'Expect:\n'
} > "$work/headers"

for package in "${packages[@]}"; do
  # Braces: bash 3.2 reads a byte of "…" as part of the name.
  echo "Publishing $(basename "$package") to ${server}…"
  # Signing and notarizing take minutes; the answer waits for them.
  status="$(curl -sS --cacert "$work/ca.pem" --connect-timeout 10 --max-time 3600 -H @"$work/headers" -X POST -T "$package" \
    -o "$work/answer" -w '%{http_code}' "$server/api/publish")" || fail "$(basename "$package") was not sent"
  if [ "$status" != "201" ]; then
    said="$(sed -n 's/.*"error":"\(.*\)"}.*/\1/p' "$work/answer")"
    fail "$(basename "$package") was not published ($status): ${said:-$(cat "$work/answer")}"
  fi
  field() { sed -n "s/.*\"$1\":\"\\([^\"]*\\)\".*/\\1/p" "$work/answer"; }
  echo "Published $(field name) $(field version) ($(field bundleID)), $(field channel): build $(field id)"
done
finished=1
