#!/bin/bash
# The Linux Storybook (SDL2 and OpenGL, the SwiftGPU renderer) on each story,
# where it's built: under Xvfb with Mesa's software OpenGL (llvmpipe), as the
# proof's Linux VM draws, or SDL's offscreen driver where there's no Xvfb.
# One launch: the stories are switched through ISO_STORYBOOK_CONTROL (the
# Storybook's control file, as the proof does), each picture the host's
# own frame dump (ISO_SHOT), checked for having drawn and written as a PNG
# to the test's outputs.
#   linux_test.sh <storybook> <picture_check> <story>…
set -uo pipefail
app="$1" check="$2"
shift 2
out="${TEST_UNDECLARED_OUTPUTS_DIR:-$(mktemp -d)}"
work="$(mktemp -d)"
control="$work/control"
shot="$work/frame.ppm"
pids=()
cleanup() {
    for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null; done
    rm -rf "$work"
}
trap cleanup EXIT

if command -v Xvfb >/dev/null; then
    display=$((90 + RANDOM % 100))
    Xvfb ":$display" -screen 0 1280x800x24 -nolisten tcp >"$out/xvfb.log" 2>&1 &
    pids+=($!)
    export DISPLAY=":$display"
    for _ in $(seq 1 50); do [ -e "/tmp/.X11-unix/X$display" ] && break; sleep 0.1; done
else
    export SDL_VIDEODRIVER=offscreen
fi
export LIBGL_ALWAYS_SOFTWARE=1 ISO_SHOT="$shot" ISO_STORYBOOK_CONTROL="$control" ISO_WINDOW_MAXIMIZED=1
"$app" >"$out/storybook.log" 2>&1 &
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
        echo "linux_test: the Storybook ended (at $story); its log:" >&2
        tail -40 "$out/storybook.log" >&2
        exit 1
    fi
    if [ "$shown" != "$story" ]; then
        echo "linux_test: $story: never shown" >&2
        failures=$((failures + 1))
        continue
    fi
    sleep 2
    # The dump is rewritten each frame: two copies alike are a whole frame.
    for _ in $(seq 1 20); do
        cp "$shot" "$work/a.ppm" 2>/dev/null && sleep 0.2 && cp "$shot" "$work/b.ppm" 2>/dev/null &&
            cmp -s "$work/a.ppm" "$work/b.ppm" && break
    done
    "$check" "$work/a.ppm" "$out/linux-$story.png" || failures=$((failures + 1))
done
echo "linux_test: $# stories, $failures failed"
[ $failures -eq 0 ]
