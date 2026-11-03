#!/bin/bash
# Stamps a GitHub Actions job's builds with their version before they are
# built: MAJOR.MINOR.BUILD, the next of the line the repository commits
# (MAJOR.MINOR.0), from Applications Server, which gives every build of one
# commit the same (AttilaTheFun/applications' docs/CI.md, "Versions"). The
# job asks with its OIDC token, as publish_from_ci.sh publishes
# (connect_from_ci.sh, beside both: a repository copies it with them), and
# the server takes the commit from the token (its `sha`), never from the
# job. bash, curl and openssl, on a Mac or Linux. Copied from
# AttilaTheFun/reviews' tools/ci/next_version.sh.
#
# Isomer's versions are MAJOR.MINOR.BUILD too (AGENTS.md, "Versions"):
# MODULE.bazel and the apps commit MAJOR.MINOR.0, and a build's BUILD is
# the Playground's, the number releases are tagged with (v0.39.N). So
# tools/ci/stamp_apps.sh asks for app "Playground" and stamps the one
# version into the Storybook's Info.plists as well as the Playground's,
# then (examples/tools/stamp_storybook.py and the Playground's stamp.py)
# into their Android versionName and versionCode.
#
#   tools/ci/next_version.sh <app> <Info.plist>…
#
# - <app>: the app as the server counts its builds ("Applications", for
#   Applications β's too): one of the repository's bundle ids' apps.
# - The line is MAJOR.MINOR of the first Info.plist's
#   CFBundleShortVersionString. Every Info.plist's is stamped with the
#   version, in the checkout, before the build: never committed.
#   CFBundleVersion stays as committed, 1.
# - The Info.plists are XML, as checked in.
# - A server from before POST /api/next-version answers 404 (or, with its
#   password on, 401 "The password is wrong": it reads any bearer on a path
#   other than publish's as its password). The builds then keep the
#   committed version, with a warning, until the server is updated.
#
# From the job's environment, as publish_from_ci.sh's: its `permissions:
# id-token: write`, APPLICATIONS_CI_CODE and APPLICATIONS_AUDIENCE.
set -euo pipefail

fail() { echo "next_version: $*" >&2; exit 1; }

[ $# -ge 2 ] || fail "usage: tools/ci/next_version.sh <app> <Info.plist>…"
app="$1"
shift
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

stamp() {
  plist_version "$1" "$2" > "$work/stamped" || fail "$1's CFBundleShortVersionString was not stamped"
  cat "$work/stamped" > "$1"
}

committed="$(plist_version "$1")" || fail "$1's CFBundleShortVersionString has no <string>"
line="$(printf '%s' "$committed" | awk -F. 'NF >= 2 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { print $1 "." $2 }')"
[ -n "$line" ] || fail "$1's CFBundleShortVersionString, \"$committed\", is not MAJOR.MINOR.0"

work="$(mktemp -d)"
chmod 700 "$work"
# macOS's bash (3.2) runs this with $? 0, and ends with 0, when an unset
# variable stops the script (set -eu): an end before the last line is a
# failure, whatever it says.
finished=""
trap 'code=$?; rm -rf "$work"; [ -n "$finished" ] || [ "$code" -ne 0 ] || code=1; exit $code' EXIT

# The job's token, and the server's address and certificate authority.
. "$(dirname "$0")/connect_from_ci.sh"
connect_from_ci

# The request: the app (a JSON string, its quotes and backslashes escaped)
# and the line; the token in a file, never on a command line.
printf '{"app":"%s","line":"%s"}' "$(printf '%s' "$app" | sed 's/[\\"]/\\&/g')" "$line" > "$work/asked.json"
printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$token" > "$work/headers"
status="$(curl -sS --cacert "$work/ca.pem" --connect-timeout 10 --max-time 60 -H @"$work/headers" --data-binary @"$work/asked.json" \
  -o "$work/answer" -w '%{http_code}' "$server/api/next-version")" || fail "Applications Server at $server was not asked"
said="$(sed -n 's/.*"error":"\(.*\)"}.*/\1/p' "$work/answer" | sed 's,\\/,/,g')"
if [ "$status" = 404 ] || { [ "$status" = 401 ] && [ "$said" = "The password is wrong" ]; }; then
  echo "::warning::Applications Server at $server has no POST /api/next-version yet ($status): $app keeps the committed $committed"
  finished=1
  exit 0
fi
[ "$status" = 200 ] || fail "no version was given ($status): ${said:-$(cat "$work/answer")}"
version="$(sed -n 's/.*"version":"\([^"]*\)".*/\1/p' "$work/answer")"
# The line's, and a number after it.
build="${version#"$line".}"
case "$build" in
  "$version" | "" | *[!0-9]*) fail "the server's answer is not a version of $line: $(cat "$work/answer")" ;;
esac

for plist in "$@"; do stamp "$plist" "$version"; done
echo "$app $version (the next of $line, for the token's commit): stamped into $*"
finished=1
