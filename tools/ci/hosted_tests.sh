#!/bin/bash
# The platforms' Storybook tests on GitHub's own runners, from the apps CI's
# container built (tools/ci/container_build.sh's .ci/platforms, the job's
# `platform-apps` artifact): the build in our containers, the running on
# GitHub's machines (free for a public repository), each test the same
# script that runs it in our containers.
#
#   tools/ci/hosted_tests.sh web <apps> <out>       ubuntu-24.04-arm: Chrome for Testing
#   tools/ci/hosted_tests.sh linux <apps> <out>     ubuntu-24.04-arm: under Xvfb, Mesa's llvmpipe
#   tools/ci/hosted_tests.sh android <apps> <out>   ubuntu-latest (x86_64, KVM): an x86_64 emulator
#
# The stories are the test stories (examples/tests/platforms/stories.bzl);
# the pictures go to <out>. Each prepares its runner first: packages from
# apt, Chrome for Testing at MODULE.bazel's version, the runner's Android
# SDK's emulator. Also runs in a Linux container of ours (root, or sudo).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
platform="${1:?usage: hosted_tests.sh web|linux|android <apps> <out>}"
apps="$(cd "${2:?<apps>}" && pwd)"
mkdir -p "${3:?<out>}"
out="$(cd "$3" && pwd)"
stories=($(sed -n 's/^ *"\([a-z]*\.[a-z]*\)",$/\1/p' "$ROOT/examples/tests/platforms/stories.bzl"))
[ ${#stories[@]} -gt 0 ] || { echo "hosted_tests.sh: no stories" >&2; exit 1; }
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
apt_install() {
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@" > /dev/null ||
        { root_do apt-get update -qq > /dev/null &&
          root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@" > /dev/null; }
}
# The Swift runtime the Linux Storybook and our test tools link.
export LD_LIBRARY_PATH="$apps/linux/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

case "$platform" in
web)
    # What Chrome for Testing loads; then Chrome for Testing itself, the
    # archive MODULE.bazel pins for this architecture, checked.
    apt_install unzip libnss3 libasound2t64 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 \
        libpango-1.0-0 libcairo2 libcups2t64 libdrm2 libgbm1 fonts-dejavu-core
    case "$(uname -m)" in aarch64 | arm64) name=chrome_linux_arm64 ;; *) name=chrome_linux_x86_64 ;; esac
    block="$(awk -v name="\"$name\"" '$0 ~ "name = " name { found = 1 } found { print } found && /^\)/ { exit }' \
        "$ROOT/examples/MODULE.bazel")"
    url="$(sed -n 's/.*url = "\(.*\)".*/\1/p' <<< "$block")"
    sha="$(sed -n 's/.*sha256 = "\(.*\)".*/\1/p' <<< "$block")"
    folder="$(sed -n 's/.*strip_prefix = "\(.*\)".*/\1/p' <<< "$block")"
    work="$(mktemp -d)"
    curl -fsSL -o "$work/chrome.zip" "$url"
    echo "$sha  $work/chrome.zip" | sha256sum -c - > /dev/null
    unzip -q "$work/chrome.zip" -d "$work"
    export TEST_UNDECLARED_OUTPUTS_DIR="$out"
    exec "$ROOT/examples/tests/platforms/web_test.sh" "$apps/linux/bin/browser_check" "$apps/web" \
        "$work/$folder/chrome" "${stories[@]}"
    ;;
linux)
    # SDL2 and SDL2_ttf, OpenGL through Mesa, GTK and WebKitGTK (the web
    # view), Xvfb to draw on.
    apt_install xvfb libsdl2-2.0-0 libsdl2-ttf-2.0-0 libgl1-mesa-dri libegl1 libglx-mesa0 \
        libgtk-3-0t64 libwebkit2gtk-4.1-0 fonts-dejavu-core
    missing="$(ldd "$apps/linux/storybook" | grep "not found" || true)"
    [ -z "$missing" ] || { echo "hosted_tests.sh: the Linux Storybook needs libraries this runner hasn't:" >&2; echo "$missing" >&2; exit 1; }
    export TEST_UNDECLARED_OUTPUTS_DIR="$out"
    exec "$ROOT/examples/tests/platforms/linux_test.sh" "$apps/linux/run.sh" "$apps/linux/bin/picture_check" "${stories[@]}"
    ;;
android)
    # An x86_64 phone (Android 14, the AOSP image) on the runner's KVM, from
    # the runner's own Android SDK.
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?no Android SDK on this runner}}"
    echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666", OPTIONS+="static_node=kvm"' |
        root_do tee /etc/udev/rules.d/99-kvm.rules > /dev/null
    root_do udevadm control --reload-rules
    root_do udevadm trigger --name-match=kvm
    image="system-images;android-34;default;x86_64"
    yes | "$sdk/cmdline-tools/latest/bin/sdkmanager" --install emulator platform-tools "$image" > /dev/null
    echo no | "$sdk/cmdline-tools/latest/bin/avdmanager" create avd --force -n isomer -k "$image" -d pixel_6 > /dev/null
    adb="$sdk/platform-tools/adb"
    "$sdk/emulator/emulator" -avd isomer -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader_indirect \
        > "$out/emulator.log" 2>&1 &
    emulator=$!
    trap 'kill "$emulator" 2> /dev/null || true' EXIT
    "$adb" wait-for-device
    for _ in $(seq 1 180); do
        [ "$("$adb" shell getprop sys.boot_completed 2> /dev/null | tr -d '\r')" = 1 ] && break
        sleep 2
    done
    "$ROOT/tools/ci/android_test.sh" "$adb" emulator-5554 "$apps/android-test/storybook.apk" "$out" "${stories[@]}"
    ;;
*)
    echo "hosted_tests.sh: no platform $platform (web, linux, android)" >&2
    exit 2
    ;;
esac
