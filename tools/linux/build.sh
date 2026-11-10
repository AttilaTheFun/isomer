#!/bin/bash
# Builds Isomer's Linux targets (and, with the Apple SDK, every platform's) in
# a Linux container leased from Shireworks: arm64 on Apple silicon, in the
# image a Visor session runs in (Visor's agent image, tools/ci/agent_image,
# as CI's tools/ci/container_build.sh builds: Swift, clang, Bazel, the
# libraries the Linux targets link, x86_64 glibc and Rosetta for Android's
# tools). The checkout's files (what git tracks, and new files it would) are
# copied in at each run; Bazel's output and downloads stay on a kept volume
# between runs.
#
#   tools/linux/build.sh                       # //linux/... in isomer, and in examples
#   tools/linux/build.sh <targets>             # in isomer's root module
#   tools/linux/build.sh --module examples [--after '<command>'] [--out <path> <dir>] <targets>
#                                              # in that module (the Storybook); then
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
#                                              # SHA-256, in <dir> or a folder in it) copied onto
#                                              # the volume once, Bazel given them by
#                                              # --distdir, and .bazelrc's apple_on_linux on
#   tools/linux/build.sh --stop                # release a lease of this script's still held, and
#                                              # delete the volume (its Bazel tree)
#
#   SHIREWORKS_SERVERS    the Shireworks to lease from, with SHIREWORKS_API_KEY
#                         (or SHIREWORKS_TOKEN): tools/ci/shireworks.sh's
#   ISOMER_LINUX_IMAGE    the image (default: tools/ci/agent_image's)
#   ISOMER_LINUX_VOLUME   Bazel's tree (default: isomer-linux-build)
#
# Each run is one container leased through Shireworks' API
# (tools/ci/shireworks.sh), for an hour, renewed while the build runs and
# released however it ends (a signal releases it at once; a run killed
# outright is reclaimed when its hour is up). The checkout goes in as an
# archive (`put`) and is unpacked into /work, the build runs with `run`, and
# what --out names comes back as an archive (`get`). Nothing of the Mac is
# mounted, so this works from any client Shireworks lends a container to (a
# Mac, a session's container), and the checkout's own bazel-* links are left
# alone. Bazel's tree is the volume, at /var/cache/bazel, kept (`:keep`) when
# the lease goes, so a run builds only what changed; one build at a time uses
# it (a second, while one runs, waits for the volume). Until 2026-10-31 this
# was a plain Apple `container` this script made and kept itself (from 0.38;
# a lease before).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SW="$ROOT/tools/ci/shireworks.sh"
IMAGE="${ISOMER_LINUX_IMAGE:-$(cat "$ROOT/tools/ci/agent_image")}"
VOLUME="${ISOMER_LINUX_VOLUME:-isomer-linux-build}"
# This script's leases are known by their label (--stop releases them).
LABEL="isomer tools/linux/build.sh"

# The build, in the container leased below ($id): the options from the
# environment, the targets the arguments.
build_in_lease() {
    # /work/isomer whatever isomer's checkout is called here; another
    # repository's by its folder's name.
    source_root="$BUILD_SOURCE_ROOT" name=isomer
    [ "$BUILD_CHECKOUT" = 1 ] && name="$(basename "$BUILD_SOURCE_ROOT")"
    staging="$(mktemp -d)"

    # The checkout as git sees it (tracked, and untracked but not ignored),
    # into the container's home.
    (cd "$source_root" && git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --no-xattrs -czf "$staging/src.tgz" --null -T -)
    "$SW" put "$id" "$staging/src.tgz" "/root/$name-src.tgz" >/dev/null

    flags="--keep_going"
    # The Apple SDK archive and the ported tools' archives, once, by their
    # names, onto the volume: Bazel takes them from --distdir.
    if [ -n "$BUILD_APPLE_SDKS" ]; then
        distdir=/var/cache/bazel/apple-sdks
        archives="$(find "$BUILD_APPLE_SDKS" -maxdepth 2 -type f | grep -E '/apple-sdks-[^/]*\.tar\.gz$|/[0-9a-f]{64}$' || true)"
        [ -n "$archives" ] || { echo "build.sh: no apple-sdks-*.tar.gz or ported tools in $BUILD_APPLE_SDKS" >&2; exit 1; }
        while read -r archive; do
            base="$(basename "$archive")"
            # (Their stdin isn't the list's.)
            if ! "$SW" run "$id" -- test -f "$distdir/$base" </dev/null 2>/dev/null; then
                echo "build.sh: $base onto the volume" >&2
                "$SW" put "$id" "$archive" "$distdir/$base" >/dev/null </dev/null
            fi
        done <<< "$archives"
        flags="$flags --config=apple_on_linux --distdir=$distdir"
    fi
    targets="$(printf '%q ' "$@")"
    if [ "$BUILD_CHECKOUT" = 1 ]; then
        command="cd /work/$name && bazel build $flags $targets"
        [ -n "$BUILD_AFTER" ] && command="$command && $BUILD_AFTER"
    elif [ -n "$BUILD_MODULE" ]; then
        command="cd /work/isomer/$BUILD_MODULE && bazel build $flags $targets"
        [ -n "$BUILD_AFTER" ] && command="$command && $BUILD_AFTER"
    elif [ $# -gt 0 ]; then
        command="cd /work/isomer && bazel build $flags $targets"
    else
        command="cd /work/isomer && bazel build $flags //linux/... && cd examples && bazel build $flags //linux/..."
    fi
    # A fresh copy of the checkout each run (files deleted here go there
    # too), in the container's own /work; every bazel there (a packaging
    # command's too) keeps its tree on the volume, and Bazelisk its Bazel.
    status=0
    "$SW" run "$id" -- bash -lc "
        echo 'startup --output_user_root=/var/cache/bazel' >> ~/.bazelrc
        export BAZELISK_HOME=/var/cache/bazel/bazelisk
        rm -rf /work/$name && mkdir -p /work/$name && tar -xzf /root/$name-src.tgz -C /work/$name && rm /root/$name-src.tgz
        $command" </dev/null || status=$?
    # What --out names, from the container's home, as an archive (a file or
    # a folder alike).
    if [ "$status" -eq 0 ] && [ -n "$BUILD_OUT" ]; then
        { "$SW" run "$id" -- bash -c 'cd ~ && tar -czf /tmp/build-out.tgz -- "$1"' build "$BUILD_OUT" </dev/null &&
          "$SW" get "$id" /tmp/build-out.tgz "$staging/out.tgz"; } || status=$?
        if [ "$status" -eq 0 ]; then
            mkdir -p "$staging/out"
            tar -xzf "$staging/out.tgz" -C "$staging/out"
            rm -rf "$BUILD_OUT_DIR"
            mkdir -p "$(dirname "$BUILD_OUT_DIR")"
            mv "$staging/out/$BUILD_OUT" "$BUILD_OUT_DIR"
        fi
    fi
    rm -rf "$staging"
    return "$status"
}

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
            # A lease of this script's that outlived its run (one is
            # reclaimed when its hour is up anyway), then the volume (with
            # SHIREWORKS_TOKEN or SHIREWORKS_API_KEY: a CI job's grant can't).
            for lease in $("$SW" list --label="$LABEL" | cut -d' ' -f1); do
                "$SW" release "$lease" || true
            done
            "$SW" volume-delete "$VOLUME" || { echo "build.sh: the volume $VOLUME is still there" >&2; exit 1; }
            exit 0 ;;
        *) break ;;
    esac
done

# The lease: 6 CPUs and 16 GB, the VMs' size (a Swift build thrashes in
# less); Rosetta, for Android's x86_64 SDK and NDK tools; Bazel's tree on
# the kept volume. Released however this ends, renewed while it runs.
BUILD_SOURCE_ROOT="${checkout:-$ROOT}" BUILD_CHECKOUT="$([ -n "$checkout" ] && echo 1 || echo 0)"
BUILD_MODULE="$module" BUILD_AFTER="$after" BUILD_OUT="$out" BUILD_OUT_DIR="$out_dir" BUILD_APPLE_SDKS="$apple_sdks"
id=""
renewer=""
finish() {
    [ -n "$renewer" ] && kill "$renewer" 2>/dev/null
    [ -n "$id" ] && "$SW" release "$id" >/dev/null 2>&1
    id=""
}
trap finish EXIT
trap 'exit 143' TERM INT
eval "$("$SW" lease container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --volume="$VOLUME:/var/cache/bazel:128:keep" --minutes=60 --label="$LABEL")"
id="${SHIREWORKS_ID:-}"
[ -n "$id" ] || { echo "build.sh: no container came" >&2; exit 1; }
(
    while sleep 600; do "$SW" renew "$id" --minutes=60 >/dev/null 2>&1 || true; done
) &
renewer=$!
build_in_lease "$@"
