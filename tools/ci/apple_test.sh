#!/bin/bash
# The iPhone and Mac Storybooks on Shireworks' primary macOS VM, as CI tests
# them: built in the Linux container (rules_applecross), each run where it
# runs: the iPhone app on an `ios` lease (a simulator inside the primary,
# its status bar held at 9:41), the Mac app on a `mac` slot of the primary
# (`exec --gui` in its console session, pictured by `screenshot --window`).
# Each story opened at launch (ISO_STORYBOOK_STORY), pictured once two
# pictures in a row agree, and checked for having drawn something; the
# pictures kept in <out>. Both leases released however it ends. All through
# Shireworks' API (tools/ci/shireworks.sh): it runs in a CI job's Linux
# container as on a Mac.
#
#   tools/ci/apple_test.sh <storybook_ios_sim_application .ipa> <storybook_macos_application .zip> <out> <story>…
set -uo pipefail
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
ipa="$(absolute "$1")" macos_zip="$(absolute "$2")"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
shift 3
work="$(mktemp -d)"
sw="$(cd "$(dirname "$0")" && pwd)/shireworks.sh"
ios="" mac="" run=""
BUNDLE=com.LoganShire.IsomerStorybook
cleanup() {
    [ -n "$ios" ] && "$sw" release "$ios" >/dev/null 2>&1
    if [ -n "$mac" ]; then
        command -v mac_stop >/dev/null && mac_stop
        "$sw" release "$mac" >/dev/null 2>&1
    fi
    rm -rf "$work"
}
trap cleanup EXIT
lease_id() { (eval "$("$sw" lease "$@")" && printf '%s' "${SHIREWORKS_ID:-}"); }
# A picture of almost nothing (one colour compresses to a few KB): nothing drawn.
drawn() {
    [ -s "$1" ] && [ "$(wc -c <"$1")" -gt 20000 ]
}
# Two pictures in a row alike, at most a few more tries. A shot that fails
# (the window between frames, on a screen another run shares) is one more try.
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

# The iPhone.
ios="$(lease_id ios --kind=ci --label="Isomer: the iPhone Storybook's tests")"
if [ -z "$ios" ]; then echo "apple_test: no ios lease" >&2; exit 1; fi
# Installed from Shireworks' storage, which unpacks the .ipa itself: simctl
# install of a local .app would zip it here with ditto, which only a Mac has.
object="$("$sw" storage-put "$ipa" --ttl=2h | sed -n 's/.*"sha256" *: *"\([0-9a-f]*\)".*/\1/p' | head -1)"
if [ -z "$object" ]; then echo "apple_test: the .ipa didn't reach Shireworks' storage" >&2; exit 1; fi
"$sw" install "$ios" "$object" || exit 1
"$sw" simctl "$ios" ui booted appearance light >/dev/null 2>&1
ios_shot() { "$sw" screenshot "$ios" "$1" >/dev/null; }
for story in "$@"; do
    "$sw" simctl "$ios" terminate booted "$BUNDLE" >/dev/null 2>&1
    "$sw" simctl "$ios" --env=ISO_STORYBOOK_STORY="$story" launch booted "$BUNDLE" >/dev/null ||
        { echo "apple_test: ios $story: didn't launch" >&2; failures=$((failures + 1)); continue; }
    sleep 4
    if steady ios_shot "$out/ios-$story.png" && drawn "$out/ios-$story.png"; then
        echo "apple_test: ios $story"
    else
        echo "apple_test: ios $story: nothing drawn" >&2
        failures=$((failures + 1))
    fi
done
"$sw" release "$ios" >/dev/null 2>&1
ios=""

# The Mac.
mac="$(lease_id mac --kind=ci --label="Isomer: the Mac Storybook's tests")"
if [ -z "$mac" ]; then echo "apple_test: no mac slot" >&2; exit 1; fi
"$sw" put "$mac" "$macos_zip" storybook.zip >/dev/null || exit 1
"$sw" run "$mac" -- /bin/sh -c 'rm -rf Storybook.app && /usr/bin/ditto -x -k storybook.zip . && rm storybook.zip' || exit 1
home="$("$sw" run "$mac" -- /bin/sh -c 'printf %s "$HOME"')"
# One GUI run for every story, as the proof's (the primary's screen is one
# `--gui` run at a time, and an app left running holds it): stories are
# switched through the Storybook's control file, and the app is ended by
# its own launcher when `stop` appears, whether or not the server ends the
# exec's processes when its client goes. The slot's user makes the folder;
# the console user's app writes in it (its home, the control's `.shown`).
dir="/tmp/isomer-test-$mac"
"$sw" run "$mac" -- /bin/sh -c 'rm -rf "$1" && mkdir -p "$1/home" && chmod 777 "$1" "$1/home"' dir "$dir" || exit 1
launch='app=$1; dir=$2; shift 2
"$app/Contents/MacOS/Storybook" "$@" &
pid=$!
sleep 2
kill -0 "$pid" 2> /dev/null && /usr/bin/open "$app"
while kill -0 "$pid" 2> /dev/null; do
    [ -e "$dir/stop" ] && { kill "$pid"; break; }
    sleep 1
done
wait "$pid"'
mac_stop() {
    "$sw" run "$mac" -- /bin/sh -c 'touch "$1/stop"' stop "$dir" >/dev/null 2>&1
    [ -n "$run" ] && { sleep 3; kill "$run" 2>/dev/null; wait "$run" 2>/dev/null; run=""; }
}
mac_shot() { "$sw" screenshot "$mac" "$1" --window="$BUNDLE" >/dev/null; }
"$sw" run "$mac" --gui --env=ISO_STORYBOOK_CONTROL="$dir/control" --env=CFFIXED_USER_HOME="$dir/home" -- \
    /bin/sh -c "$launch" launch "$home/Storybook.app" "$dir" -AppleInterfaceStyle Light -NSRequiresAquaSystemAppearance YES \
    -AppleShowScrollBars WhenScrolling -ApplePersistenceIgnoreState YES >"$work/mac.log" 2>&1 &
run=$!
# Its window once the screen is this slot's turn (another job's run may hold it).
for _ in $(seq 1 180); do
    mac_shot "$work/window.png" 2>/dev/null && break
    kill -0 "$run" 2>/dev/null || { echo "apple_test: the Mac Storybook ended before its window showed:" >&2; cat "$work/mac.log" >&2; exit 1; }
    sleep 5
done
for story in "$@"; do
    "$sw" run "$mac" -- /bin/sh -c 'printf %s "$2" > "$1/control"' request "$dir" "$story" >/dev/null
    shown=""
    for _ in $(seq 1 30); do
        sleep 1
        shown="$("$sw" run "$mac" -- /bin/sh -c 'cat "$1/control.shown" 2>/dev/null' shown "$dir")"
        [ "$shown" = "$story" ] && break
    done
    sleep 2
    if [ "$shown" = "$story" ] && steady mac_shot "$out/macos-$story.png" && drawn "$out/macos-$story.png"; then
        echo "apple_test: macos $story"
    else
        echo "apple_test: macos $story: nothing drawn (shown: ${shown:-none})" >&2
        failures=$((failures + 1))
    fi
done
mac_stop
echo "apple_test: $(( $# * 2 )) pictures, $failures failed"
[ $failures -eq 0 ]
