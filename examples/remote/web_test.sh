#!/bin/bash
# The web's thin client in headless Chrome (//tools/testing/browser_check)
# against the Storybook built headless, served on a WebSocket of its own
# (ISO_DRIVE_LISTEN): the story drawn by the page's renderer from the
# session's patches, its button clicked in the page, and the count it changes
# drawn from the next frame. The picture is the test's output
# (TEST_UNDECLARED_OUTPUTS_DIR).
#   web_test.sh <app> <browser_check> <thin client's site> <chrome or "">
set -euo pipefail
app="$1" check="$2" site="$3"
chrome="${4:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}"
log="$(mktemp)"
ISO_DRIVE_LISTEN="ws://127.0.0.1:0" ISO_HEADLESS_PROTOCOL=serve ISO_STORYBOOK_STORY=state.observableobject \
    "$app" > "$log" 2>&1 < /dev/null &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 200); do grep -q "isomer: listening ws:" "$log" && break; sleep 0.1; done
session="$(sed -n 's/^isomer: listening \(ws:[^ ]*\).*/\1/p' "$log")/session"
[ "$session" != "/session" ] || { echo "the app didn't start listening:"; cat "$log"; exit 1; }
# Taps once the first frame shows "Taps: 0", then waits for "Taps: 1".
until='(() => {
  const tree = window.__isoLastTree || "";
  if (tree.includes("Taps: 1")) return true;
  if (!window.__tapped && tree.includes("Taps: 0")) {
    const button = [...document.querySelectorAll("[data-tap]")].find((e) => e.textContent.trim() === "Tap");
    if (button) { button.click(); window.__tapped = true; }
  }
  return false;
})()'
"$check" --site "$site" --chrome "$chrome" --until "$until" --settle 1 --timeout 60 \
    --page "?session=$session=$out/remote-web.png"
