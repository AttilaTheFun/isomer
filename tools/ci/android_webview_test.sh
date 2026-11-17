#!/bin/bash
# The Storybook in web-view mode on a phone reached by adb (docs/modes.md;
# //android/webview_android_application: its Swift as wasm in a WebView the
# app keeps out of sight, drawn by the Compose renderer over the session).
# Opened on state.observableobject, the story's "Taps: 0" must be drawn, a
# tap on its Tap button must make it "Taps: 1" (the event through the page,
# the app's next frame back), as //tests/webview_session does in Chrome. Then
# the app is started cold a few more times, and how long its page took each
# time (the reactor's compile from the page's Cache Storage after the first,
# session_host.js) is kept, from the page's own log. Run after
# tools/ci/android_test.sh on the same phone (tools/ci/hosted_android_test.sh).
#
#   tools/ci/android_webview_test.sh <adb> <serial> <web-view .apk> <out>
set -uo pipefail
# Nothing here reads standard input, and adb mustn't either (android_test.sh).
exec < /dev/null
adb="$1" serial="$2" apk="$3" out="$4"
mkdir -p "$out"
BUNDLE=com.LoganShire.IsomerExamples.WebView
STORY=state.observableobject
a() { "$adb" -s "$serial" "$@"; }
# The screen's views (uiautomator's dump), on standard output.
screen() {
    a shell uiautomator dump /sdcard/webview-ui.xml >/dev/null 2>&1 &&
        a exec-out cat /sdcard/webview-ui.xml 2>/dev/null
}
# Waits up to $2 seconds for text $1 on the screen; the last dump in $out.
wait_for() {
    local text="$1" until=$((SECONDS + $2))
    while [ $SECONDS -lt $until ]; do
        screen >"$out/webview-ui.xml"
        grep -q "text=\"$text\"" "$out/webview-ui.xml" && return 0
        sleep 2
    done
    return 1
}
# The page's start, from its log: the session's own line and the host's.
starts() { a logcat -d -s Isomer:I 2>/dev/null | grep -E "\[session\] the app's first frame|\[webview\]"; }
launch() {
    a shell am force-stop "$BUNDLE"
    a logcat -c
    a shell am start -W -n "$BUNDLE/.MainActivity" -e ISO_STORYBOOK_STORY "$STORY" "$@" >/dev/null
}

a install -r "$apk" >/dev/null || { echo "android_webview_test: the install failed" >&2; exit 1; }
a shell cmd uimode night no >/dev/null 2>&1
# The first launch: the page's caches empty (a fresh install keeps none).
a shell pm clear "$BUNDLE" >/dev/null
launch
failure=""
if ! wait_for "Taps: 0" 90; then
    failure="the story never drew \"Taps: 0\""
else
    bounds="$(grep -o '<node [^>]*text="Tap"[^>]*>' "$out/webview-ui.xml" | head -1 | grep -o 'bounds="[^"]*"')"
    read -r x1 y1 x2 y2 <<<"$(sed -E 's/bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/' <<<"$bounds")"
    if [ -z "${y2:-}" ]; then
        failure="no Tap button on the screen"
    else
        a shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
        wait_for "Taps: 1" 30 || failure="the tap didn't change the count"
    fi
fi
a exec-out screencap -p >"$out/android-webview-$STORY.png"
starts >"$out/starts.txt"
a logcat -d >"$out/logcat-first.txt" 2>/dev/null
if [ -n "$failure" ]; then
    echo "android_webview_test: $failure" >&2
    exit 1
fi
echo "android_webview_test: $STORY drew, and a tap changed it"

# Cold starts: with the reactor's code cache as the first launch left it,
# then without the page's Cache Storage, to compare.
for run in 1 2 3; do
    launch
    wait_for "Taps: 0" 60 || echo "android_webview_test: a cold start ($run) didn't draw" >&2
    { echo "cold start $run:"; starts; } >>"$out/starts.txt"
done
for run in 1 2; do
    launch -e reactorCache 0
    wait_for "Taps: 0" 60 || echo "android_webview_test: a cold start without the cache ($run) didn't draw" >&2
    { echo "cold start $run, reactorCache=0:"; starts; } >>"$out/starts.txt"
done
a shell am force-stop "$BUNDLE"
cat "$out/starts.txt"
exit 0
