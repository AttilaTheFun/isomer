#!/bin/bash
# The platforms CI's build container can't run, tested where they run, at
# once, after tools/ci/container_build.sh put their apps in .ci/platforms:
#   - Windows under arm64 Wine 10 in a Linux container (Ubuntu 26.04's Wine:
#     tools/ci/windows_test.sh);
#   - Android on an emulator leased from OS Server, on its Mac's own
#     hypervisor (tools/ci/android_test.sh);
#   - the iPhone and the Mac on OS Server's primary macOS VM (an `ios` lease
#     and a `mac` slot: tools/ci/apple_test.sh), from this Mac.
# Each opens the Storybook's test stories (examples/tests/platforms/
# stories.bzl), pictures each and fails on one that doesn't draw; the
# pictures go to <out>/<platform>. Any failing fails the run.
#
#   tools/ci/platform_tests.sh <out>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
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

# Android: an emulator leased from OS Server, run on its Mac's own
# hypervisor (outside Apple's Virtualization, whose vCPU threads oversleep
# every timed wait: a phone in a container takes over an hour to boot,
# tools/ci/android_device.sh, so that stays a by-hand path).
(
    id="$(oss machine lease android --kind=ci --label="Isomer: the Android Storybook's tests" --wait --json |
        sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$id" ] || { echo "platform_tests.sh: no android lease" >&2; exit 1; }
    trap 'oss machine release "$id" >/dev/null 2>&1' EXIT
    "$ROOT/tools/ci/android_test.sh" oss "$id" "$(ls "$apps"/*storybook_android*.apk | head -1)" \
        "$out/android" "${stories[@]}"
) >"$out/android.log" 2>&1 &
pids+=($!) names+=(android)

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
