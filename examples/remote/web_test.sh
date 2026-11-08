#!/bin/bash
# The web's thin client in headless Chrome (//tools/testing/browser_check)
# against the gateway: the headless Storybook's story drawn by the page's
# React renderer from the session's patches, its button clicked in the page,
# and the count it changes drawn from the next frame. The picture is the
# test's output (TEST_UNDECLARED_OUTPUTS_DIR).
#   web_test.sh <gateway> <app> <browser_check> <thin client's site> <chrome or "">
set -euo pipefail
gateway="$1" app="$2" check="$3" site="$4"
chrome="${5:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}"
log="$(mktemp)"
"$gateway" --app "$app" --port 0 --grpc-port 0 > "$log" &
pid=$!
trap 'kill $pid 2>/dev/null || true; rm -f "$log"' EXIT
for _ in $(seq 100); do grep -q "^gateway:" "$log" && break; sleep 0.1; done
session="$(sed -n 's/^gateway: \(ws:[^ ]*\).*/\1/p' "$log")"
[ -n "$session" ] || { echo "the gateway didn't start"; exit 1; }
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
    --page "?session=$session&ISO_STORYBOOK_STORY=state.observableobject=$out/remote-web.png"
