#!/bin/bash
# What a CI job's Linux container needs beyond its image, installed when
# missing: the project's own image (ghcr.io/attilathefun/visor-agent) has it
# all; Swift's (the x86_64 jobs': Android's tools are x86_64) has Swift and
# clang, and is given Bazel (Bazelisk, pinned by SHA-256, honouring
# .bazelversion), git, Python, zip and the rest the scripts call. As root,
# or by sudo.
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
echo "job_tools: $(bazel --version 2> /dev/null || echo bazel), $(git --version)"
