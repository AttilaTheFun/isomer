#!/bin/bash
# An Android phone on GitHub's own Ubuntu runner (x86_64, with KVM: free for
# a public repository), for the Android Storybook's tests
# (tools/ci/hosted_android_test.sh) and pictures (tools/ci/proof.sh): the
# runner's Android SDK's emulator, an x86_64 Android 14 (the AOSP image)
# shaped as the hermetic one is (1080×1920, 420 dpi), its status bar held
# still by SystemUI's demo mode. It boots, and stays running for the rest
# of the job; its serial is printed (everything else goes to standard error).
#
#   tools/ci/hosted_android_emulator.sh <emulator log>
set -euo pipefail
log="${1:?usage: hosted_android_emulator.sh <emulator log>}"
mkdir -p "$(dirname "$log")"
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
exec 3>&1 1>&2

# KVM for the runner's user.
echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
    sudo tee /etc/udev/rules.d/99-kvm.rules > /dev/null
sudo udevadm control --reload-rules
sudo udevadm trigger --name-match=kvm

# `yes` ends by SIGPIPE when sdkmanager stops reading, which pipefail
# would take for a failure.
image="system-images;android-34;default;x86_64"
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
# Its own session, so it outlives this script (the job's end ends it).
setsid nohup "$sdk/emulator/emulator" -avd isomer -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect \
    > "$log" 2>&1 < /dev/null &
"$adb" wait-for-device
booted=""
for _ in $(seq 1 300); do
    [ "$("$adb" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] && { booted=1; break; }
    sleep 2
done
[ -n "$booted" ] || { echo "hosted_android_emulator.sh: the emulator didn't boot (its log: $log)"; exit 1; }

# The status bar held still (~/Developer/AGENTS.md's sequence), once
# SystemUI runs and has settled (boot_completed comes well before it takes
# demo commands), three times a few seconds apart.
for _ in $(seq 1 60); do
    [ -n "$("$adb" shell pidof com.android.systemui 2> /dev/null | tr -d '\r')" ] && break
    sleep 2
done
sleep 20
"$adb" shell settings put global sysui_demo_allowed 1
demo() { "$adb" shell am broadcast -a com.android.systemui.demo -e command "$@" > /dev/null; }
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

"$adb" devices | awk 'NR > 1 && $2 == "device" { print $1; exit }' >&3
