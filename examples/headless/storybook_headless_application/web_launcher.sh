#!/bin/bash
# The web Storybook, headful, for StorybookHeadlessTests
# (:storybook_headful_web_test): the site (built with
# --@isomer//drive:headful) in headless Chrome under browser_check, which
# keeps the page open until this is stopped. The page dials out to the
# test's hub (ISO_DRIVER, ISO_DRIVER_NAME: the page's ISO_ query, which the
# web host reads as the app's environment).
#
#   web_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# KEY=VALUE: the app's launch hooks, into the query; ISO_HEADLESS_WIDTH and
# ISO_HEADLESS_HEIGHT size Chrome's window instead (390 by 844 by default,
# the headless app's). From the test's environment: ISOMER_BROWSER_CHECK,
# ISOMER_WEB_SITE and CHROME (none: browser_check's own default).
set -euo pipefail
url="${1:?usage: web_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
width=390
height=844
query="renderer=react&ISO_DRIVER=$url&ISO_DRIVER_NAME=$name"
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH) width="${pair#*=}" ;;
        ISO_HEADLESS_HEIGHT) height="${pair#*=}" ;;
        *) query="$query&$pair" ;;
    esac
done
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}/$name.png"
exec "$ISOMER_BROWSER_CHECK" --site "$ISOMER_WEB_SITE" ${CHROME:+--chrome "$CHROME"} --width "$width" \
    --height "$height" --until 'window.__isoLastTree' --timeout 90 --settle 0 --allow-errors --hold \
    --page "?$query=$out"
