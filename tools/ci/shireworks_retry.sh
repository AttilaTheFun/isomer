#!/bin/bash
# tools/ci/shireworks.sh, asked again when its server didn't answer (a busy
# Mac's server is sometimes slow to take a connection): nothing reached the
# server then, so asking again is safe. Up to five tries, ten seconds
# apart; any other failure is the command's own, passed on at once. The CI
# scripts call this in place of shireworks.sh, which already waits through
# a busy server and a restart while it leases.
#
#   tools/ci/shireworks_retry.sh <shireworks.sh arguments…>
set -uo pipefail
script="$(cd "$(dirname "$0")" && pwd)/shireworks.sh"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT
try=1
while :; do
    "$script" "$@" 2> "$err"
    status=$?
    cat "$err" >&2
    if [ "$status" -ne 0 ] && [ "$try" -lt 5 ] && grep -q "didn't answer" "$err"; then
        echo "shireworks_retry.sh: the server didn't answer; asking again in 10 s (try $try of 5)" >&2
        try=$((try + 1))
        sleep 10
        continue
    fi
    exit "$status"
done
