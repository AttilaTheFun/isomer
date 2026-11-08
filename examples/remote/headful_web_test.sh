#!/bin/bash
# A headful app driven from the command line: the web Storybook (built with
# --@isomer//drive:headful) in headless Chrome, launched with ISO_DRIVER (the
# page's ISO_ query), dials out to the `isomer` CLI's hub; the CLI, through
# the hub, taps the story's button, and the page draws the count it changed.
#   headful_web_test.sh <isomer> <browser_check> <the web Storybook's site> <chrome or "">
set -euo pipefail
isomer="$1" check="$2" site="$3"
chrome="${4:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}"
log="$(mktemp)" driven="$(mktemp)"
"$isomer" hub --ws 0 > "$log" 2>&1 &
hub=$!
trap 'kill $hub ${driver:-} 2>/dev/null || true; rm -f "$log" "$driven"' EXIT
for _ in $(seq 200); do grep -q "isomer hub: ws:" "$log" && break; sleep 0.1; done
url="$(sed -n 's/^isomer hub: \(ws:[^ ]*\).*/\1/p' "$log")"
[ -n "$url" ] || { echo "the hub didn't start:"; cat "$log"; exit 1; }
# The driver: until the page has attached, then a tap and the count it makes.
(
    for _ in $(seq 300); do
        if "$isomer" --url "$url" tap Tap > /dev/null 2>&1; then
            "$isomer" --url "$url" wait "Taps: 1" > "$driven" 2>&1 && exit 0
        fi
        sleep 0.2
    done
    exit 1
) &
driver=$!
"$check" --site "$site" --chrome "$chrome" --until 'window.__isoLastTree && window.__isoLastTree.includes("Taps: 1")' \
    --settle 1 --timeout 90 --allow-errors \
    --page "?renderer=react&ISO_STORYBOOK_STORY=state.observableobject&ISO_DRIVER=$url=$out/headful-web.png"
wait $driver
grep -q "Taps: 1" "$driven"
grep -q "attached:" "$log"
echo "PASS: the web Storybook, headful in Chrome, driven through the hub"
