#!/bin/bash
# Builds Isomer's Linux targets in a Linux container, from a Mac: a check that
# Linux (a T3 platform, run on its own hosts) still compiles and
# links after a change elsewhere. Podman's machine is started if it is stopped,
# and stopped again afterwards.
#
#   tools/linux/build.sh            # //linux/... in isomer and in its examples
#   tools/linux/build.sh <targets>  # in isomer's root module
#
# The container is the podman machine's architecture (arm64 on Apple silicon):
# the same Swift and C as x86_64, its own WAMR trampoline. Bazel's output and
# downloads are kept in podman volumes between runs.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
started=""
if ! podman machine inspect --format '{{.State}}' 2>/dev/null | grep -q running; then
    podman machine start >/dev/null
    started=1
fi
trap '[ -n "$started" ] && podman machine stop >/dev/null' EXIT
podman build --quiet --file "$HERE/Containerfile" --tag localhost/isomer-linux-builder:dev "$HERE" >/dev/null
# The convenience symlinks go outside the checkout (the Mac's own stay).
flags="--keep_going --symlink_prefix=/build/links/"
if [ $# -gt 0 ]; then
    command="bazel --output_base=/build/root build $flags $*"
else
    command="bazel --output_base=/build/root build $flags //linux/... && cd examples && bazel --output_base=/build/examples build $flags //linux/..."
fi
# An untracked .bazelrc.user may point --override_module at checkouts beside
# this one (swift-foundation, say): they are mounted at the same paths.
extra=()
for rc in "$ROOT/.bazelrc.user" "$ROOT/examples/.bazelrc.user"; do
    [ -f "$rc" ] || continue
    for path in $(grep -oE -- '--override_module=[^= ]+=[^ ]+' "$rc" | sed 's/.*=//'); do
        [ -d "$path" ] && extra+=(--volume "$path:$path:ro")
    done
done
podman run --rm \
    --volume "$ROOT:/workspace:rw" \
    ${extra[@]+"${extra[@]}"} \
    --volume isomer-linux-build:/build \
    --volume isomer-linux-cache:/root/.cache \
    localhost/isomer-linux-builder:dev \
    bash -euc "$command"
