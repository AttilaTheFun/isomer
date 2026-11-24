#!/bin/bash
# The Storybook in web-view mode on a phone reached by adb (docs/modes.md;
# //android/webview_android_application: its Swift as wasm in a WebView the
# app keeps out of sight, drawn by the Compose renderer over the session).
# Opened on state.observableobject, the story's "Taps: 0" must be drawn, a
# tap on its Tap button must make it "Taps: 1" (the event through the page,
# the app's next frame back), as //tests/webview_session does in Chrome. The
# page sent off its site must be refused with the session going on, and the
# page's renderer crashed must bring a new web view and session that draw
# and take a tap (the app's debug hooks, IsomerWebViewHost.debugCommand).
# Then the app is started cold a few more times, and how long its page took each
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
# The story's view is below its code on the page: until its count is on the
# screen, each look scrolls the page up by about half a screen.
wait_for() {
    local text="$1" until=$((SECONDS + $2))
    while [ $SECONDS -lt $until ]; do
        screen >"$out/webview-ui.xml"
        grep -q "text=\"$text\"" "$out/webview-ui.xml" && return 0
        grep -q "text=\"Taps: " "$out/webview-ui.xml" || a shell input swipe 540 1600 540 600 300
        sleep 2
    done
    return 1
}
# Taps the story's Tap button, once it is on the screen: the count can be
# on the screen with the button still below it (the story's field between
# them), so each look without it scrolls up by a third of a screen. False
# when it never shows.
tap_button() {
    local bounds x1 y1 x2 y2 look
    for look in 1 2 3 4; do
        bounds="$(grep -o '<node [^>]*text="Tap"[^>]*>' "$out/webview-ui.xml" | head -1 | grep -o 'bounds="[^"]*"')"
        read -r x1 y1 x2 y2 <<<"$(sed -E 's/bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/' <<<"$bounds")"
        if [ -n "${y2:-}" ]; then
            a shell input tap $(((x1 + x2) / 2)) $(((y1 + y2) / 2))
            return 0
        fi
        a shell input swipe 540 1600 540 900 300
        sleep 1
        screen >"$out/webview-ui.xml"
    done
    return 1
}
# Taps the story's Tap button and waits for "Taps: <$1>".
tap_count() {
    wait_for "Taps: $(($1 - 1))" 30 || return 1
    tap_button || return 1
    wait_for "Taps: $1" 30
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
elif ! tap_button; then
    failure="no Tap button on the screen"
else
    wait_for "Taps: 1" 30 || failure="the tap didn't change the count"
fi
# The page sent off the site (its own script, isomerDebug navigateAway):
# refused, and the session goes on (a second tap counts).
if [ -z "$failure" ]; then
    a shell am start -n "$BUNDLE/.MainActivity" --es isomerDebug navigateAway >/dev/null
    tap_count 2 || failure="after a navigation off the site, the tap didn't count"
    a logcat -d -s Isomer:W 2>/dev/null | grep -q "refused a navigation off the site" ||
        { [ -n "$failure" ] || failure="the navigation off the site was not refused"; }
fi
# The page's renderer gone (isomerDebug crashRenderer, chrome://crash): the
# app destroys its web view, makes a new one and a new session, whose story
# starts again at "Taps: 0", and a tap there counts.
if [ -z "$failure" ]; then
    a shell am start -n "$BUNDLE/.MainActivity" --es isomerDebug crashRenderer >/dev/null
    if ! wait_for "Taps: 0" 90; then
        failure="after its renderer went, the app didn't draw again"
    else
        tap_count 1 || failure="after its renderer went, the tap didn't count"
    fi
    a logcat -d -s Isomer:W 2>/dev/null | grep -q "the page's renderer went" ||
        { [ -n "$failure" ] || failure="the app drew, but its log says no renderer went"; }
    [ -n "$(a shell pidof "$BUNDLE")" ] || { [ -n "$failure" ] || failure="the app ended with its renderer"; }
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
