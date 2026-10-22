#!/bin/bash
# Builds Isomer's Linux targets in a Linux container from a Mac: an oss
# container (https://github.com/AttilaTheFun/oss) of the image this
# directory's Containerfile makes (Ubuntu 24.04 with what the Linux targets
# link, and Bazel), arm64 on Apple silicon. The checkout's files (what git
# tracks, and new files it would) are copied in at each run; Bazel's output
# and downloads stay in the container between runs.
#
#   tools/linux/build.sh                       # //linux/... in isomer, its examples and the Playground
#   tools/linux/build.sh <targets>             # in isomer's root module
#   tools/linux/build.sh --module playground [--after '<command>'] <targets>
#                                              # in that module (examples, playground); then
#                                              # <command> there, in the container (packaging
#                                              # what was built)
#   tools/linux/build.sh --stop                # archive nothing: remove the container
#
# The container is the one this script started last (its id kept in
# ~/.cache/isomer/linux-build-container; started again when it is gone). Its
# home, /root there, is a folder on this Mac shared into the container: the
# checkout arrives there and what's packaged leaves there, but the checkout is
# unpacked into /work and Bazel's tree kept in /var/cache/bazel, on the
# container's own disk. A shared folder costs the Mac a file handle for every
# file the container has looked at in it: a Bazel tree there held 160,000
# and ran macOS out of them. The image is built with Apple's `container build` when this
# machine lacks it. Nothing is run there but the build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="isomer-linux-builder:dev"
module=""
after=""
while [ $# -gt 0 ]; do
    case "$1" in
        --module) module="$2"; shift 2 ;;
        --after) after="$2"; shift 2 ;;
        --stop)
            id="$(cat ~/.cache/isomer/linux-build-container 2>/dev/null || true)"
            [ -n "$id" ] && oss container remove "$id"
            rm -f ~/.cache/isomer/linux-build-container
            exit 0 ;;
        *) break ;;
    esac
done

if ! container image list 2>/dev/null | grep -q "^isomer-linux-builder *dev"; then
    container build --tag "$IMAGE" --file "$HERE/Containerfile" "$HERE" >/dev/null
    # Apple's builder is a container of its own (2 GB): not kept after.
    container builder stop >/dev/null 2>&1 || true
fi
mkdir -p ~/.cache/isomer
id="$(cat ~/.cache/isomer/linux-build-container 2>/dev/null || true)"
if [ -z "$id" ] || ! oss container list 2>/dev/null | grep -q "^$id  *running"; then
    id="$(oss container start --image="$IMAGE" --label=isomer=linux-build | awk '/^container / {sub(":", "", $2); print $2; exit}')"
    echo "$id" > ~/.cache/isomer/linux-build-container
fi
home="$(oss container list 2>/dev/null | awk -v id="$id" '$1 == id {print $NF}')"
[ -n "$id" ] && [ -d "$home" ] || { echo "no oss container" >&2; exit 1; }

# The checkout as git sees it (tracked, and untracked but not ignored),
# into the container's home.
(cd "$ROOT" && git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --no-xattrs -czf "$home/isomer-src.tgz" --null -T -)

# Every bazel in the container (a packaging command's too) keeps its tree
# on the container's disk.
echo "startup --output_user_root=/var/cache/bazel" > "$home/.bazelrc"

flags="--keep_going"
if [ -n "$module" ]; then
    command="cd /work/isomer/$module && bazel build $flags $*"
    [ -n "$after" ] && command="$command && $after"
elif [ $# -gt 0 ]; then
    command="cd /work/isomer && bazel build $flags $*"
else
    command="cd /work/isomer && bazel build $flags //linux/... && cd examples && bazel build $flags //linux/... && cd ../playground && bazel build $flags //linux/..."
fi
# A fresh copy of the checkout each run (files deleted here go there too);
# Bazel's output base is outside it.
oss container exec "$id" -- bash -lc "rm -rf /work/isomer && mkdir -p /work/isomer && tar -xzf /root/isomer-src.tgz -C /work/isomer && rm /root/isomer-src.tgz && $command"
