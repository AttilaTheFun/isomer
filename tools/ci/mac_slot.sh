# Sourced by the CI scripts whose steps need a Mac (Xcode's xcresulttool,
# assetutil) but run in a Linux container (the
# isomer-jit runners): a slot of OS Server's primary Mac VM (`oss machine
# lease mac`: a macOS user of its own there, ready in seconds), renewed
# while the script runs and released however it ends. As
# AttilaTheFun/oss's tools/ci/mac_vm.sh leases one. A slot has no SSH: its
# commands go through `oss machine exec`, which hands them their arguments
# as they are, and its files one at a time through upload and download,
# their paths relative to its user's home.
#
#   . "$ROOT/tools/ci/mac_slot.sh"
#   mac_slot_lease                       # the slot, its renewer started
#   mac_slot_upload <file> <path>        # a file, to the slot's <path>
#   mac_slot_exec <command> <args…>      # a command there; its status
#   mac_slot_download <path> <file>      # a file, from the slot's <path>
#   mac_slot_release                     # given back now (else on exit)
#
# Copied from AttilaTheFun/reviews' tools/ci/mac_slot.sh.
#
# The script that sources it gives OSS (the oss command line) and work (a
# folder of its own), and calls mac_slot_release from its EXIT trap.
slot=""
slot_renewer=""

mac_slot_lease() {
    "$OSS" machine lease mac --minutes=60 --wait --exports > "$work/slot"
    slot="$(. "$work/slot"; printf '%s' "$OSS_ID")"
    [ -n "$slot" ] || { echo "mac_slot: no slot came" >&2; return 1; }
    echo "Slot $slot"
    (
        trap 'kill $! 2> /dev/null; exit 0' TERM
        # Only while the script runs: one killed past its traps (a cancel
        # that ends in SIGKILL) leaves this loop, which must not keep its
        # slot past the hour. $$ is the script, in this subshell too.
        while kill -0 "$$" 2> /dev/null; do
            sleep 600 &
            wait $!
            kill -0 "$$" 2> /dev/null || break
            "$OSS" machine renew "$slot" --minutes=60 > /dev/null || true
        done
    ) &
    slot_renewer=$!
}

mac_slot_upload() { "$OSS" machine upload "$slot" "$1" "$2" > /dev/null; }
mac_slot_download() { "$OSS" machine download "$slot" "$1" "$2" > /dev/null; }
mac_slot_exec() { "$OSS" machine exec "$slot" -- "$@"; }

mac_slot_release() {
    if [ -n "$slot_renewer" ]; then kill "$slot_renewer" 2> /dev/null || true; wait "$slot_renewer" 2> /dev/null || true; slot_renewer=""; fi
    [ -n "$slot" ] || slot="$(. "$work/slot" 2> /dev/null; printf '%s' "${OSS_ID:-}")"
    if [ -n "$slot" ]; then
        "$OSS" machine release "$slot" || echo "mac_slot: slot $slot was not released: oss machine release $slot" >&2
        slot=""
        rm -f "$work/slot"
    fi
}
