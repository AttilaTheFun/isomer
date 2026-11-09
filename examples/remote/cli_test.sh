#!/bin/bash
# The `iso` CLI driving the Storybook built headless: added as an exec:
# application (started on the first command, kept running on a Unix socket),
# driven a command at a time, its state kept between them, then stopped.
#   cli_test.sh <isomer> <app>
set -euo pipefail
# Each answer is captured before it's matched: `grep -q` stops reading at its
# first match, and the CLI writing the rest into a closed pipe would fail the
# pipeline.
has() { local output; output="$("$@")"; grep -q -- "$EXPECTED" <<< "$output"; }
isomer="$PWD/$1" app="$PWD/$2"
export XDG_CONFIG_HOME="$(mktemp -d)"
export ISO_STORYBOOK_STORY=state.observableobject ISO_HEADLESS_HEIGHT=6000
trap '"$isomer" application stop storybook >/dev/null 2>&1 || true; rm -rf "$XDG_CONFIG_HOME"' EXIT
"$isomer" application add storybook "exec:$app"
EXPECTED='^\* storybook' has "$isomer" application list
EXPECTED='Taps: 0' has "$isomer" ls
EXPECTED='^text-[0-9]* "Taps: 0"$' has "$isomer" ls text
EXPECTED='^button-[0-9]* "Tap"$' has "$isomer" ls button
if EXPECTED='^text-' has "$isomer" ls button; then echo "ls button listed texts"; exit 1; fi
# Elements by their names on the screen: the button, tapped by its name.
tap="$("$isomer" ls button | sed -n 's/^\(button-[0-9]*\) "Tap"$/\1/p')"
[ -n "$tap" ] || { echo "no button named for Tap"; exit 1; }
"$isomer" tap "$tap" > /dev/null
"$isomer" tap Tap > /dev/null
EXPECTED='^role: textField$' has "$isomer" inspect Title
# The app kept running: its count went on from the last command's.
EXPECTED='Taps: 2' has "$isomer" wait "Taps: 2"
EXPECTED='Headless' has "$isomer" info
EXPECTED='"ok":true' has "$isomer" --json ls
if "$isomer" tap "No such button" > /dev/null; then echo "a missing button didn't fail"; exit 1; fi
"$isomer" application stop storybook
"$isomer" application remove storybook
echo "PASS: the iso CLI drove the Storybook"
