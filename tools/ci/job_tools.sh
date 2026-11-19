#!/bin/bash
# What a CI job's Linux container needs beyond its image, installed when
# missing: the project's own image (ghcr.io/attilathefun/visor-agent, arm64
# alone) has it all; Swift's (the x86_64 jobs', where the web, Linux and
# Android build together: Android's tools are x86_64) has Swift and clang,
# and is given Bazel (Bazelisk, pinned by SHA-256, honouring .bazelversion),
# git, Python, zip and the rest the scripts call, and, when the job builds
# Linux (ISOMER_PLATFORMS names linux, or names nothing), what Isomer's Linux
# apps link, as the project's image has it (visor's
# tools/containers/visor-agent/Dockerfile): SDL2 and SDL2_ttf, GL and EGL,
# GTK 3 and WebKitGTK, lld. As root, or by sudo.
#
#   tools/ci/job_tools.sh
set -euo pipefail
root_do() { if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi; }
BAZELISK_VERSION=v1.30.0
case "$(uname -m)" in
    x86_64) bazelisk=bazelisk-linux-amd64 sha=a248ae2b2b62b5baebb748f6fba7203bff1a27e5d01b55399a8406744cb539e8 ;;
    aarch64) bazelisk=bazelisk-linux-arm64 sha=b2bcc040c213b44586b121bda6d983c35df121b917c3a7a66fb16f2fa0df1a4f ;;
    *) echo "job_tools: no Bazelisk pinned for $(uname -m)" >&2; exit 1 ;;
esac

# Each command, by the package that has it.
wanted=(git:git curl:curl python3:python3 unzip:unzip zip:zip zstd:zstd xz:xz-utils openssl:openssl
        file:file gzip:gzip sha256sum:coreutils sudo:sudo)
packages=(ca-certificates)
for pair in "${wanted[@]}"; do
    command -v "${pair%%:*}" > /dev/null || packages+=("${pair#*:}")
done
# zlib's headers: build_tools' proof-diff (examples' //tools/ci_tools)
# reads PNGs and zips through the system's zlib.
[ -f /usr/include/zlib.h ] || packages+=(zlib1g-dev)
# Isomer's Linux apps' libraries (linux/libraries/swift_ui), by pkg-config.
platforms=" ${ISOMER_PLATFORMS:-linux} "
if [[ $platforms == *" linux "* ]] &&
    ! { command -v pkg-config > /dev/null && pkg-config --exists sdl2 SDL2_ttf gl egl gtk+-3.0 webkit2gtk-4.1 &&
        command -v ld.lld > /dev/null; }; then
    packages+=(pkg-config lld libsdl2-dev libsdl2-ttf-dev libgl-dev libegl-dev libglvnd-dev libgtk-3-dev
               libwebkit2gtk-4.1-dev libcurl4-openssl-dev libsqlite3-dev libnss3)
fi
if [ ${#packages[@]} -gt 1 ]; then
    root_do apt-get update -qq > /dev/null
    root_do env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "${packages[@]}" > /dev/null
fi
if ! command -v bazel > /dev/null; then
    work="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$work/bazel" "https://github.com/bazelbuild/bazelisk/releases/download/$BAZELISK_VERSION/$bazelisk"
    echo "$sha  $work/bazel" | sha256sum -c --quiet - || { echo "job_tools: Bazelisk isn't the pinned $sha" >&2; exit 1; }
    root_do install -m 755 "$work/bazel" /usr/local/bin/bazel
    rm -rf "$work"
fi
# The checkout belongs to the runner's user, not the container's.
git config --global --add safe.directory "${GITHUB_WORKSPACE:-$PWD}"
echo "job_tools: $(bazel --version 2> /dev/null || echo bazel), $(git --version), $(uname -m)"
# The room Bazel has: its tree and its caches (the x86_64 runner's second
# disk at /mnt, where the job mounts it).
df -h / /mnt 2> /dev/null || df -h /
