#!/bin/bash
# The Android Storybook's stories on GitHub's own Ubuntu runner (x86_64, with
# KVM: free for a public repository), the primary place CI runs them; a
# private copy runs them on an emulator leased from OS Server instead
# (tools/ci/platform_tests.sh). The phone is tools/ci/hosted_android_emulator.sh's;
# the app is the x86_64 test APK CI's container built
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
serial="$("$ROOT/tools/ci/hosted_android_emulator.sh" "$out/emulator.log")"
exec "$ROOT/tools/ci/android_test.sh" "$sdk/platform-tools/adb" "$serial" "$apk" "$out" "${stories[@]}"
