#!/bin/bash
# Boots the hermetically downloaded Android emulator with the bundled AOSP
# (default) system image. Usage (via bazel run //tools/android/emulator):
#   bazel run //tools/android/emulator              # windowed
#   bazel run //tools/android/emulator -- -no-window  # headless
set -euo pipefail

RUNFILES_ROOT="$PWD/.."
EMULATOR_BIN="$RUNFILES_ROOT/$1"
SYSIMG_MARKER="$RUNFILES_ROOT/$2"
ADB="$RUNFILES_ROOT/$3"
shift 3

EMULATOR_DIR="$(cd "$(dirname "$EMULATOR_BIN")" && pwd)"
# The system image is the host's architecture (tools/android/extensions.bzl),
# run natively: arm64 on a Mac (HVF), x86_64 on Linux (KVM, CI's runners).
case "$(uname -m)" in
  x86_64|amd64) ABI=x86_64; CPU_ARCH=x86_64 ;;
  *) ABI=arm64-v8a; CPU_ARCH=arm64 ;;
esac
SYSIMG_DIR="$(cd "$(dirname "$SYSIMG_MARKER")" && pwd)"
# Its API level, from the image itself (an app's MODULE.bazel may choose
# another image: android_tools.system_image), 34 by default.
API="$(sed -n 's/^ro\.build\.version\.sdk=//p' "$SYSIMG_DIR/build.prop" 2> /dev/null | head -1)"
API="${API:-34}"

STATE="${TMPDIR:-/tmp}/isomer_emulator"
SDK="$STATE/sdk"
AVD_HOME="$STATE/avd"
# An AVD per API level: one made for another image isn't reused.
AVD="isomer-$API"
AVD_DIR="$AVD_HOME/$AVD.avd"
mkdir -p "$SDK/system-images/android-$API/default" "$AVD_DIR" "$SDK/platforms" "$SDK/platform-tools"

ln -sfn "$EMULATOR_DIR" "$SDK/emulator"
ln -sfn "$SYSIMG_DIR" "$SDK/system-images/android-$API/default/$ABI"
ln -sfn "$ADB" "$SDK/platform-tools/adb"

cat > "$AVD_HOME/$AVD.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_DIR
target=android-$API
EOF

if [[ ! -f "$AVD_DIR/config.ini" ]]; then
  cat > "$AVD_DIR/config.ini" <<EOF
AvdId=$AVD
avd.ini.displayname=Isomer (API $API)
avd.ini.encoding=UTF-8
abi.type=$ABI
hw.cpu.arch=$CPU_ARCH
image.sysdir.1=system-images/android-$API/default/$ABI/
tag.id=default
tag.display=Default
hw.ramSize=2048
hw.lcd.density=420
hw.lcd.width=1080
hw.lcd.height=1920
hw.keyboard=yes
hw.mainKeys=no
hw.gpu.enabled=yes
hw.gpu.mode=auto
disk.dataPartition.size=2G
PlayStore.enabled=false
EOF
fi

# The emulator reads ANDROID_HOME before ANDROID_SDK_ROOT: both name the
# hermetic SDK assembled here, so a machine's own (a CI runner's preinstalled
# SDK, which has no system image of this AVD) is never what it finds.
export ANDROID_HOME="$SDK"
export ANDROID_SDK_ROOT="$SDK"
export ANDROID_AVD_HOME="$AVD_HOME"

echo "Starting Android emulator, API $API (AVD state in $STATE)"
exec "$SDK/emulator/emulator" -avd "$AVD" -no-audio -no-boot-anim -no-snapshot "$@"
