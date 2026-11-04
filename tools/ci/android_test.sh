#!/bin/bash
# The Android Storybook's stories on a phone in this container
# (android_device.sh): installed, each story opened by its link
# (iso://story/<id>, a VIEW intent to the running app, as the proof does),
# pictured by screencap once two pictures in a row agree, and checked for
# having drawn; the pictures kept in <out>.
#
#   tools/ci/android_test.sh <adb> <serial> <storybook .apk> <out> <story>…
set -uo pipefail
adb="$1" serial="$2" apk="$3" out="$4"
shift 4
mkdir -p "$out"
BUNDLE=com.LoganShire.IsomerStorybook
a() { "$adb" -s "$serial" "$@"; }
a install -r "$apk" >/dev/null || { echo "android_test: the install failed" >&2; exit 1; }
a shell cmd uimode night no >/dev/null 2>&1
a shell am start -W -n "$BUNDLE/.MainActivity" >/dev/null
sleep 10
shot() { a exec-out screencap -p >"$1"; }
failures=0
for story in "$@"; do
    a shell am start -a android.intent.action.VIEW -d "iso://story/$story" "$BUNDLE" >/dev/null
    sleep 4
    shot "$out/android-$story.png"
    for _ in 1 2 3 4 5; do
        sleep 2
        shot "$out/again.png"
        cmp -s "$out/android-$story.png" "$out/again.png" && break
        mv "$out/again.png" "$out/android-$story.png"
    done
    rm -f "$out/again.png"
    if [ "$(stat -c %s "$out/android-$story.png" 2>/dev/null || echo 0)" -gt 20000 ] &&
        [ -n "$(a shell pidof "$BUNDLE")" ]; then
        echo "android_test: $story"
    else
        echo "android_test: $story: nothing drawn, or the app ended" >&2
        failures=$((failures + 1))
    fi
done
echo "android_test: $# stories, $failures failed"
[ $failures -eq 0 ]
