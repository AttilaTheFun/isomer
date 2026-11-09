#!/bin/bash
# The Linux Storybook, headful, for StorybookHeadlessTests: the app (SDL2
# and OpenGL, built with --@isomer//drive:headful) under a display of its
# own (Xvfb with Mesa's software OpenGL, else SDL's offscreen driver), run
# with ISO_DRIVER and ISO_DRIVER_NAME in its environment until this is
# stopped.
#
#   linux_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…]
#
# From the test's environment: ISOMER_LINUX_APP, the app.
set -uo pipefail
url="${1:?usage: linux_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_LINUX_APP:?ISOMER_LINUX_APP: the Linux app}"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name" LIBGL_ALWAYS_SOFTWARE=1)
for pair in "$@"; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
pids=()
stop() { for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null; done; exit 0; }
trap stop TERM INT
if command -v Xvfb > /dev/null; then
    display=$((100 + RANDOM % 400))
    Xvfb ":$display" -screen 0 1280x800x24 -nolisten tcp > /dev/null 2>&1 &
    pids+=($!)
    for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X$display" ] && break; sleep 0.1; done
    environment+=(DISPLAY=":$display")
else
    environment+=(SDL_VIDEODRIVER=offscreen)
fi
env "${environment[@]}" "$app" > "${TEST_UNDECLARED_OUTPUTS_DIR:-/tmp}/$name.log" 2>&1 &
pids+=($!)
wait "${pids[-1]}"
