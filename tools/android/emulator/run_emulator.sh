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

STATE="${TMPDIR:-/tmp}/isomer_emulator"
SDK="$STATE/sdk"
AVD_HOME="$STATE/avd"
AVD_DIR="$AVD_HOME/isomer.avd"
mkdir -p "$SDK/system-images/android-34/default" "$AVD_DIR" "$SDK/platforms" "$SDK/platform-tools"

ln -sfn "$EMULATOR_DIR" "$SDK/emulator"
ln -sfn "$SYSIMG_DIR" "$SDK/system-images/android-34/default/$ABI"
ln -sfn "$ADB" "$SDK/platform-tools/adb"

cat > "$AVD_HOME/isomer.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_DIR
target=android-34
EOF

if [[ ! -f "$AVD_DIR/config.ini" ]]; then
  cat > "$AVD_DIR/config.ini" <<EOF
AvdId=isomer
avd.ini.displayname=Isomer
avd.ini.encoding=UTF-8
abi.type=$ABI
hw.cpu.arch=$CPU_ARCH
image.sysdir.1=system-images/android-34/default/$ABI/
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

export ANDROID_SDK_ROOT="$SDK"
export ANDROID_AVD_HOME="$AVD_HOME"

echo "Starting Android emulator (AVD state in $STATE)"
exec "$SDK/emulator/emulator" -avd isomer -no-audio -no-boot-anim -no-snapshot "$@"
