#!/bin/bash
# The platforms CI's build container can't run, tested where they run, at
# once, after tools/ci/container_build.sh put their apps in .ci/platforms:
#   - Windows under arm64 Wine 10 in a Linux container (Ubuntu 26.04's Wine:
#     tools/ci/windows_test.sh), only with PLATFORM_TESTS naming it: for now
#     (2026-11-05) CI runs the tier-1 platforms and only builds Windows;
#   - Android on an emulator leased from Shireworks, on its Mac's own
#     hypervisor (tools/ci/android_test.sh), when PLATFORM_TESTS names it:
#     a private repository's CI, and the fallback; a public one's runs on
#     GitHub's Ubuntu runner (tools/ci/hosted_android_test.sh);
#   - the iPhone and the Mac on Shireworks' primary macOS VM (an `ios` lease
#     and a `mac` slot: tools/ci/apple_test.sh), from this Mac.
# All through Shireworks' API (tools/ci/shireworks.sh), so it runs anywhere
# with a Shireworks to ask (a CI job's container: the isomer-jit runners). Each opens the Storybook's
# test stories (examples/tests/platforms/
# stories.bzl), pictures each and fails on one that doesn't draw; the
# pictures go to <out>/<platform>. Any failing fails the run.
#
#   tools/ci/platform_tests.sh <out>
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
out="$(mkdir -p "$1" && cd "$1" && pwd)"
apps="$ROOT/.ci/platforms"
stories=($(sed -n 's/^ *"\([a-z]*\.[a-z]*\)",$/\1/p' "$ROOT/examples/tests/platforms/stories.bzl"))
[ ${#stories[@]} -gt 0 ] || { echo "platform_tests.sh: no stories" >&2; exit 1; }
mkdir -p "$out/windows" "$out/android" "$out/apple"
chmod -R 777 "$out"
pids=() names=()
shireworks="$ROOT/tools/ci/shireworks.sh"

platforms=" ${PLATFORM_TESTS:-android apple} "

# Windows: Wine and what it draws on, from Ubuntu 26.04's apt (its archives
# kept in a volume between runs), in a container of its own. Nothing of
# this runner's is mounted (a CI job's container can't mount): the app and
# the script go in through Shireworks, the pictures come back the same way.
if [[ $platforms == *" windows "* ]]; then
    (
        set -e
        eval "$("$shireworks" lease container --image=docker.io/library/ubuntu:26.04 --cpus=4 --memory=4 \
            --volume=isomer-ci-wine-apt:/var/cache/apt/archives:8:keep --minutes=60 \
            --kind=ci --label="Isomer: the Windows Storybook's tests (Wine)")"
        id="${SHIREWORKS_ID:-}"
        [ -n "$id" ] || { echo "platform_tests.sh: no container for Wine" >&2; exit 1; }
        trap '"$shireworks" release "$id" >/dev/null 2>&1' EXIT
        tar -czf "$out/windows.tgz" -C "$apps" windows -C "$ROOT/tools/ci" windows_test.sh
        "$shireworks" put "$id" "$out/windows.tgz" /tmp/windows.tgz >/dev/null
        rm -f "$out/windows.tgz"
        status=0
        "$shireworks" run "$id" -- bash -c 'set -e
            rm -f /etc/apt/apt.conf.d/docker-clean
            apt-get update -qq >/dev/null
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine xvfb imagemagick libgl1-mesa-dri >/dev/null
            mkdir -p /w && tar -xzf /tmp/windows.tgz -C /w
            status=0
            /w/windows_test.sh /w/windows /w/out "$@" || status=$?
            tar -czf /tmp/out.tgz -C /w/out .
            exit $status' windows "${stories[@]}" || status=$?
        "$shireworks" get "$id" /tmp/out.tgz "$out/windows.tgz" && tar -xzf "$out/windows.tgz" -C "$out/windows" && rm -f "$out/windows.tgz"
        exit $status
    ) >"$out/windows.log" 2>&1 &
    pids+=($!) names+=(windows)
fi

# Android: an emulator leased from Shireworks, run on its Mac's own
# hypervisor (outside Apple's Virtualization, whose vCPU threads oversleep
# every timed wait: a phone in a container takes over an hour to boot,
# tools/ci/android_device.sh, so that stays a by-hand path).
if [[ $platforms == *" android "* ]]; then
    (
        eval "$("$shireworks" lease android --kind=ci --label="Isomer: the Android Storybook's tests")"
        id="${SHIREWORKS_ID:-}"
        [ -n "$id" ] || { echo "platform_tests.sh: no android lease" >&2; exit 1; }
        trap '"$shireworks" release "$id" >/dev/null 2>&1' EXIT
        "$ROOT/tools/ci/android_test.sh" shireworks "$id" "$(ls "$apps"/*storybook_android*.apk | head -1)" \
            "$out/android" "${stories[@]}"
    ) >"$out/android.log" 2>&1 &
    pids+=($!) names+=(android)
fi

if [[ $platforms == *" apple "* ]]; then
    "$ROOT/tools/ci/apple_test.sh" "$(ls "$apps"/*storybook_ios*.ipa | head -1)" \
        "$(ls "$apps"/*storybook_macos*.zip | head -1)" "$out/apple" "${stories[@]}" >"$out/apple.log" 2>&1 &
    pids+=($!) names+=(apple)
fi

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
