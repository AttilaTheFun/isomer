#!/bin/bash
# Boots the hermetically downloaded Android emulator with the bundled AOSP
# (default) system image. Usage (via bazel run //swift_map/tools/android/emulator):
#   bazel run //swift_map/tools/android/emulator              # windowed
#   bazel run //swift_map/tools/android/emulator -- -no-window  # headless
set -euo pipefail

RUNFILES_ROOT="$PWD/.."
EMULATOR_BIN="$RUNFILES_ROOT/$1"
SYSIMG_MARKER="$RUNFILES_ROOT/$2"
ADB="$RUNFILES_ROOT/$3"
shift 3

EMULATOR_DIR="$(cd "$(dirname "$EMULATOR_BIN")" && pwd)"
SYSIMG_DIR="$(cd "$(dirname "$SYSIMG_MARKER")" && pwd)"

STATE="${TMPDIR:-/tmp}/swift_map_emulator"
SDK="$STATE/sdk"
AVD_HOME="$STATE/avd"
AVD_DIR="$AVD_HOME/swift_map.avd"
mkdir -p "$SDK/system-images/android-34/default" "$AVD_DIR" "$SDK/platforms" "$SDK/platform-tools"

ln -sfn "$EMULATOR_DIR" "$SDK/emulator"
ln -sfn "$SYSIMG_DIR" "$SDK/system-images/android-34/default/arm64-v8a"
ln -sfn "$ADB" "$SDK/platform-tools/adb"

cat > "$AVD_HOME/swift_map.ini" <<EOF
avd.ini.encoding=UTF-8
path=$AVD_DIR
target=android-34
EOF

if [[ ! -f "$AVD_DIR/config.ini" ]]; then
  cat > "$AVD_DIR/config.ini" <<EOF
AvdId=swift_map
avd.ini.displayname=SwiftMap
avd.ini.encoding=UTF-8
abi.type=arm64-v8a
hw.cpu.arch=arm64
image.sysdir.1=system-images/android-34/default/arm64-v8a/
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
exec "$SDK/emulator/emulator" -avd swift_map -no-audio -no-boot-anim -no-snapshot "$@"
