#!/bin/bash
# An iPhone app on a booted simulator, headful, for a test's HeadlessApp
# (docs/drive.md): built with --@isomer//drive:headful, so its driver dials
# out, launched with ISO_DRIVER and ISO_DRIVER_NAME (simctl's
# SIMCTL_CHILD_), until this is stopped (SIGTERM, or HeadlessApp's `stop`
# request). Pictures (a test's `picture`) are simctl's, masked (the
# simulator's own status bar is held at 9:41 by whoever made the
# simulator), turned to the app's interface: an app that turns itself to
# landscape on an upright simulator is pictured on its side, as a person
# turning the phone sees it. HeadlessApp's `scene` (requests.sh) is the
# phone's own: background sends the app home, active brings it back to the
# front, the same process with its state, as its icon does (inactive is the
# driver's); and a command left unanswered (`wake`) brings back an app iOS
# has suspended, as one that opened another app (Safari, for a link) is.
#
#   ios_launcher.sh <the hub's ws:// URL> <the app's name> [KEY=VALUE…] [-- <argument>…]
#
# The arguments after `--` are the app's own (simctl launch's).
# From the test's environment: ISOMER_SIMULATOR (a booted simulator's
# UDID), ISOMER_BUNDLE_ID (the app installed on it) and ISOMER_FRESH
# (requests.sh: 1, the default, starts the app with none of its data from
# before). ISO_HEADLESS_WIDTH and ISO_HEADLESS_HEIGHT are a headless
# window's, not a phone's: left out.
set -uo pipefail
. "$(dirname "$0")/requests.sh"
url="${1:?usage: ios_launcher.sh <hub url> <name> [KEY=VALUE…]}"
name="${2:?<name>}"
shift 2
udid="${ISOMER_SIMULATOR:?ISOMER_SIMULATOR: a booted simulator}"
bundle="${ISOMER_BUNDLE_ID:?ISOMER_BUNDLE_ID: the app installed on it}"
split_arguments "$@"
environment=(SIMCTL_CHILD_ISO_DRIVER="$url" SIMCTL_CHILD_ISO_DRIVER_NAME="$name")
for pair in ${pairs[@]+"${pairs[@]}"}; do
    case "${pair%%=*}" in
        ISO_HEADLESS_WIDTH | ISO_HEADLESS_HEIGHT) ;;
        *) environment+=("SIMCTL_CHILD_$pair") ;;
    esac
done
stop() { xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1 || true; exit 0; }
trap stop TERM INT
# From the home screen: an app opened over another (Safari, left in front
# by a test before) shows a "◀" link back to it in the status bar.
xcrun simctl launch "$udid" com.apple.springboard > /dev/null 2>&1
if fresh; then
    # The app's data as an install leaves it: its defaults, each domain
    # deleted through the simulator's cfprefsd by its file's path (the
    # domain the app's container holds: by name, `defaults` reaches the
    # simulator's own, and a file removed under cfprefsd comes back from its
    # cache), then its files and its app groups' (the containers themselves
    # kept, with their metadata), and the simulator's keychain (an app's
    # items outlive it, as on a phone). The simulator is the test's: nothing
    # else of its is touched.
    xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1
    clear_container() {
        [ -n "$1" ] && [ -d "$1" ] || return 0
        local plist
        for plist in "$1/Library/Preferences/"*.plist; do
            [ -e "$plist" ] && xcrun simctl spawn "$udid" defaults delete "${plist%.plist}" > /dev/null 2>&1
        done
        rm -rf "$1/Documents/"* "$1/Library/Application Support" "$1/Library/Caches" "$1/Library/Preferences/"* \
            "$1/Library/SplashBoard" "$1/tmp/"* 2> /dev/null
    }
    clear_container "$(xcrun simctl get_app_container "$udid" "$bundle" data 2> /dev/null)"
    xcrun simctl get_app_container "$udid" "$bundle" groups 2> /dev/null | while IFS=$'\t' read -r group path; do
        clear_container "$path"
    done
    xcrun simctl keychain "$udid" reset > /dev/null 2>&1
fi
# The app's output kept with the test's (an app that never attached says why
# there; ISO_DRIVE_TRACE=1, simctl's SIMCTL_CHILD_ISO_DRIVE_TRACE, prints
# the driver's walk of its accessibility tree).
log="${TEST_UNDECLARED_OUTPUTS_DIR:-${TMPDIR:-/tmp}}/$name.log"
# (From when the simulator's log is read for RunningBoard's word on it:
# `suspended`.)
started="$(date '+%Y-%m-%d %H:%M:%S')"
launched="$(env "${environment[@]}" xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" \
    "$udid" "$bundle" ${app_arguments[@]+"${app_arguments[@]}"})" || exit 1
# simctl's "<bundle>: <pid>": the process the test drives.
pid="${launched##*: }"
# Whether the launcher sent the app home (`scene background`).
away=0
# Whether iOS has suspended the app (seconds after it leaves the screen, a
# background task aside), so that it answers nothing: RunningBoard's jetsam
# state, which launchctl shows root alone (sudo where it asks no password,
# as on GitHub's Macs and Shireworks' VMs); else what RunningBoard last
# logged of the process in the simulator's own log ("Suspending task." or
# "Resuming task.", read as any user in a second or so: a Shireworks slot
# asks a password for sudo, and there an app's scheduling priority can stay
# where it was as it is suspended); else that priority, which drops to 4
# (darwin background) as it is suspended.
suspended() {
    local info last priority
    if info="$(sudo -n launchctl procinfo "$pid" 2> /dev/null)" && grep -q "^jetsam state" <<< "$info"; then
        grep -q "^jetsam state = suspended" <<< "$info"
        return
    fi
    if info="$(xcrun simctl spawn "$udid" log show --start "$started" --style compact --predicate \
        "process == \"runningboardd\" AND eventMessage CONTAINS \":$pid] \" AND (eventMessage ENDSWITH \"Suspending task.\" OR eventMessage ENDSWITH \"Resuming task.\")" \
        2> /dev/null)"; then
        last="$(grep -E '(Suspending|Resuming) task\.$' <<< "$info" | tail -1)"
        [[ "$last" == *"Suspending task." ]]
        return
    fi
    priority="$(ps -o pri= -p "$pid" 2> /dev/null | tr -d ' ')"
    [ -n "$priority" ] && [ "$priority" -le 4 ]
}
# The app brought to the front from wherever it went: the home screen
# first (an app opened over another shows a "◀" link back to it in the
# status bar), then the app as its icon opens it: the same process,
# resumed, its scene through inactive to active. simctl's launch without
# --terminate-running-process starts no other.
bring_forward() {
    local now
    xcrun simctl launch "$udid" com.apple.springboard > /dev/null 2>&1
    now="$(xcrun simctl launch "$udid" "$bundle" 2> /dev/null)" || return 1
    away=0
    if [ "${now##*: }" != "$pid" ]; then
        # (iOS ended it while it was away: a new process, which no driver
        # of the test's is attached to.)
        echo "ios_launcher: $bundle started again (pid ${now##*: }, was $pid): what it held is gone" >&2
        pid="${now##*: }"
    fi
    # Until it runs again (at most 5 s; a check can take a second).
    local until=$((SECONDS + 5))
    while [ "$SECONDS" -lt "$until" ]; do
        suspended || return 0
        sleep 0.1
    done
    return 0
}
# HeadlessApp's `scene` (requests.sh). Background: home, as the home
# gesture goes (SpringBoard opened), until iOS suspends the app (at most
# 3 s), answered `ok away`: the app answers nothing there, so the test asks
# it nothing until it is back. Active: brought back if it was sent home or
# is suspended (another app opened over it: Safari, for a link), or is
# suspended within a moment (iOS suspends an app a second or so after
# another opens over it; an app in front waits that out); else it is in
# front: opened as its icon opens it all the same (nothing moves for an app
# in front; one still behind another comes forward), and left to the
# driver, which moves the phase from inactive (its own) to active. An app
# brought back is answered `ok`, and HeadlessApp has its driver make the
# phase active then too: iOS can leave a scene brought back from the home
# screen inactive (seen on a Shireworks slot, whose simulators no
# Simulator.app shows), and the driver finishes the step (nothing moves
# where the phase is active already). Inactive: the driver's (iOS has no
# way to it from here).
scene() {
    case "$1" in
    background)
        xcrun simctl launch "$udid" com.apple.springboard > /dev/null || return 1
        away=1
        local until=$((SECONDS + 3))
        while [ "$SECONDS" -lt "$until" ]; do
            suspended && break
            sleep 0.1
        done
        scene_answer="ok away"
        ;;
    active)
        local until=$((SECONDS + 2))
        until [ "$away" = 1 ] || suspended; do
            if [ "$SECONDS" -ge "$until" ]; then
                xcrun simctl launch "$udid" "$bundle" > /dev/null 2>&1
                return 1
            fi
            sleep 0.1
        done
        bring_forward || return 1
        ;;
    *) return 1 ;;
    esac
}
# A command the app hasn't answered for a while (HeadlessApp's `wake`):
# brought to the front if iOS has suspended it; otherwise it is working (a
# long `wait`), or hung, which the test's own timeout says.
wake() {
    suspended || return 0
    echo "ios_launcher: $bundle was suspended (a command waiting on it): brought to the front" >&2
    bring_forward
}
# A picture, turned from the simulator's upright frame to the interface's
# orientation (the app's driver says which, in the request) when the two
# differ: sips turns clockwise, so landscape-right (the home indicator on
# the right, the phone turned anticlockwise) is 270.
take() {
    local path="$1" orientation="${2:-}" turn="" width height
    xcrun simctl io "$udid" screenshot --mask=black "$path" > /dev/null 2>&1 || return 1
    case "$orientation" in
        landscape-right) turn=270 ;;
        landscape-left) turn=90 ;;
        *) return 0 ;;
    esac
    width="$(sips -g pixelWidth "$path" 2> /dev/null | awk '/pixelWidth/ { print $2 }')"
    height="$(sips -g pixelHeight "$path" 2> /dev/null | awk '/pixelHeight/ { print $2 }')"
    # Already as the interface stands (a simulator turned with the app).
    [ "${width:-0}" -gt "${height:-0}" ] && return 0
    sips -r "$turn" "$path" > /dev/null 2>&1
}
serve_requests take
