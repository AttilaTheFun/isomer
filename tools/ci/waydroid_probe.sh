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
#  3. Waydroid from its official apt repository (repo.waydro.id), and
#     `waydroid init` (the LineageOS system and vendor images);
#  4. the container (waydroid-container's service), then a session under a
#     headless Weston (Waydroid draws into a Wayland compositor);
#  5. Android booted: `waydroid status`, sys.boot_completed, and adb over
#     Waydroid's IP (`adb connect <ip>:5555`, `adb devices`).
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

# 3. Waydroid, from its official repository, and its images.
# (A mirror stalled for minutes on one package once: apt's own timeout and
# retries, and only what the three need.)
if run 180 repository bash -c 'curl -fsSL --retry 3 https://repo.waydro.id | sudo bash' && run 480 install sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
        -o Acquire::http::Timeout=30 -o Acquire::Retries=5 waydroid weston adb dbus-daemon; then
    row "waydroid installed" ok "$(dpkg-query -W -f '${Version}' waydroid 2> /dev/null)"
else
    row "waydroid installed" failed "$(tail -2 "$LOGS/install.log" 2> /dev/null | tr '\n' ' ')"
    exit 0
fi
[ "$binder" = yes ] || exit 0
if run 600 init sudo waydroid init; then
    row "waydroid init" ok "$(grep -iE "system|vendor" "$LOGS/init.log" | tail -2 | tr '\n' ' ' | cut -c1-200)"
else
    row "waydroid init" failed "$(tail -3 "$LOGS/init.log" | tr '\n' ' ')"
    exit 0
fi

# 4. The container, and a session under a headless Weston.
if run 90 container sudo systemctl restart waydroid-container; then
    sleep 5
    row "container" "$(systemctl is-active waydroid-container)" "$(sudo waydroid status 2> /dev/null | tr '\n' ' ')"
else
    row "container" failed "$(sudo journalctl -u waydroid-container --no-pager 2> /dev/null | tail -3 | tr '\n' ' ')"
fi
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -d "$XDG_RUNTIME_DIR" ] || { sudo mkdir -p "$XDG_RUNTIME_DIR" && sudo chown "$(id -u)" "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"; }
weston --backend=headless --socket=wayland-probe --width=1080 --height=1920 > "$LOGS/weston.log" 2>&1 &
weston_pid=$!
sleep 5
if kill -0 "$weston_pid" 2> /dev/null; then
    row "weston (headless)" ok ""
else
    row "weston (headless)" failed "$(tail -2 "$LOGS/weston.log" | tr '\n' ' ')"
fi
# 5. Android booted, and adb. The session tried as it is, then (should it
# end) under a D-Bus session bus of its own: Waydroid's user session talks
# to one, and a runner's job has none.
booted=no
deadline=$((SECONDS + 300))
for way in plain dbus-run-session; do
    if [ "$way" = plain ]; then
        WAYLAND_DISPLAY=wayland-probe waydroid session start > "$LOGS/session-$way.log" 2>&1 &
    else
        command -v dbus-run-session > /dev/null || break
        WAYLAND_DISPLAY=wayland-probe dbus-run-session -- waydroid session start > "$LOGS/session-$way.log" 2>&1 &
    fi
    session_pid=$!
    while [ $SECONDS -lt $deadline ]; do
        if [ "$(sudo timeout 20 waydroid shell getprop sys.boot_completed 2> /dev/null | tr -d '\r\n')" = 1 ]; then booted=yes; break; fi
        kill -0 "$session_pid" 2> /dev/null || break
        sleep 10
    done
    kill -0 "$session_pid" 2> /dev/null && state=running || state=ended
    row "session ($way)" "$state" "$(tail -4 "$LOGS/session-$way.log" | tr '\n' ' ' | cut -c1-400)"
    [ "$booted" = yes ] || [ "$state" = running ] && break
done
status="$(sudo waydroid status 2> /dev/null)"
echo "$status" > "$LOGS/status.log"
row "waydroid status" info "$(tr '\n' ' ' <<< "$status")"
row "sys.boot_completed" "$booted" "after $((SECONDS - deadline + 300)) s"
ip="$(awk '/IP address/ {print $NF}' <<< "$status")"
if [ -n "$ip" ] && [ "$ip" != UNKNOWN ]; then
    timeout 30 adb connect "$ip:5555" > "$LOGS/adb.log" 2>&1
    timeout 30 adb devices -l >> "$LOGS/adb.log" 2>&1
    model="$(timeout 20 adb -s "$ip:5555" shell getprop ro.product.model 2> /dev/null | tr -d '\r')"
    release="$(timeout 20 adb -s "$ip:5555" shell getprop ro.build.version.release 2> /dev/null | tr -d '\r')"
    row "adb devices" "$(grep -q "$ip:5555.*device" "$LOGS/adb.log" && echo connected || echo "not connected")" "$(tr '\n' ' ' < "$LOGS/adb.log" | cut -c1-200)"
    [ -n "$release" ] && row "Android" ok "$model, Android $release"
else
    row "adb devices" skipped "no IP from waydroid status"
fi
[ "$booted" = yes ] && verdict="Android booted under Waydroid on the hosted runner: GUI tests could run in the same job"
sudo timeout 10 cat /var/lib/waydroid/waydroid.log > "$LOGS/waydroid.log" 2>&1
row "waydroid.log" info "$(grep -iE "error|fail|exception" "$LOGS/waydroid.log" | tail -4 | tr '\n' ' ' | cut -c1-400)"
sudo dmesg 2> /dev/null | tail -200 > "$LOGS/dmesg.log"
# Stopped by their own PIDs and the service.
timeout 30 waydroid session stop > /dev/null 2>&1
kill "${session_pid:-}" "$weston_pid" 2> /dev/null
sudo systemctl stop waydroid-container > /dev/null 2>&1
exit 0
