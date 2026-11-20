#!/bin/bash
# A probe, by hand only (the Build workflow's `run: waydroid-probe`): whether
# Waydroid (Android in an LXC container on the host's own kernel) can run on
# GitHub's hosted x86_64 Ubuntu runner, so that the Android GUI tests could
# run in the same job as everything else, as they do on a kernel the owner
# controls. Nothing depends on it, and it never fails: every step is tried,
# time-limited, and what happened is written to the job's summary
# ($GITHUB_STEP_SUMMARY) and its log.
#
#   tools/ci/waydroid_probe.sh [<folder for logs>]
#
# What it tries, in order (each later step only if the one it needs worked):
#  1. the kernel: uname -a, binder and ashmem in its config, /dev/binder*,
#     /dev/binderfs, binder in /proc/filesystems;
#  2. binder: modprobe binder_linux (devices=binder,hwbinder,vndbinder),
#     with the kernel's linux-modules-extra package installed if the module
#     isn't there, and binderfs mounted; ashmem (Waydroid uses memfd where
#     ashmem is missing);
#  3. the phone CI's Android jobs use, made as they make it
#     (tools/ci/hosted_waydroid.sh: Waydroid from its apt repository, its
#     images, a session under a headless Weston, adb let in, the phone
#     shaped and its status bar held still), then a screenshot, an app
#     started and a tap over adb, and the phone's insets.
# Run on the runner itself (not in a job container), with sudo.
set -u
LOGS="${1:-${RUNNER_TEMP:-/tmp}/waydroid-probe}"
mkdir -p "$LOGS"
SUMMARY="${GITHUB_STEP_SUMMARY:-$LOGS/summary.md}"
rows=()
# row <step> <result> <detail>
row() { rows+=("| $1 | $2 | ${3//|/\\|} |"); echo "waydroid_probe: $1: $2${3:+ ($3)}"; }
# run <seconds> <log name> <command…>: the command's output kept and shown.
run() {
    local seconds=$1 name=$2; shift 2
    echo "::group::$name: $*"
    timeout --kill-after=10 "$seconds" "$@" > "$LOGS/$name.log" 2>&1
    local status=$?
    tail -60 "$LOGS/$name.log"
    echo "exit $status"
    echo "::endgroup::"
    return $status
}
finish() {
    {
        echo "## Waydroid on GitHub's hosted Ubuntu"
        echo
        echo "\`$(uname -a)\`"
        echo
        echo "| Step | Result | Detail |"
        echo "| --- | --- | --- |"
        printf '%s\n' "${rows[@]}"
        echo
        echo "Verdict: $verdict"
        echo
        echo "Logs: the run's \`waydroid-probe\` artifact."
    } >> "$SUMMARY"
    cat "$SUMMARY" 2> /dev/null | tail -40
    exit 0
}
verdict="Android did not boot (see the first failing step)"
trap finish EXIT

# 1. The kernel.
kernel="$(uname -r)"
uname -a | tee "$LOGS/uname.log"
row kernel ok "$kernel"
config=""
for candidate in "/boot/config-$kernel" /proc/config.gz; do [ -r "$candidate" ] && { config=$candidate; break; }; done
if [ -n "$config" ]; then
    case "$config" in *.gz) zcat "$config" ;; *) cat "$config" ;; esac | grep -E "CONFIG_ANDROID|BINDER|ASHMEM" > "$LOGS/kernel-config.log"
    row "kernel config" ok "$(tr '\n' ' ' < "$LOGS/kernel-config.log" | cut -c1-300)"
else
    row "kernel config" "not readable" ""
fi
ls -la /dev/binder* /dev/binderfs /dev/ashmem > "$LOGS/dev-before.log" 2>&1
row "/dev/binder*, /dev/binderfs, /dev/ashmem before" info "$(tr '\n' ' ' < "$LOGS/dev-before.log" | cut -c1-300)"
filesystems="$(grep binder /proc/filesystems)"
row "binder in /proc/filesystems before" "${filesystems:+yes}${filesystems:-no}" "$filesystems"

# 2. Binder (and ashmem). (`timeout` runs programs, not this script's
# functions: each step below is a command line of its own.)
find "/lib/modules/$kernel" -name 'binder*' > "$LOGS/binder-modules.log" 2>&1
row "binder modules shipped" info "$(tr '\n' ' ' < "$LOGS/binder-modules.log" | cut -c1-300)"
modprobe_binder=(sudo modprobe binder_linux devices=binder,hwbinder,vndbinder)
if run 60 modprobe-binder "${modprobe_binder[@]}"; then
    row "modprobe binder_linux" ok ""
else
    row "modprobe binder_linux" failed "$(tail -2 "$LOGS/modprobe-binder.log" | tr '\n' ' ')"
    # The module ships in the kernel's extra modules, which the runner's
    # image may leave out.
    run 300 apt-update sudo apt-get update -q
    if run 300 modules-extra sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q "linux-modules-extra-$kernel"; then
        row "linux-modules-extra-$kernel" installed ""
        if run 60 modprobe-binder-again "${modprobe_binder[@]}"; then
            row "modprobe binder_linux, again" ok ""
        else
            row "modprobe binder_linux, again" failed "$(tail -2 "$LOGS/modprobe-binder-again.log" | tr '\n' ' ')"
        fi
    else
        row "linux-modules-extra-$kernel" "not installed" "$(tail -2 "$LOGS/modules-extra.log" | tr '\n' ' ')"
    fi
fi
if grep -q binder /proc/filesystems && ! mountpoint -q /dev/binderfs; then
    sudo mkdir -p /dev/binderfs
    if run 30 binderfs sudo mount -t binder binder /dev/binderfs; then
        row "binderfs mounted" ok "$(ls /dev/binderfs | tr '\n' ' ')"
    else
        row "binderfs mounted" failed "$(tail -2 "$LOGS/binderfs.log" | tr '\n' ' ')"
    fi
fi
run 30 modprobe-ashmem sudo modprobe ashmem_linux
row "ashmem" "$([ -e /dev/ashmem ] && echo present || echo absent)" "Waydroid uses memfd without it"
lsmod | grep -E "binder|ashmem" > "$LOGS/lsmod.log"
ls -la /dev/binder* /dev/binderfs /dev/ashmem > "$LOGS/dev-after.log" 2>&1
binder=no
{ [ -e /dev/binder ] || [ -e /dev/binderfs/binder ] || grep -q binder /proc/filesystems; } && binder=yes
row "binder available" "$binder" "$(tr '\n' ' ' < "$LOGS/lsmod.log" | cut -c1-200)"
[ "$binder" = yes ] || { verdict="no binder in this kernel: Waydroid cannot run here"; }

# 3. The phone CI's Android jobs use (tools/ci/hosted_waydroid.sh: Waydroid
# installed, its images, a session under a headless Weston, adb let in, the
# phone's shape and status bar), then what the tests ask of it: a
# screenshot, an app started, a tap.
[ "$binder" = yes ] || exit 0
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
adb="$sdk/platform-tools/adb"
started=$SECONDS
if "$(dirname "$0")/hosted_waydroid.sh" "$LOGS/phone.log" "$LOGS/serial" > /dev/null 2>&1; then
    row "phone (hosted_waydroid.sh)" ok "$((SECONDS - started)) s: $(grep -v "^hosted_waydroid: [a-z-]* ([0-9]* s)$" "$LOGS/phone.log" | tr '\n' ' ' | cut -c1-300)"
else
    row "phone (hosted_waydroid.sh)" failed "$(tail -3 "$LOGS/phone.log" | tr '\n' ' ' | cut -c1-400)"
    sudo timeout 10 cat /var/lib/waydroid/waydroid.log > "$LOGS/waydroid.log" 2>&1
    exit 0
fi
row "phone's steps" info "$(grep -oE "^hosted_waydroid: [a-z-]* \([0-9]* s\)" "$LOGS/phone.log" | sed 's/^hosted_waydroid: //' | tr '\n' ' ')"
serial="$(cat "$LOGS/serial")"
a() { timeout 60 "$adb" -s "$serial" "$@"; }
a exec-out screencap -p > "$LOGS/home.png"
row "screenshot" "$(file -b "$LOGS/home.png" | cut -d, -f1-2)" "$(wc -c < "$LOGS/home.png") bytes"
a shell am start -W -a android.settings.SETTINGS > "$LOGS/settings.log" 2>&1
sleep 3
a exec-out screencap -p > "$LOGS/settings.png"
a shell input tap 540 1200
sleep 2
a exec-out screencap -p > "$LOGS/after-tap.png"
row "an app and a tap" "$(grep -q "Status: ok" "$LOGS/settings.log" && echo started || echo "not started")" \
    "$(cmp -s "$LOGS/settings.png" "$LOGS/after-tap.png" && echo "the tap changed nothing" || echo "the tap changed the screen"); top: $(a shell dumpsys activity activities 2> /dev/null | grep -m1 topResumedActivity | tr -s ' ' | cut -c1-120)"
a shell dumpsys window > "$LOGS/window.log" 2>&1
row "insets" info "$(grep -oE "type=(ITYPE_STATUS_BAR|ITYPE_NAVIGATION_BAR|statusBars|navigationBars) frame=\[[0-9,]+\]\[[0-9,]+\]" "$LOGS/window.log" | sort -u | tr '\n' ' ')"
# Screenshots, many in a row (the Storybook's tests and proof hung on one
# over adb's TCP connection): over adb (exec-out, each given 20 s), and
# written on the phone then read from the host (its /data is the session
# user's ~/.local/share/waydroid/data).
shots() { # <way> <count>
    local way=$1 n=$2 ok=0 hung=0 short=0 i t0 size
    t0=$SECONDS
    for i in $(seq 1 "$n"); do
        rm -f "$LOGS/shot.png"
        case "$way" in
            exec-out) timeout 20 "$adb" -s "$serial" exec-out screencap -p > "$LOGS/shot.png" ;;
            file) timeout 20 "$adb" -s "$serial" shell screencap -p /data/local/tmp/shot.png &&
                sudo timeout 10 cat "$HOME/.local/share/waydroid/data/local/tmp/shot.png" > "$LOGS/shot.png" ;;
        esac
        case $? in
            0) size=$(wc -c < "$LOGS/shot.png"); [ "$size" -gt 20000 ] && ok=$((ok + 1)) || short=$((short + 1)) ;;
            124) hung=$((hung + 1)) ;;
            *) short=$((short + 1)) ;;
        esac
        [ $((i % 3)) -eq 0 ] && a shell input swipe 540 1600 540 900 200 > /dev/null 2>&1
    done
    row "screenshots ($way)" "$ok of $n" "$hung hung past 20 s, $short short or failed, $((SECONDS - t0)) s in all"
}
shots exec-out 30
# A quiet minute, as the Storybook's tests have between stories, then again.
sleep 60
shots exec-out 10
shots file 30
verdict="Android booted under Waydroid on the hosted runner, adb in: GUI tests can run in the same job"
sudo timeout 10 cat /var/lib/waydroid/waydroid.log > "$LOGS/waydroid.log" 2>&1
sudo dmesg 2> /dev/null | tail -200 > "$LOGS/dmesg.log"
exit 0
