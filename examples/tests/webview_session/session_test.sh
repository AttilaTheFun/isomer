#!/bin/bash
# The web Storybook's page serving its session (runtime/session_host.js: an
# app in web-view mode, docs/modes.md) in headless Chrome, driven as a head
# drives it (session_test.html): the start, the whole tree first, a tap on
# the story's button, the count it changes in the next patch. Nothing is
# drawn and nothing pictured.
#   session_test.sh <browser_check> <site> <test page> <chrome or "">
set -euo pipefail
check="$1" site="$2" page="$3"
chrome="${4:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
# The site with the test's page beside its own.
copy="$(mktemp -d)"
trap 'rm -rf "$copy"' EXIT
cp -RL "$site/." "$copy/"
chmod -R u+w "$copy"
cp "$page" "$copy/session_test.html"
# Console errors are printed but don't fail it (a story's remote image can
# be refused offline); exceptions do, and the page throws its failure.
"$check" --site "$copy" --chrome "$chrome" --until "window.__isoSessionTest !== undefined" \
    --settle 0 --timeout 90 --allow-errors \
    --page "session_test.html?ISO_STORYBOOK_STORY=state.observableobject="
