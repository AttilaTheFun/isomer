#!/bin/bash
# An Android phone in a Linux container: Cuttlefish, AOSP's virtual device
# (arm64, the build Android's CI publishes as
# aosp_cf_arm64_only_phone-userdebug), under the container's own KVM (an OS
# Server container lease with --virtualization: /dev/kvm, vhost-vsock),
# drawn in software (SwiftShader). Its host tools come from Cuttlefish's apt
# repository, the device from Android's CI by `cvd fetch`, both kept in
# <cache> (a kept volume) between runs. Prints the adb serial once the phone
# has booted.
#
#   tools/ci/android_device.sh start <cache>      # installs what's missing, boots it
#   tools/ci/android_device.sh stop <cache>
#
# Slow: Virtualization's vCPU threads aren't real-time, so every timed wait
# in the guest oversleeps by about half (macOS's timer leeway, measured by
# OS Server's maintainers), across thousands of Android's threads. A boot
# takes over an hour; 2 vCPUs do better than 4; Android's own timeouts (the
# system server's watchdog, ART's thread suspension) are scaled by 20
# (hw_timeout_multiplier), or they end the boot first. Its browser view
# (WebRTC) and radio simulator (netsim) are off: both want services a
# container doesn't run, and either ending ends the device.
set -euo pipefail
command="$1" cache="$2"
build="${CUTTLEFISH_BUILD:-aosp-android-latest-release/aosp_cf_arm64_only_phone-userdebug}"
export PATH="/usr/lib/cuttlefish-common/bin:$PATH" HOME="$cache/device"
mkdir -p "$cache/device"

if [ "$command" = stop ]; then
    (cd "$cache/device" && ./bin/stop_cvd >/dev/null 2>&1) || true
    exit 0
fi

if ! command -v cvd >/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null
    apt-get install -y -q --no-install-recommends curl ca-certificates >/dev/null
    curl -fsSL https://us-apt.pkg.dev/doc/repo-signing-key.gpg -o /etc/apt/trusted.gpg.d/artifact-registry.asc
    echo "deb https://us-apt.pkg.dev/projects/android-cuttlefish-artifacts android-cuttlefish main" \
        >/etc/apt/sources.list.d/artifact-registry.list
    apt-get update -qq >/dev/null
    apt-get install -y -q --no-install-recommends cuttlefish-base cuttlefish-user >/dev/null
fi
# What `cvd setup` asks of the host, as root in a container: the groups
# (no sudo here), and the network devices its init script makes.
for group in cvdnetwork kvm render; do
    getent group "$group" >/dev/null || groupadd "$group"
    usermod -aG "$group" root
done
/etc/init.d/cuttlefish-host-resources start >/dev/null 2>&1 || true

if [ ! -x "$cache/device/bin/launch_cvd" ]; then
    cvd fetch --default_build="$build" --target_directory="$cache/device" >&2
fi
# Its groups take effect in a new login: launched through su.
su root -c "export PATH='$PATH' HOME='$HOME'; cd '$cache/device' && ./bin/launch_cvd --daemon \
    --start_webrtc=false --netsim=false --netsim_bt=false --netsim_uwb=false \
    --gpu_mode=guest_swiftshader --report_anonymous_usage_stats=n \
    --cpus=2 --memory_mb=4096 --boot_timeout_secs=6000 --resume=false \
    --extra_bootconfig_args=androidboot.hw_timeout_multiplier=20" >&2
serial="0.0.0.0:6520"
"$cache/device/bin/adb" connect "$serial" >/dev/null
"$cache/device/bin/adb" -s "$serial" wait-for-device
echo "$serial"
