#!/bin/bash
# An Android phone on GitHub's own x86_64 Ubuntu runner under Waydroid:
# Android 13 (LineageOS 20, x86_64) in an LXC container on the runner's own
# kernel, whose binder module is loaded here, drawn into a headless Weston,
# no emulator and no KVM. Shaped as Shireworks' Waydroid leases and
# hosted_android_emulator.sh's phone are (1080×2400, 420 dpi, gesture
# navigation), its status bar held still by SystemUI's demo mode; adb
# reaches it over Waydroid's bridge (<its IP>:5555), this runner's adb key
# let in. It boots in about three minutes from nothing (Waydroid installed,
# its images fetched) and stays running for the rest of the job; its serial
# is written to <serial file>. tools/ci/hosted_android_emulator.sh hands
# over to it (ISOMER_ANDROID_PHONE, waydroid by default), so its callers
# (hosted_android_test.sh, hosted_headful_test.sh, proof.sh) take either.
# tools/ci/waydroid_probe.sh found the way (the run's summary says each step).
#
#   tools/ci/hosted_waydroid.sh <log> <serial file>
#
# <log> is a file; each step's output is kept beside it (<log>.d/<step>.log).
set -uo pipefail
# Nothing here reads standard input, and adb mustn't either (hosted_android_emulator.sh).
exec < /dev/null
log="${1:?usage: hosted_waydroid.sh <log> <serial file>}"
serial_file="${2:?usage: hosted_waydroid.sh <log> <serial file>}"
logs="$log.d"
mkdir -p "$(dirname "$log")" "$logs"
exec 3>> "$log"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
adb="$sdk/platform-tools/adb"
say() { echo "hosted_waydroid: $*" >&3; echo "hosted_waydroid: $*" >&2; }
fail() { say "$*"; exit 1; }
# step <seconds> <name> <command…>: its output in <log>.d/<name>.log, its
# end shown should it fail.
step() {
    local seconds=$1 name=$2 started=$SECONDS
    shift 2
    if timeout --kill-after=10 "$seconds" "$@" > "$logs/$name.log" 2>&1; then
        say "$name ($((SECONDS - started)) s)"
    else
        tail -20 "$logs/$name.log" >&2
        fail "$name failed (its log: $logs/$name.log)"
    fi
}

# Binder, from the runner's own kernel (its modules ship binder_linux;
# Waydroid uses memfd where there's no ashmem).
step 60 binder sudo modprobe binder_linux devices=binder,hwbinder,vndbinder
if ! mountpoint -q /dev/binderfs; then
    sudo mkdir -p /dev/binderfs
    step 30 binderfs sudo mount -t binder binder /dev/binderfs
fi

# Waydroid from its own apt repository. A runner on AWS fetches Ubuntu's
# packages from an EC2 mirror that stalled this install past ten minutes in
# two probes of four: Ubuntu's own archives are asked first.
if [ -f /etc/apt/apt-mirrors.txt ] && grep -q ec2.archive /etc/apt/apt-mirrors.txt; then
    { printf 'http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\nhttp://archive.ubuntu.com/ubuntu/\tpriority:2\n'
      grep -v ec2.archive /etc/apt/apt-mirrors.txt; } > "$logs/apt-mirrors.txt"
    sudo cp "$logs/apt-mirrors.txt" /etc/apt/apt-mirrors.txt
fi
step 180 repository bash -c 'curl -fsSL --retry 3 https://repo.waydro.id | sudo bash'
step 600 install sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
    -o Acquire::http::Timeout=30 -o Acquire::Retries=5 waydroid weston dbus-daemon

# Its images fetched here rather than by `waydroid init`, whose download
# from SourceForge stalled past ten minutes on an AWS runner: Waydroid's OTA
# index names each (the newest first), curl gives up on a mirror that slows
# below 1 MB/s for 20 s and asks again (each ask may go to another mirror),
# and each is checked against its SHA-256. They go where Waydroid takes
# preinstalled images from (/etc/waydroid-extra/images: then `waydroid init`
# downloads nothing; its -i only says where its downloads go).
images=/etc/waydroid-extra/images
sudo mkdir -p "$images" && sudo chown "$(id -u)" "$images"
fetch_image() { # <OTA index URL> <image name>
    local entry url sha zip="$images/$2.zip"
    entry="$(curl -fsSL --retry 3 "$1" |
        python3 -c 'import json, sys; e = json.load(sys.stdin)["response"][0]; print(e["url"], e["id"])')" || return 1
    read -r url sha <<< "$entry"
    curl -fsSL --retry 8 --retry-all-errors --speed-limit 1000000 --speed-time 20 -o "$zip" "$url" &&
        echo "$sha  $zip" | sha256sum -c - && unzip -o -q "$zip" -d "$images" && rm -f "$zip"
}
export -f fetch_image
export images
step 600 system bash -c 'fetch_image https://ota.waydro.id/system/lineage/waydroid_x86_64/VANILLA.json system'
step 600 vendor bash -c 'fetch_image https://ota.waydro.id/vendor/waydroid_x86_64/MAINLINE.json vendor'
step 300 init sudo waydroid init
step 90 container sudo systemctl restart waydroid-container

# The display: a headless Weston the phone's size (Waydroid's Android takes
# its Wayland output's), in the runner user's runtime directory.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[ -d "$XDG_RUNTIME_DIR" ] || { sudo mkdir -p "$XDG_RUNTIME_DIR" && sudo chown "$(id -u)" "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"; }
nohup weston --backend=headless --socket=wayland-isomer --width=1080 --height=2400 > "$logs/weston.log" 2>&1 &
sleep 3
kill -0 $! 2> /dev/null || fail "weston didn't start (its log: $logs/weston.log)"
# Waydroid binds the session's PulseAudio socket into the container whether
# or not there is one (its tools/helpers/lxc.py, 1.6.3), and lxc won't start
# the container without it. A runner plays no sound: a socket nothing
# answers is enough for the mount.
pulse="${PULSE_RUNTIME_PATH:-$XDG_RUNTIME_DIR/pulse}"
if [ ! -S "$pulse/native" ]; then
    mkdir -p "$pulse" && rm -f "$pulse/native" &&
        python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$pulse/native"
fi

# The session, and Android's boot.
WAYLAND_DISPLAY=wayland-isomer nohup waydroid session start > "$logs/session.log" 2>&1 &
session=$!
started=$SECONDS
booted=""
while [ $((SECONDS - started)) -lt 300 ]; do
    [ "$(sudo timeout 20 waydroid shell getprop sys.boot_completed 2> /dev/null | tr -d '\r\n')" = 1 ] && { booted=1; break; }
    kill -0 "$session" 2> /dev/null || break
    sleep 5
done
sudo timeout 10 cat /var/lib/waydroid/waydroid.log > "$logs/waydroid.log" 2>&1
[ -n "$booted" ] || { tail -5 "$logs/session.log" >&2; fail "Android didn't boot (its logs: $logs)"; }
say "booted ($((SECONDS - started)) s)"
# Waydroid freezes its whole container when Android is idle (the screen off,
# no window in use), and every adb call then waits: CI's Storybook tests and
# proof hung on their first quiet moment. Never, as Shireworks' phones have it.
waydroid prop set persist.waydroid.suspend false > /dev/null 2>&1 ||
    sudo waydroid prop set persist.waydroid.suspend false > /dev/null 2>&1

# adb: this runner's key let in (written into Android's adb_keys through
# Waydroid's own root shell, adbd started again to read it), then a
# connection over Waydroid's bridge.
"$adb" start-server > /dev/null 2>&1
key="$(cat "$HOME/.android/adbkey.pub" 2> /dev/null)"
[ -n "$key" ] || fail "adb made no key ($HOME/.android/adbkey.pub)"
printf '%s\n' "echo '$key' >> /data/misc/adb/adb_keys" "chown system:shell /data/misc/adb/adb_keys" \
    "chmod 0640 /data/misc/adb/adb_keys" "setprop ctl.restart adbd" |
    sudo timeout 30 waydroid shell > "$logs/adb-key.log" 2>&1
ip="$(sudo waydroid status 2> /dev/null | awk '/IP address/ {print $NF}')"
[ -n "$ip" ] && [ "$ip" != UNKNOWN ] || fail "Waydroid has no IP ($(sudo waydroid status 2>&1 | tr '\n' ' '))"
serial="$ip:5555"
for _ in $(seq 1 20); do
    # A fresh connection each try: one made before the key stays unauthorized.
    "$adb" disconnect "$serial" > /dev/null 2>&1
    "$adb" connect "$serial" > /dev/null 2>&1
    sleep 2
    [ "$("$adb" -s "$serial" get-state 2> /dev/null)" = device ] && break
done
[ "$("$adb" -s "$serial" get-state 2> /dev/null)" = device ] || fail "adb didn't get in ($("$adb" devices | tr '\n' ' '))"
a() { "$adb" -s "$serial" "$@"; }

# The phone's shape, and its status bar held still once SystemUI has
# settled (hosted_android_emulator.sh's sequence, three times a few seconds
# apart), after gesture navigation: switching it restarts SystemUI, which
# forgets demo mode.
a shell wm size 1080x2400 > /dev/null
a shell wm density 420 > /dev/null
# Awake for the whole job: the screen on, whatever the time since a touch.
a shell svc power stayon true > /dev/null 2>&1
a shell settings put system screen_off_timeout 2147483647 > /dev/null 2>&1
a shell cmd overlay enable com.android.internal.systemui.navbar.gestural > /dev/null 2>&1 || true
for _ in $(seq 1 60); do
    [ -n "$(a shell pidof com.android.systemui 2> /dev/null | tr -d '\r')" ] && break
    sleep 2
done
sleep 15
a shell settings put global sysui_demo_allowed 1
demo() { a shell am broadcast -a com.android.systemui.demo -e command "$@" > /dev/null; }
for _ in 1 2 3; do
    demo exit
    demo enter
    demo clock -e hhmm 0941
    demo battery -e level 100 -e plugged false
    demo network -e wifi show -e level 4 -e fully true
    demo network -e mobile hide
    demo network -e nosim hide
    demo notifications -e visible false
    sleep 5
done
say "$(a shell getprop ro.product.model | tr -d '\r'), Android $(a shell getprop ro.build.version.release | tr -d '\r') (API $(a shell getprop ro.build.version.sdk | tr -d '\r')), EGL $(a shell getprop ro.hardware.egl | tr -d '\r'), suspend $(a shell getprop persist.waydroid.suspend | tr -d '\r'), $(a shell wm size | tail -1 | tr -d '\r'), $(a shell wm density | tail -1 | tr -d '\r') at $serial"
echo "$serial" > "$serial_file"
