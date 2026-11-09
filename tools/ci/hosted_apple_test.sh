#!/bin/bash
# The iPhone and Mac Storybooks' test stories on GitHub's own `xcode-27` Mac
# runner (free for a public repository), the primary place CI runs them; a
# private copy runs them on Shireworks' leases instead (tools/ci/apple_test.sh,
# platform_tests.sh). The apps are the ones CI's container built
# (tools/ci/container_build.sh): the iPhone's on a simulator made for the
# run (an iPhone 17 of the newest iOS this Xcode has, its status bar held at
# 9:41), the Mac's on this Mac's own screen, each story opened at launch
# (ISO_STORYBOOK_STORY), pictured once two pictures in a row agree (the
# Mac's by its window alone), and checked for having drawn something; the
# pictures kept in <out>.
#
#   tools/ci/hosted_apple_test.sh <storybook_ios_sim_application .ipa> <storybook_macos_application .zip> <out>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
ipa="$(absolute "${1:?usage: hosted_apple_test.sh <.ipa> <.zip> <out>}")"
macos_zip="$(absolute "${2:?<.zip>}")"
mkdir -p "${3:?<out>}"
out="$(cd "$3" && pwd)"
stories=($(sed -n 's/^ *"\([a-z]*\.[a-z]*\)",$/\1/p' "$ROOT/examples/tests/platforms/stories.bzl"))
[ ${#stories[@]} -gt 0 ] || { echo "hosted_apple_test: no stories" >&2; exit 1; }
BUNDLE=com.LoganShire.IsomerStorybook
work="$(mktemp -d)"
udid="" pid=""
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
    if [ -n "$udid" ]; then
        xcrun simctl shutdown "$udid" >/dev/null 2>&1
        xcrun simctl delete "$udid" >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT
# A picture of almost nothing (one colour compresses to a few KB): nothing drawn.
drawn() {
    [ -s "$1" ] && [ "$(wc -c <"$1")" -gt 20000 ]
}
# Two pictures in a row alike, at most a few more tries.
steady() {
    local shoot="$1" path="$2" tries=0
    until $shoot "$path"; do
        tries=$((tries + 1)); [ $tries -lt 5 ] || return 1; sleep 2
    done
    for _ in 1 2 3 4 5; do
        sleep 2
        $shoot "$path.again.png" || continue
        if cmp -s "$path" "$path.again.png"; then rm -f "$path.again.png"; return 0; fi
        mv "$path.again.png" "$path"
    done
}
failures=0

# The iPhone: a simulator of the run's own.
device="${HOSTED_IOS_DEVICE:-iPhone 17}"
runtime="$(xcrun simctl list runtimes iOS available | sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1)"
[ -n "$runtime" ] || { echo "hosted_apple_test: no iOS runtime on this Mac" >&2; exit 1; }
udid="$(xcrun simctl create "isomer-test-$$" "$device" "$runtime")" || exit 1
xcrun simctl boot "$udid" && xcrun simctl bootstatus "$udid" -b >/dev/null || exit 1
xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
xcrun simctl ui "$udid" appearance light
mkdir -p "$work/ios" && unzip -q "$ipa" -d "$work/ios" || exit 1
xcrun simctl install "$udid" "$work/ios/Payload/"*.app || exit 1
ios_shot() { xcrun simctl io "$udid" screenshot --mask=black "$1" >/dev/null 2>&1; }
for story in "${stories[@]}"; do
    xcrun simctl terminate "$udid" "$BUNDLE" >/dev/null 2>&1
    SIMCTL_CHILD_ISO_STORYBOOK_STORY="$story" xcrun simctl launch "$udid" "$BUNDLE" >/dev/null ||
        { echo "hosted_apple_test: ios $story: didn't launch" >&2; failures=$((failures + 1)); continue; }
    sleep 4
    if steady ios_shot "$out/ios-$story.png" && drawn "$out/ios-$story.png"; then
        echo "hosted_apple_test: ios $story"
    else
        echo "hosted_apple_test: ios $story: nothing drawn" >&2
        failures=$((failures + 1))
    fi
done
xcrun simctl shutdown "$udid" >/dev/null 2>&1
xcrun simctl delete "$udid" >/dev/null 2>&1
udid=""

# The Mac: this Mac's own screen, the app's window pictured alone.
ditto -x -k "$macos_zip" "$work/mac" || exit 1
app="$(ls -d "$work/mac/"*.app | head -1)"
binary="$app/Contents/MacOS/$(defaults read "$app/Contents/Info" CFBundleExecutable)"
mkdir -p "$work/home"
cat > "$work/window.js" <<'EOF'
ObjC.import('CoreGraphics');
function run(argv) {
  const pid = Number(argv[0]);
  const list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(
    $.kCGWindowListOptionOnScreenOnly | $.kCGWindowListExcludeDesktopElements, 0));
  let number = '', area = 0;
  for (let i = 0; i < list.count; i++) {
    const w = list.objectAtIndex(i);
    if (ObjC.unwrap(w.objectForKey('kCGWindowOwnerPID')) !== pid) continue;
    if (ObjC.unwrap(w.objectForKey('kCGWindowLayer')) !== 0) continue;
    const b = w.objectForKey('kCGWindowBounds');
    const a = ObjC.unwrap(b.objectForKey('Width')) * ObjC.unwrap(b.objectForKey('Height'));
    if (a > area) { area = a; number = String(ObjC.unwrap(w.objectForKey('kCGWindowNumber'))); }
  }
  return number;
}
EOF
# No "quit unexpectedly" dialog over the next story after a crash.
defaults write com.apple.CrashReporter DialogType -string none
mac_shot() {
    local number
    number="$(osascript -l JavaScript "$work/window.js" "$pid" 2>/dev/null)"
    [ -n "$number" ] && screencapture -x -o -l "$number" "$1"
}
for story in "${stories[@]}"; do
    ISO_STORYBOOK_STORY="$story" CFFIXED_USER_HOME="$work/home" "$binary" -AppleInterfaceStyle Light \
        -NSRequiresAquaSystemAppearance YES -AppleShowScrollBars WhenScrolling -ApplePersistenceIgnoreState YES \
        >"$work/mac-$story.log" 2>&1 &
    pid=$!
    sleep 2
    # Frontmost, as the Dock opens an app.
    open "$app"
    for _ in $(seq 1 30); do
        [ -n "$(osascript -l JavaScript "$work/window.js" "$pid" 2>/dev/null)" ] && break
        sleep 1
    done
    sleep 3
    if steady mac_shot "$out/macos-$story.png" && drawn "$out/macos-$story.png"; then
        echo "hosted_apple_test: macos $story"
    else
        echo "hosted_apple_test: macos $story: nothing drawn" >&2
        tail -5 "$work/mac-$story.log" >&2
        failures=$((failures + 1))
    fi
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    pid=""
done
echo "hosted_apple_test: $(( ${#stories[@]} * 2 )) pictures, $failures failed"
[ $failures -eq 0 ]
