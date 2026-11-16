#!/bin/bash
# A Linux app (SDL2 and OpenGL), headful, for a test's HeadlessApp
# (docs/drive.md): built with --@isomer//drive:headful, under a display of
# its own (Xvfb with Mesa's software OpenGL, else SDL's offscreen driver),
# run with ISO_DRIVER and ISO_DRIVER_NAME in its environment until this is
# stopped. A test's pictures are the app's last frame: its renderer writes
# each frame to ISO_SHOT, a PNG (linux/libraries/swift_ui/renderer.c).
#
#   linux_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…] [-- <argument>…]
#
# From the test's environment: ISOMER_LINUX_APP, the app, and ISOMER_FRESH
# (requests.sh: 1, the default, gives the app a new home, HOME and XDG_*,
# each launch; 0 the same one every launch, kept in the temporary
# directory).
set -uo pipefail
. "$(dirname "$0")/requests.sh"
url="${1:?usage: linux_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
app="${ISOMER_LINUX_APP:?ISOMER_LINUX_APP: the Linux app}"
frames="$(mktemp -d)"
split_arguments "$@"
environment=(ISO_DRIVER="$url" ISO_DRIVER_NAME="$name" LIBGL_ALWAYS_SOFTWARE=1 ISO_SHOT="$frames/frame.png")
for pair in ${pairs[@]+"${pairs[@]}"}; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("$pair") ;;
    esac
done
if fresh; then
    home="$frames/home"
else
    home="${TMPDIR:-/tmp}/isomer-linux-home-$(basename "$app")"
fi
mkdir -p "$home/.config" "$home/.local/share" "$home/.cache"
environment+=(HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache")
pids=()
stop() { for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null; done; rm -rf "$frames"; exit 0; }
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
env "${environment[@]}" "$app" ${app_arguments[@]+"${app_arguments[@]}"} > "${TEST_UNDECLARED_OUTPUTS_DIR:-/tmp}/$name.log" 2>&1 &
pids+=($!)
# A picture: the last frame drawn (none before the first).
last_frame() { [ -s "$frames/frame.png" ] && cp "$frames/frame.png" "$1"; }
serve_requests last_frame &
pids+=($!)
wait "${pids[-2]}"
