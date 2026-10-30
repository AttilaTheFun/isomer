#!/bin/bash
# CI's build of every platform in a Linux container, on a self-hosted
# runner's Mac: a container leased from that Mac's OS Server (`oss machine
# run container --inside`), in the image a Visor session runs in, so CI
# builds where an agent works. The Apple targets take Xcode 27.0's SDK
# archive and rules_applecross's ported tools from the same OS Server's
# files (by SHA-256, with its cache's read token) through a downloader
# config written here, and its Bazel reads that server's cache: no host is
# named in the repository.
#
#   tools/ci/container_build.sh [<bazel build args>…]   # default: every platform's Storybook
#
#   OSS_FILES_HOST   the name the container reaches this Mac's OS Server by
#                    (default: this Mac's tailnet name, from Tailscale)
#   ISOMER_CI_IMAGE  the image (default: Visor's agent image, below)
#   ISOMER_CI_VOLUME Bazel's tree, kept between builds (default: isomer-ci;
#                    `:keep`, so OS Server keeps it when the lease ends)
#
# With no arguments (CI's run) the core's checks run after the build, in the
# same container: the mock renderer's and the snapshots' (isomer's own module,
# //tests/renderer and //tests/snapshot), their output in the log. Either the
# build or a check failing fails the run.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE="${ISOMER_CI_IMAGE:-ghcr.io/attilathefun/visor-agent:0.41.2}"
VOLUME="${ISOMER_CI_VOLUME:-isomer-ci}"
SDK_SHA256="251c252f7f41bcd3e08655e49e182686682d705945f4a2807049b9051c606ebb"

# `--inside` came in OS Server 0.12.0. An older oss takes it for an option it
# doesn't know and runs the build on this Mac instead: refused here. (The
# command line is inside the app: its version is the app's.)
oss_app="$(python3 -c 'import os, shutil; print(os.path.realpath(shutil.which("oss")))' | sed 's|/Contents/Helpers/oss$||')"
oss_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$oss_app/Contents/Info.plist" 2>/dev/null || echo 0)"
if ! python3 -c 'import sys; v = [int(x) for x in sys.argv[1].split(".")[:3]] + [0, 0]; sys.exit(0 if v[:3] >= [0, 12, 0] else 1)' "$oss_version"; then
    echo "container_build.sh: needs OS Server 0.12.0 or later on this Mac (oss machine run --inside); it has $oss_version" >&2
    exit 1
fi

host="${OSS_FILES_HOST:-}"
if [ -z "$host" ]; then
    tailscale=/Applications/Tailscale.app/Contents/MacOS/Tailscale
    host="$("$tailscale" status --json | python3 -c 'import json, sys; print(json.load(sys.stdin)["Self"]["DNSName"].rstrip("."))')"
fi

# The placeholders in MODULE.bazel, to this Mac's OS Server.
mkdir -p "$ROOT/.ci"
cat > "$ROOT/.ci/downloader.cfg" <<EOF
rewrite apple-sdks\.invalid/.* http://$host:7490/files/sha256/$SDK_SHA256
rewrite ported-tools\.invalid/sha256/(.*) http://$host:7490/files/sha256/\$1
EOF

checks=0
if [ $# -eq 0 ]; then
    checks=1
    set -- --ios_multi_cpus=sim_arm64 \
        //apple/storybook_ios_application:storybook_ios_sim_application \
        //apple/storybook_macos_application:storybook_macos_application \
        //web/storybook_web_application:storybook_web_application \
        //android/storybook_android_application:storybook_android_application \
        //linux/storybook_linux_application:storybook_linux_application
fi

# In the container: the build in the examples' module, then (CI's run) the
# checks in isomer's, each Bazel reading the cache (--cache writes the
# container's ~/.bazelrc).
steps='
root=$1 checks=$2; shift 2
cd "$root/examples"
bazel build --keep_going --config=apple_on_linux --downloader_config="$root/.ci/downloader.cfg" "$@"
built=$?
[ "$checks" = 1 ] || exit $built
cd "$root"
start=$SECONDS
bazel test --test_output=all //tests/renderer:mock_renderer_test //tests/snapshot:snapshot_test
checked=$?
echo "container_build.sh: the checks took $((SECONDS - start)) s"
[ $built -ne 0 ] && exit $built
exit $checked
'

cd "$ROOT/examples"
exec oss machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --mount="$ROOT:$ROOT" --volume="$VOLUME:/var/cache/bazel:128:keep" \
    --inside --cache="$host" -- \
    bash -c "$steps" container_build "$ROOT" "$checks" "$@"
