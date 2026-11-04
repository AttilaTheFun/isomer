#!/bin/bash
# The iPhone and Mac Storybooks on OS Server's primary macOS VM, as CI tests
# them: built in the Linux container (rules_applecross), each run where it
# runs: the iPhone app on an `ios` lease (a simulator inside the primary,
# its status bar held at 9:41), the Mac app on a `mac` slot of the primary
# (`exec --gui` in its console session, pictured by `screenshot --window`).
# Each story opened at launch (ISO_STORYBOOK_STORY), pictured once two
# pictures in a row agree, and checked for having drawn something; the
# pictures kept in <out>. Both leases released however it ends. All through
# oss's API: it runs in a CI job's Linux container as on a Mac.
#
#   tools/ci/apple_test.sh <storybook_ios_sim_application .ipa> <storybook_macos_application .zip> <out> <story>…
set -uo pipefail
absolute() { printf '%s/%s' "$(cd "$(dirname "$1")" && pwd)" "$(basename "$1")"; }
ipa="$(absolute "$1")" macos_zip="$(absolute "$2")"
mkdir -p "$3"
out="$(cd "$3" && pwd)"
shift 3
work="$(mktemp -d)"
ios="" mac=""
BUNDLE=com.LoganShire.IsomerStorybook
cleanup() {
    [ -n "$ios" ] && oss machine release "$ios" >/dev/null 2>&1
    [ -n "$mac" ] && oss machine release "$mac" >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT
lease_id() { oss machine lease "$@" --wait --json | sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1; }
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
# Installed from OS Server's storage, which unpacks the .ipa itself: simctl
# install of a local .app would zip it here with ditto, which only a Mac has.
object="$(oss storage put "$ipa" --ttl=2h --json | sed -n 's/.*"sha256" *: *"\([0-9a-f]*\)".*/\1/p' | head -1)"
if [ -z "$object" ]; then echo "apple_test: the .ipa didn't reach OS Server's storage" >&2; exit 1; fi
oss machine install "$ios" "$object" || exit 1
oss machine simctl "$ios" ui booted appearance light >/dev/null 2>&1
ios_shot() { oss machine screenshot "$ios" "$1" >/dev/null; }
for story in "$@"; do
    oss machine simctl "$ios" terminate booted "$BUNDLE" >/dev/null 2>&1
    oss machine simctl "$ios" --env=ISO_STORYBOOK_STORY="$story" -- launch booted "$BUNDLE" >/dev/null ||
        { echo "apple_test: ios $story: didn't launch" >&2; failures=$((failures + 1)); continue; }
    sleep 4
    if steady ios_shot "$out/ios-$story.png" && drawn "$out/ios-$story.png"; then
        echo "apple_test: ios $story"
    else
        echo "apple_test: ios $story: nothing drawn" >&2
        failures=$((failures + 1))
    fi
done
oss machine release "$ios" >/dev/null 2>&1
ios=""

# The Mac.
mac="$(lease_id mac --kind=ci --label="Isomer: the Mac Storybook's tests")"
if [ -z "$mac" ]; then echo "apple_test: no mac slot" >&2; exit 1; fi
oss machine upload "$mac" "$macos_zip" storybook.zip >/dev/null || exit 1
oss machine exec "$mac" -- /bin/sh -c 'rm -rf Storybook.app && /usr/bin/ditto -x -k storybook.zip . && rm storybook.zip' || exit 1
home="$(oss machine exec "$mac" -- /bin/sh -c 'printf %s "$HOME"')"
mac_shot() { oss machine screenshot "$mac" "$1" --window="$BUNDLE" >/dev/null; }
for story in "$@"; do
    oss machine exec "$mac" --gui --env=ISO_STORYBOOK_STORY="$story" --env=CFFIXED_USER_HOME="$home/test-home" -- \
        "$home/Storybook.app/Contents/MacOS/Storybook" -AppleInterfaceStyle Light -NSRequiresAquaSystemAppearance YES \
        -AppleShowScrollBars WhenScrolling -ApplePersistenceIgnoreState YES >"$work/mac.log" 2>&1 &
    run=$!
    # The primary's screen is one `--gui` run at a time: another job's may
    # hold it, and this one's app starts only when it's let go.
    for _ in $(seq 1 60); do
        sleep 5
        mac_shot "$out/macos-$story.png" 2>/dev/null && break
    done
    sleep 3
    if steady mac_shot "$out/macos-$story.png" && drawn "$out/macos-$story.png"; then
        echo "apple_test: macos $story"
    else
        echo "apple_test: macos $story: nothing drawn" >&2
        failures=$((failures + 1))
    fi
    kill "$run" 2>/dev/null
    wait "$run" 2>/dev/null
done
echo "apple_test: $(( $# * 2 )) pictures, $failures failed"
[ $failures -eq 0 ]
