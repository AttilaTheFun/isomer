#!/bin/bash
# The Android Storybook's stories on GitHub's own Ubuntu runner (x86_64, with
# KVM: free for a public repository), the primary place CI runs them; a
# private copy runs them on an emulator leased from OS Server instead
# (tools/ci/platform_tests.sh). The phone is the runner's Android SDK's
# emulator, an x86_64 Android 14 (the AOSP image) shaped as the hermetic
# one is (1080×1920, 420 dpi), its status bar held still by SystemUI's demo
# mode; the app is the x86_64 test APK CI's container built
# (tools/ci/container_build.sh with ISOMER_ANDROID_X86_64=1). Then
# tools/ci/android_test.sh, as on a lease.
#
#   tools/ci/hosted_android_test.sh <storybook .apk> <out>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
apk="${1:?usage: hosted_android_test.sh <storybook .apk> <out>}"
mkdir -p "${2:?<out>}"
out="$(cd "$2" && pwd)"
stories=($(sed -n 's/^ *"\([a-z]*\.[a-z]*\)",$/\1/p' "$ROOT/examples/tests/platforms/stories.bzl"))
[ ${#stories[@]} -gt 0 ] || { echo "hosted_android_test.sh: no stories" >&2; exit 1; }
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"

# KVM for the runner's user.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
    sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

# `yes` ends by SIGPIPE when sdkmanager stops reading, which pipefail
# would take for a failure.
image="system-images;android-${ISOMER_ANDROID_TEST_API:-34};default;x86_64"
{ yes || true; } | "$sdk/cmdline-tools/latest/bin/sdkmanager" --install emulator platform-tools "$image" > /dev/null
# The AVD where both avdmanager and the emulator look (the runner's own
# defaults differ).
export ANDROID_AVD_HOME="$HOME/.android/avd"
mkdir -p "$ANDROID_AVD_HOME"
echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd --force -n isomer -k "$image" > /dev/null
config="$ANDROID_AVD_HOME/isomer.avd/config.ini"
sed -i -E '/^(hw\.lcd\.(width|height|density)|hw\.keyboard|hw\.mainKeys) *=/d' "$config"
printf '%s\n' hw.lcd.width=1080 hw.lcd.height=1920 hw.lcd.density=420 hw.keyboard=yes hw.mainKeys=no >> "$config"

adb="$sdk/platform-tools/adb"
"$sdk/emulator/emulator" -avd isomer -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect \
    > "$out/emulator.log" 2>&1 &
emulator=$!
trap 'kill "$emulator" 2> /dev/null || true' EXIT
"$adb" wait-for-device
booted=""
for _ in $(seq 1 300); do
    [ "$("$adb" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] && { booted=1; break; }
    sleep 2
done
[ -n "$booted" ] || { echo "hosted_android_test.sh: the emulator didn't boot" >&2; exit 1; }

# The status bar held still (~/Developer/AGENTS.md's sequence), once
# SystemUI runs and has settled (boot_completed comes well before it takes
# demo commands), three times a few seconds apart.
for _ in $(seq 1 60); do
    [ -n "$("$adb" shell pidof com.android.systemui 2> /dev/null | tr -d '\r')" ] && break
    sleep 2
done
sleep 20
"$adb" shell settings put global sysui_demo_allowed 1
demo() { "$adb" shell am broadcast -a com.android.systemui.demo -e command "$@"; }
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

serial="$("$adb" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }')"
# The install on its own, bounded, with the phone's log when it fails.
if ! timeout 600 "$adb" -s "$serial" install -r "$apk"; then
    "$adb" -s "$serial" logcat -d > "$out/logcat-install.txt" 2>&1 || true
    tail -150 "$out/logcat-install.txt"
    echo "hosted_android_test.sh: the install failed or took over 10 minutes" >&2
    exit 1
fi
status=0
timeout 1800 "$ROOT/tools/ci/android_test.sh" "$adb" "$serial" "$apk" "$out" "${stories[@]}" || status=$?
"$adb" -s "$serial" logcat -d > "$out/logcat.txt" 2>&1 || true
[ $status -eq 0 ] || grep -E "FATAL|AndroidRuntime|libc  |DEBUG   " "$out/logcat.txt" | tail -80
exit $status
