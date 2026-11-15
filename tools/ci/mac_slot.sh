# Sourced by tools/ci/check_mac_icons.sh and tools/ci/ios_lease_tests.sh: a
# slot of Shireworks' primary Mac (`shireworks.sh lease mac`: a macOS user of
# its own on a VM with Xcode, ready in seconds) for what only a Mac runs
# (Xcode's assetutil and xcresulttool, CoreGraphics), from a Linux job. Its
# files go up and come back through Shireworks (`shireworks.sh put`, `get`),
# its commands run by `shireworks.sh run`, as the slot's user in its home.
#
# Needs the script's SW (tools/ci/shireworks_retry.sh) and work (a folder of
# its own); the script's cleanup calls mac_slot_release, so the slot is given
# back however it ends.

mac_slot=""

# The slot, leased once (waiting for a free one).
mac_slot_lease() {
    [ -z "$mac_slot" ] || return 0
    # In the background, waited for: a signal reaches the script's trap at once.
    "$SW" lease mac --minutes=30 > "$work/mac-slot" &
    wait $!
    mac_slot="$(. "$work/mac-slot"; printf '%s' "$SHIREWORKS_ID")"
    echo "A Mac slot: $mac_slot"
}

# mac_slot_upload <file> <path in the slot's home>
mac_slot_upload() { "$SW" put "$mac_slot" "$1" "$2" > /dev/null; }

# mac_slot_download <path in the slot's home> <file>
mac_slot_download() { "$SW" get "$mac_slot" "$1" "$2"; }

# mac_slot_exec <program> <arguments…>: in the slot's home.
mac_slot_exec() { "$SW" run "$mac_slot" -- "$@"; }

mac_slot_release() {
    [ -n "$mac_slot" ] || mac_slot="$(. "$work/mac-slot" 2> /dev/null; printf '%s' "${SHIREWORKS_ID:-}")"
    if [ -n "$mac_slot" ]; then
        "$SW" release "$mac_slot" || echo "$(basename "$0"): slot $mac_slot was not released: shireworks.sh release $mac_slot" >&2
        mac_slot=""
    fi
    rm -f "$work/mac-slot"
}
