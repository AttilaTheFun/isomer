#!/bin/bash
# The web Storybook's stories, each opened by its link and pictured in
# headless Chrome (//tools/testing/browser_check): a story that never draws,
# or throws, fails the test. The pictures are the test's outputs
# (TEST_UNDECLARED_OUTPUTS_DIR: bazel-testlogs/…/test.outputs/outputs.zip).
#   web_test.sh <browser_check> <site> <chrome or ""> <story>…
set -euo pipefail
check="$1" site="$2" chrome="${3:-${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}}"
shift 3
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}"
pages=()
for story in "$@"; do
    pages+=(--page "?renderer=dom&ISO_STORYBOOK_STORY=$story=$out/web-$story.png")
done
# The renderer's first tree committed, then a few seconds for fonts and
# images. Console errors are printed but don't fail it (a story's remote
# image can be refused offline); exceptions do.
exec "$check" --site "$site" --chrome "$chrome" --until "window.__isoLastTree" \
    --settle 2 --timeout 90 --allow-errors "${pages[@]}"
