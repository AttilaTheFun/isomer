#!/bin/bash
# Builds Isomer's Linux targets in a Linux container from a Mac: an Apple
# `container` of the image this directory's Containerfile makes (Ubuntu
# 24.04 with what the Linux targets link, and Bazel), arm64 on Apple
# silicon. The checkout's files (what git
# tracks, and new files it would) are copied in at each run; Bazel's output
# and downloads stay in the container between runs.
#
#   tools/linux/build.sh                       # //linux/... in isomer, and in examples (the Playground's too)
#   tools/linux/build.sh <targets>             # in isomer's root module
#   tools/linux/build.sh --module examples [--after '<command>'] [--out <path> <dir>] <targets>
#                                              # in that module (the Storybook, the Playground); then
#                                              # <command> there, in the container (packaging
#                                              # what was built), and <path> in its home
#                                              # copied out to <dir> here
#   tools/linux/build.sh --checkout <dir> [--after …] [--out …] <targets>
#                                              # another repository's checkout (an app on
#                                              # Isomer: reviews), built the same way in
#                                              # /work/<its name>
#   tools/linux/build.sh --apple-sdks <dir> …  # also the Apple targets (rules_applecross): the
#                                              # SDK archive in <dir> (apple-sdks-27.0.tar.gz)
#                                              # and the ported tools' archives (named by their
#                                              # SHA-256, in <dir> or a folder in it) copied into
#                                              # the container once, Bazel given them by
#                                              # --distdir, and .bazelrc's apple_on_linux on
#   tools/linux/build.sh --stop                # remove the container (and its Bazel tree)
#
# The container is named isomer-linux-build: started when stopped, made
# again when gone, and stopped after each build (an idle one holds its
# memory). Until 0.38 it was an oss container; oss is for GUI machines now,
# and this one is a plain `container`. The checkout goes in, and what's
# packaged comes out, with `container cp`; the checkout is unpacked into
# /work and Bazel's tree kept in /var/cache/bazel, on the container's own
# disk (a folder shared with the Mac costs the Mac a file handle for every
# file the container has looked at in it: a Bazel tree there held 160,000
# and ran macOS out of them). The image is built with `container build`
# when this machine lacks it. Nothing is run there but the build.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# Tagged by the Containerfile's hash: a changed one makes a new image (and,
# for a container of an older one, a new container).
IMAGE="isomer-linux-builder:$(shasum -a 256 "$HERE/Containerfile" | cut -c1-12)"
module=""
checkout=""
after=""
out=""
apple_sdks=""
out_dir=""
while [ $# -gt 0 ]; do
    case "$1" in
        --module) module="$2"; shift 2 ;;
        --checkout) checkout="$(cd "$2" && pwd)"; shift 2 ;;
        --after) after="$2"; shift 2 ;;
        --out) out="$2"; out_dir="$3"; shift 3 ;;
        --apple-sdks) apple_sdks="$(cd "$2" && pwd)"; shift 2 ;;
        --stop)
            container delete --force isomer-linux-build >/dev/null 2>&1 || true
            exit 0 ;;
        *) break ;;
    esac
done

if ! container image list 2>/dev/null | awk '{print $1":"$2}' | grep -qx "$IMAGE"; then
    container build --tag "$IMAGE" --file "$HERE/Containerfile" "$HERE" >/dev/null
    # Apple's builder is a container of its own (2 GB): not kept after.
    container builder stop >/dev/null 2>&1 || true
fi
id="isomer-linux-build"
state="$(container list --all 2>/dev/null | awk -v id="$id" '$1 == id {print $5}')"
# A container of an older image: made again.
if [ -n "$state" ] && ! container list --all 2>/dev/null | awk -v id="$id" '$1 == id {print $2}' | grep -q "$IMAGE\$"; then
    container delete --force "$id" >/dev/null 2>&1 || true
    state=""
fi
if [ "$state" = "stopped" ]; then
    container start "$id" >/dev/null
elif [ "$state" != "running" ]; then
    # Kept alive by a sleep; the builds run in it with exec. 6 CPUs and
    # 16 GB, the VMs' size (a Swift build thrashes in less).
    # Rosetta, for Android's x86_64 SDK and NDK tools.
    container run --detach --name "$id" --label isomer=linux-build --cpus 6 --memory 16g --rosetta \
        "$IMAGE" sleep infinity >/dev/null
fi

# The checkout as git sees it (tracked, and untracked but not ignored),
# into the container's home: isomer's, or the one --checkout names.
source_root="${checkout:-$ROOT}"
name="$(basename "$source_root")"
staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
(cd "$source_root" && git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --no-xattrs -czf "$staging/src.tgz" --null -T -)
container cp "$staging/src.tgz" "$id:/root/$name-src.tgz" >/dev/null

# Every bazel in the container (a packaging command's too) keeps its tree
# on the container's disk.
echo "startup --output_user_root=/var/cache/bazel" > "$staging/bazelrc"
container cp "$staging/bazelrc" "$id:/root/.bazelrc" >/dev/null

flags="--keep_going"
# The Apple SDK archive and the ported tools' archives, once, by their names:
# Bazel takes them from --distdir.
if [ -n "$apple_sdks" ]; then
    find -E "$apple_sdks" -maxdepth 2 -type f \( -name 'apple-sdks-*.tar.gz' -o -regex '.*/[0-9a-f]{64}' \) | while read -r archive; do
        base="$(basename "$archive")"
        # (Their stdin isn't the list's.)
        if ! container exec "$id" test -f "/var/cache/apple-sdks/$base" </dev/null; then
            container exec "$id" mkdir -p /var/cache/apple-sdks </dev/null
            container cp "$archive" "$id:/var/cache/apple-sdks/$base" >/dev/null </dev/null
        fi
    done
    flags="$flags --config=apple_on_linux --distdir=/var/cache/apple-sdks"
fi
if [ -n "$checkout" ]; then
    command="cd /work/$name && bazel build $flags $*"
    [ -n "$after" ] && command="$command && $after"
elif [ -n "$module" ]; then
    command="cd /work/isomer/$module && bazel build $flags $*"
    [ -n "$after" ] && command="$command && $after"
elif [ $# -gt 0 ]; then
    command="cd /work/isomer && bazel build $flags $*"
else
    command="cd /work/isomer && bazel build $flags //linux/... && cd examples && bazel build $flags //linux/... //playground/linux/..."
fi
# A fresh copy of the checkout each run (files deleted here go there too);
# Bazel's output base is outside it.
status=0
container exec "$id" bash -lc "rm -rf /work/$name && mkdir -p /work/$name && tar -xzf /root/$name-src.tgz -C /work/$name && rm /root/$name-src.tgz && $command" || status=$?
if [ "$status" -eq 0 ] && [ -n "$out" ]; then
    rm -rf "$out_dir"
    container cp "$id:/root/$out" "$out_dir" >/dev/null || status=$?
fi
container stop "$id" >/dev/null || true
exit "$status"
