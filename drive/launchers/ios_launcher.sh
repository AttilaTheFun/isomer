#!/bin/bash
# An iPhone app on a booted simulator, headful, for a test's HeadlessApp
# (docs/drive.md): built with --@isomer//drive:headful, so its driver dials
# out, launched with ISO_DRIVER and ISO_DRIVER_NAME (simctl's
# SIMCTL_CHILD_), until this is stopped (SIGTERM, or HeadlessApp's `stop`
# request). Pictures (a test's `picture`) are simctl's, masked (the
# simulator's own status bar is held at 9:41 by whoever made the
# simulator), turned to the app's interface: an app that turns itself to
# landscape on an upright simulator is pictured on its side, as a person
# turning the phone sees it.
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
env "${environment[@]}" xcrun simctl launch --terminate-running-process --stdout="$log" --stderr="$log" "$udid" "$bundle" \
    ${app_arguments[@]+"${app_arguments[@]}"} > /dev/null || exit 1
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
