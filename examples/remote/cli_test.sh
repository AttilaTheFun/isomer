#!/bin/bash
# The `isomer` CLI driving the Storybook built headless: added as an exec:
# application (started on the first command, kept running on a Unix socket),
# driven a command at a time, its state kept between them, then stopped.
#   cli_test.sh <isomer> <app>
set -euo pipefail
isomer="$PWD/$1" app="$PWD/$2"
export XDG_CONFIG_HOME="$(mktemp -d)"
export ISO_STORYBOOK_STORY=state.observableobject ISO_HEADLESS_HEIGHT=6000
trap '"$isomer" application stop storybook >/dev/null 2>&1 || true; rm -rf "$XDG_CONFIG_HOME"' EXIT
"$isomer" application add storybook "exec:$app"
"$isomer" application list | grep -q '^\* storybook'
"$isomer" ls | grep -q 'Taps: 0'
"$isomer" tap Tap > /dev/null
"$isomer" tap Tap > /dev/null
# The app kept running: its count went on from the last command's.
"$isomer" wait "Taps: 2" | grep -q 'Taps: 2'
"$isomer" info | grep -q 'Headless'
"$isomer" --json ls | grep -q '"ok":true'
if "$isomer" tap "No such button" > /dev/null; then echo "a missing button didn't fail"; exit 1; fi
"$isomer" application stop storybook
"$isomer" application remove storybook
echo "PASS: the isomer CLI drove the Storybook"
