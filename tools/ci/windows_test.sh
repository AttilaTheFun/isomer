#!/bin/bash
# The Windows Storybook's stories under Wine, in a Linux container: the app
# cross-built on Linux for Windows on Arm (--config=windows_on_linux), run by
# arm64 Wine (10 or later: 9 can't unwind arm64 Linux libraries built with
# pointer authentication), Direct3D 11 through Wine onto Mesa's software
# OpenGL under Xvfb. One launch, the stories switched through
# ISO_STORYBOOK_CONTROL as on Linux; each picture the X display, checked for
# having drawn (more than one colour) and kept. Wine draws Windows' text and
# controls with its own fonts and DirectWrite: a check that the app runs,
# never the proof's Windows pictures.
#
#   tools/ci/windows_test.sh <app dir> <out dir> <story>…
# <app dir>: the .exe, the Swift runtime's DLLs and the Storybook's assets
# (tools/ci/container_build.sh's `platforms` packaging). Needs wine, xvfb and
# imagemagick (Ubuntu 26.04's apt).
set -uo pipefail
app="$(cd "$1" && pwd)"
out="$2"
shift 2
mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
    wineserver -k 2>/dev/null
    rm -rf "$work"
}
trap cleanup EXIT

display=$((90 + RANDOM % 100))
Xvfb ":$display" -screen 0 1280x800x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
pids+=($!)
export DISPLAY=":$display" WINEPREFIX="$work/prefix" WINEDEBUG=-all
# No Mono or Gecko installers: their prompts wait for an answer forever.
export WINEDLLOVERRIDES="mscoree=;mshtml="
timeout 300 wineboot -i >"$out/wineboot.log" 2>&1

# The assets by Windows paths (Wine's Z: is the root), as the app's runfiles.
winpath() { printf 'Z:%s' "$(tr / '\\' <<<"$1")"; }
(cd "$app" && find assets -name '*.png' | while read -r f; do
    printf 'storybook/%s %s\n' "$f" "$(winpath "$app/$f")"
done) >"$work/manifest"
control="$work/control"
RUNFILES_MANIFEST_FILE="$(winpath "$work/manifest")" ISO_STORYBOOK_CONTROL="$(winpath "$control")" \
    wine "$app/storybook_windows_application.exe" >"$out/storybook.log" 2>&1 &
app_pid=$!
pids+=($app_pid)

failures=0
for story in "$@"; do
    printf %s "$story" >"$control"
    shown=""
    for _ in $(seq 1 240); do
        shown="$(cat "$control.shown" 2>/dev/null)"
        [ "$shown" = "$story" ] && break
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.25
    done
    if ! kill -0 "$app_pid" 2>/dev/null; then
        echo "windows_test: the Storybook ended (at $story); its log:" >&2
        tail -40 "$out/storybook.log" >&2
        exit 1
    fi
    if [ "$shown" != "$story" ]; then
        echo "windows_test: $story: never shown" >&2
        failures=$((failures + 1))
        continue
    fi
    sleep 2
    import -window root "$out/windows-$story.png"
    colours="$(identify -format '%k' "$out/windows-$story.png" 2>/dev/null || echo 0)"
    if [ "${colours:-0}" -le 1 ]; then
        echo "windows_test: $story: nothing drawn" >&2
        failures=$((failures + 1))
    else
        echo "windows_test: $story ($colours colours)"
    fi
done
echo "windows_test: $# stories, $failures failed"
[ $failures -eq 0 ]
