# The iPhone simulator of a job on GitHub's own `xcode-27` Mac runner,
# sourced by tools/ci/hosted_apple_test.sh and hosted_headful_test.sh.
#
# GitHub's xcode-27-arm64 image 20261112.0361.1 (actions/runner-images#15334,
# #14946) has simdiskimaged mount an iOS runtime twice and then unmount it
# while a simulator runs from it: SimLaunchHost crashes, every booted
# simulator goes down, and CoreSimulatorService answers every later simctl
# with "Connection interrupted" for the rest of the job. 20261104.0337.1 did
# not. So a job here waits for the runtimes to be mounted before it makes
# its simulator, and, when the simulator goes down under it, starts
# CoreSimulator again and boots it again (a new one if its runtime is gone),
# prepared as before, so the caller can try again what failed.
#
#   hosted_sim_start <name> <prepare function>   sets udid: made, booted, prepared
#   hosted_sim_healthy                           the simulator answers
#   hosted_sim_recover [<out>]                   back up (udid may change); the
#                                                crash reports kept in <out>
#
# <prepare function> is called with the simulator booted, its udid in $udid
# (its appearance, status bar, apps installed); it returns non-zero if it
# could not.

hosted_sim_name=""
hosted_sim_prepare=""
hosted_sim_recoveries=0

# Every runtime simdiskimaged is mounting, mounted (at most two minutes):
# `simctl runtime list` also starts CoreSimulator.
hosted_sim_settle() {
    local waited=0 pending
    command -v jq > /dev/null || { xcrun simctl runtime list > /dev/null 2>&1; return 0; }
    while :; do
        pending="$(xcrun simctl runtime list -j 2> /dev/null | jq -r '
            [.[] | select((.state // "Ready") != "Ready" and ((.state // "") | test("^Unusable") | not))] | length' 2> /dev/null)"
        [ "$pending" = 0 ] && return 0
        [ "$waited" -lt 120 ] || { echo "hosted_simulator: runtimes still not ready after 120 s" >&2; return 0; }
        sleep 2
        waited=$((waited + 2))
    done
}

# The newest iOS runtime simctl has.
hosted_sim_runtime() {
    xcrun simctl list runtimes iOS available |
        sed -n 's/^iOS .* - \(com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*\)$/\1/p' | tail -1
}

hosted_sim_boot() {
    xcrun simctl boot "$udid" > /dev/null 2>&1
    xcrun simctl bootstatus "$udid" -b > /dev/null 2>&1 && hosted_sim_healthy
}

hosted_sim_create() {
    local runtime
    runtime="$(hosted_sim_runtime)"
    [ -n "$runtime" ] || { echo "hosted_simulator: no iOS runtime on this Mac" >&2; return 1; }
    udid="$(xcrun simctl create "$hosted_sim_name" "${HOSTED_IOS_DEVICE:-iPhone 17}" "$runtime")" || return 1
    hosted_sim_boot || return 1
    "$hosted_sim_prepare"
}

hosted_sim_start() {
    hosted_sim_name="$1"
    hosted_sim_prepare="$2"
    hosted_sim_settle
    hosted_sim_create
}

# Booted, and its launchd answering.
hosted_sim_healthy() {
    [ -n "$udid" ] && xcrun simctl getenv "$udid" HOME > /dev/null 2>&1
}

hosted_sim_recover() {
    local out="${1:-}"
    hosted_sim_recoveries=$((hosted_sim_recoveries + 1))
    [ "$hosted_sim_recoveries" -le 3 ] || { echo "hosted_simulator: down a fourth time, not recovered" >&2; return 1; }
    echo "hosted_simulator: the simulator went down (actions/runner-images#15334): CoreSimulator started again" >&2
    if [ -n "$out" ]; then
        mkdir -p "$out/simulator-crashes"
        cp ~/Library/Logs/DiagnosticReports/*CoreSimulator* ~/Library/Logs/DiagnosticReports/*SimLaunchHost* \
            ~/Library/Logs/DiagnosticReports/*simdiskimage* "$out/simulator-crashes/" 2> /dev/null
        xcrun simctl runtime list > "$out/simulator-crashes/runtimes-$hosted_sim_recoveries.txt" 2>&1
    fi
    # CoreSimulatorService is this job's (the first simctl started it); launchd
    # starts it again at the next simctl.
    killall -9 com.apple.CoreSimulator.CoreSimulatorService 2> /dev/null
    sleep 2
    hosted_sim_settle
    if [ -n "$udid" ] && xcrun simctl list devices | grep -q "($udid)"; then
        xcrun simctl shutdown "$udid" > /dev/null 2>&1
        if hosted_sim_boot; then
            "$hosted_sim_prepare" && return 0
        fi
        xcrun simctl delete "$udid" > /dev/null 2>&1
    fi
    hosted_sim_create
}
