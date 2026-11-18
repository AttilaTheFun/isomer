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
# What the launcher's children leave to be read (a launch's "<bundle>:
# <pid>", launchctl's and the log's readings): files, not command
# substitutions, which the shell waits on as it waits on a child in front.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/ios_launcher.XXXXXX")"
# The launcher's own word, whatever a call's stderr is sent to.
exec 3>&2
# The child `bounded` waits on.
child=""
# A wake's bringing the app forward, in the background, and since when;
# and every wake's still running, which `stop` ends.
waking=""
wakers=""
waking_since=0
wakes=0
# A child command, given at most <seconds>: run in the background and
# waited for a tenth of a second at a time, so that SIGTERM's trap (`stop`)
# runs at once (bash runs a trap only once the child in front returns), and
# ended (TERM, then KILL) if it overruns, said so (with the Mac's load),
# 124 returned. simctl can stop answering (SpringBoard busy: a cold Safari
# opening) and so can launchctl; a launcher stuck in one answered no more
# requests and woke the app no more, so its test's command went unanswered
# until it timed out, and the launcher outlived its test until HeadlessApp's
# SIGKILL. The deadlines are for a call that hangs, not one that is slow:
# on GitHub's Mac runners a simctl launch can take more than 15 s, and
# launchctl more than 5, for minutes on end, and a SpringBoard launch ended
# early sent the app nowhere. The child leads a process group of its own
# (monitor mode, for the moment it starts), and it is ended as a group, so
# what it started goes with it (simctl, should xcrun not exec it; a test's
# fake xcrun's own children).
#
#   bounded <seconds> <what> <command>…
bounded() {
    local seconds="$1" what="$2" until status
    shift 2
    set -m
    "$@" &
    child=$!
    set +m
    until=$((SECONDS + seconds))
    while kill -0 "$child" 2> /dev/null; do
        if [ "$SECONDS" -ge "$until" ]; then
            kill -TERM -- -"$child" 2> /dev/null
            sleep 0.2
            kill -KILL -- -"$child" 2> /dev/null
            wait "$child" 2> /dev/null
            child=""
            echo "ios_launcher: $(date +%T) $what gave no answer in $seconds s: ended (load $(sysctl -n vm.loadavg 2> /dev/null))" >&3
            return 124
        fi
        sleep 0.1
    done
    wait "$child"
    status=$?
    child=""
    return $status
}
# A simctl call given a minute, and a minute again if it was ended: the
# launcher's way to the app (SpringBoard, the app opened, ended) doesn't
# hang on one call.
#
#   patient <what> <command>…
patient() {
    local status
    bounded 60 "$@"
    status=$?
    [ "$status" = 124 ] || return "$status"
    echo "ios_launcher: $(date +%T) $1: once more" >&3
    bounded 60 "$@"
}
stop() {
    local waker tries=0
    [ -n "$child" ] && kill -KILL -- -"$child" 2> /dev/null
    # The wakes' launches, in the background: each wake's subshell ends its
    # own child's group on TERM (within a tenth of a second: it waits in
    # `bounded`), then is ended itself if it hasn't gone in a second. Killed
    # outright, it left its simctl launch running, orphaned, past the test.
    for waker in $wakers; do kill -TERM "$waker" 2> /dev/null; done
    for waker in $wakers; do
        while kill -0 "$waker" 2> /dev/null && [ "$tries" -lt 10 ]; do
            sleep 0.1
            tries=$((tries + 1))
        done
        kill -KILL "$waker" 2> /dev/null
    done
    # (Within HeadlessApp's 10 s before its SIGKILL: the next launch ends
    # an app left running anyway.)
    bounded 8 "simctl terminate" xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1
    rm -rf "$scratch"
    exit 0
}
trap stop TERM INT
# From the home screen: an app opened over another (Safari, left in front
# by a test before) shows a "◀" link back to it in the status bar.
patient "simctl launch SpringBoard" xcrun simctl launch "$udid" com.apple.springboard > /dev/null 2>&1
if fresh; then
    # The app's data as an install leaves it: its defaults, each domain
    # deleted through the simulator's cfprefsd by its file's path (the
    # domain the app's container holds: by name, `defaults` reaches the
    # simulator's own, and a file removed under cfprefsd comes back from its
    # cache), then its files and its app groups' (the containers themselves
    # kept, with their metadata), and the simulator's keychain (an app's
    # items outlive it, as on a phone). The simulator is the test's: nothing
    # else of its is touched.
    patient "simctl terminate" xcrun simctl terminate "$udid" "$bundle" > /dev/null 2>&1
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
    patient "simctl keychain reset" xcrun simctl keychain "$udid" reset > /dev/null 2>&1
fi
# The app's output kept with the test's (an app that never attached says why
# there; ISO_DRIVE_TRACE=1, simctl's SIMCTL_CHILD_ISO_DRIVE_TRACE, prints
# the driver's walk of its accessibility tree).
log="${TEST_UNDECLARED_OUTPUTS_DIR:-${TMPDIR:-/tmp}}/$name.log"
# (From when the simulator's log is read for RunningBoard's word on it:
# `suspended`.)
started="$(date '+%Y-%m-%d %H:%M:%S')"
bounded 180 "simctl launch" env "${environment[@]}" xcrun simctl launch --terminate-running-process --stdout="$log" \
    --stderr="$log" "$udid" "$bundle" ${app_arguments[@]+"${app_arguments[@]}"} > "$scratch/launched" ||
    { rm -rf "$scratch"; exit 1; }
# simctl's "<bundle>: <pid>": the process the test drives.
launched="$(cat "$scratch/launched")"
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
    local last priority
    if bounded 20 "launchctl procinfo" sudo -n launchctl procinfo "$pid" > "$scratch/procinfo" 2> /dev/null &&
        grep -q "^jetsam state" "$scratch/procinfo"; then
        grep -q "^jetsam state = suspended" "$scratch/procinfo"
        return
    fi
    if bounded 20 "the simulator's log" xcrun simctl spawn "$udid" log show --start "$started" --style compact --predicate \
        "process == \"runningboardd\" AND eventMessage CONTAINS \":$pid] \" AND (eventMessage ENDSWITH \"Suspending task.\" OR eventMessage ENDSWITH \"Resuming task.\")" \
        > "$scratch/log" 2> /dev/null; then
        last="$(grep -E '(Suspending|Resuming) task\.$' "$scratch/log" | tail -1)"
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
# --terminate-running-process starts no other. Each launch `patient`: a
# minute, twice; and should both give no answer, the next wake tries again.
bring_forward() {
    local now
    patient "simctl launch SpringBoard" xcrun simctl launch "$udid" com.apple.springboard > /dev/null 2>&1
    patient "simctl launch" xcrun simctl launch "$udid" "$bundle" > "$scratch/launch" 2> /dev/null || return 1
    now="$(cat "$scratch/launch")"
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
        patient "simctl launch SpringBoard" xcrun simctl launch "$udid" com.apple.springboard > /dev/null || return 1
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
                patient "simctl launch" xcrun simctl launch "$udid" "$bundle" > /dev/null 2>&1
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
# long `wait`), or hung, which the test's own timeout says. Each one said
# in the test's log, with the time.
#
# The wake's launches run in the background, beside the requests: on a
# slow runner a launch can take more than the command's own timeout to
# answer, and one that hangs mustn't keep the next wake from trying. While
# one is under 20 s old the next wake leaves it be; after that another
# starts beside it (the first not ended: it may only be slow).
wake() {
    local now
    # (The process a wake's launch found: iOS may have ended the app while
    # it was away.)
    if [ -s "$scratch/woken" ]; then
        now="$(cat "$scratch/woken")"
        rm -f "$scratch/woken"
        if [ -n "${now##*: }" ] && [ "${now##*: }" != "$pid" ]; then
            echo "ios_launcher: $bundle started again (pid ${now##*: }, was $pid): what it held is gone" >&2
            pid="${now##*: }"
        fi
    fi
    if ! suspended; then
        echo "ios_launcher: $(date +%T) wake: $bundle isn't suspended (a command waiting on it: working, or hung)" >&2
        return 0
    fi
    if [ -n "$waking" ] && kill -0 "$waking" 2> /dev/null && [ $((SECONDS - waking_since)) -lt 20 ]; then
        echo "ios_launcher: $(date +%T) wake: $bundle is being brought to the front (for $((SECONDS - waking_since)) s)" >&2
        return 0
    fi
    echo "ios_launcher: $(date +%T) wake: $bundle was suspended (a command waiting on it): brought to the front" >&2
    away=0
    wakes=$((wakes + 1))
    (
        # Ended by `stop` (TERM): the launch it waits on ended with it, and
        # what that started (its group).
        child=""
        trap '[ -n "$child" ] && kill -KILL -- -"$child" 2> /dev/null; exit 0' TERM
        bounded 60 "simctl launch SpringBoard" xcrun simctl launch "$udid" com.apple.springboard > /dev/null 2>&1
        bounded 60 "simctl launch" xcrun simctl launch "$udid" "$bundle" > "$scratch/woken.$wakes" 2> /dev/null &&
            mv "$scratch/woken.$wakes" "$scratch/woken"
    ) &
    waking=$!
    wakers="$wakers $waking"
    waking_since=$SECONDS
}
# A picture, turned from the simulator's upright frame to the interface's
# orientation (the app's driver says which, in the request) when the two
# differ: sips turns clockwise, so landscape-right (the home indicator on
# the right, the phone turned anticlockwise) is 270.
take() {
    local path="$1" orientation="${2:-}" turn="" width height
    bounded 60 "simctl io screenshot" xcrun simctl io "$udid" screenshot --mask=black "$path" > /dev/null 2>&1 || return 1
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
