#!/bin/bash
# The platforms CI's build container can't run, tested where they run, at
# once, after tools/ci/container_build.sh put their apps in .ci/platforms:
#   - Windows under arm64 Wine 10 in a Linux container (Ubuntu 26.04's Wine:
#     tools/ci/windows_test.sh);
#   - Android on a Cuttlefish phone in a Linux container with its own KVM
#     (tools/ci/android_device.sh, android_test.sh), with --android: a boot
#     under nested virtualization takes ten minutes or more;
#   - the iPhone and the Mac on OS Server's primary macOS VM (an `ios` lease
#     and a `mac` slot: tools/ci/apple_test.sh), from this Mac.
# Each opens the Storybook's test stories (examples/tests/platforms/
# stories.bzl), pictures each and fails on one that doesn't draw; the
# pictures go to <out>/<platform>. Any failing fails the run.
#
#   tools/ci/platform_tests.sh [--android] <out>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
android=0
[ "${1:-}" = --android ] && { android=1; shift; }
out="$(mkdir -p "$1" && cd "$1" && pwd)"
case "$out/" in "$ROOT"/*) ;; *) echo "platform_tests.sh: <out> must be in this checkout" >&2; exit 1 ;; esac
apps="$ROOT/.ci/platforms"
stories=($(sed -n 's/^ *"\([a-z]*\.[a-z]*\)",$/\1/p' "$ROOT/examples/tests/platforms/stories.bzl"))
[ ${#stories[@]} -gt 0 ] || { echo "platform_tests.sh: no stories" >&2; exit 1; }
mkdir -p "$out/windows" "$out/android" "$out/apple"
chmod -R 777 "$out"
pids=() names=()

# Windows: Wine and what it draws on, from Ubuntu 26.04's apt (its archives
# kept in a volume between runs).
oss machine run container --image=docker.io/library/ubuntu:26.04 --cpus=4 --memory=6 \
    --mount="$ROOT:$ROOT" --volume=isomer-ci-wine-apt:/var/cache/apt/archives:8:keep --inside -- \
    bash -c 'set -e
        rm -f /etc/apt/apt.conf.d/docker-clean
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine xvfb imagemagick libgl1-mesa-dri >/dev/null
        exec "$1/tools/ci/windows_test.sh" "$2" "$3" "${@:4}"' \
    windows "$ROOT" "$apps/windows" "$out/windows" "${stories[@]}" >"$out/windows.log" 2>&1 &
pids+=($!) names+=(windows)

if [ $android -eq 1 ]; then
    apk="$(ls "$apps"/*storybook_android*.apk 2>/dev/null | head -1)"
    oss machine run container --image=docker.io/library/ubuntu:24.04 --virtualization --cpus=6 --memory=10 \
        --mount="$ROOT:$ROOT" --volume=isomer-ci-android:/var/cache/cf:64:keep --inside -- \
        bash -c 'set -e
            serial="$("$1/tools/ci/android_device.sh" start /var/cache/cf)"
            "$1/tools/ci/android_test.sh" /var/cache/cf/device/bin/adb "$serial" "$2" "$3" "${@:4}"; status=$?
            "$1/tools/ci/android_device.sh" stop /var/cache/cf
            exit $status' \
        android "$ROOT" "$apk" "$out/android" "${stories[@]}" >"$out/android.log" 2>&1 &
    pids+=($!) names+=(android)
fi

"$ROOT/tools/ci/apple_test.sh" "$(ls "$apps"/*storybook_ios*.ipa | head -1)" \
    "$(ls "$apps"/*storybook_macos*.zip | head -1)" "$out/apple" "${stories[@]}" >"$out/apple.log" 2>&1 &
pids+=($!) names+=(apple)

failed=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        echo "platform_tests.sh: ${names[$i]} passed"
    else
        echo "platform_tests.sh: ${names[$i]} FAILED; its log's end:"
        tail -30 "$out/${names[$i]}.log"
        failed=1
    fi
done
exit $failed
