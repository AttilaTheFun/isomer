#!/bin/bash
# Builds Isomer's Linux targets (and, with the Apple SDK, every platform's) in
# a Linux container leased from OS Server: arm64 on Apple silicon, in the
# image a Visor session runs in (Visor's agent image, tools/ci/agent_image,
# as CI's tools/ci/container_build.sh builds: Swift, clang, Bazel, the
# libraries the Linux targets link, x86_64 glibc and Rosetta for Android's
# tools). The checkout's files (what git tracks, and new files it would) are
# copied in at each run; Bazel's output and downloads stay on a kept volume
# between runs.
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
#                                              # SHA-256, in <dir> or a folder in it) copied onto
#                                              # the volume once, Bazel given them by
#                                              # --distdir, and .bazelrc's apple_on_linux on
#   tools/linux/build.sh --stop                # release a lease of this script's still held, and
#                                              # delete the volume (its Bazel tree)
#
#   OSS                   OS Server's command line (default: the one inside OS
#                         Server's app, else oss on the PATH)
#   ISOMER_LINUX_IMAGE    the image (default: tools/ci/agent_image's)
#   ISOMER_LINUX_VOLUME   Bazel's tree (default: isomer-linux-build)
#
# Each run is one `oss machine run container`: a lease of five minutes,
# renewed while the build runs and released however it ends (SIGTERM
# releases it at once; a run killed outright is reclaimed within the five
# minutes). The lease runs this script again (--in-lease) here, with OSS_ID
# set, and that does the work through oss: the checkout goes in as an
# archive (`oss machine upload`) and is unpacked into /work, the build runs
# with `oss machine exec`, and what --out names comes back as an archive on
# exec's output. Nothing of the Mac is mounted, so this works from any
# client OS Server lends a container to (a Mac, a session's container), and
# the checkout's own bazel-* links are left alone. Bazel's tree is the
# volume, at /var/cache/bazel, kept (`:keep`) when the lease goes, so a run
# builds only what changed; one build at a time uses it (a second, while
# one runs, is refused the volume). Until 2026-10-31 this was a plain Apple
# `container` this script made and kept itself (from 0.38; an oss one before).
#
# OS Server's client gives up when the server's hello is slow ("no oss
# server answered", a busy Mac's server): nothing was asked of it then, so
# every oss command here is asked again, up to five times, ten seconds
# apart (the lease itself is exec'd: the server is asked once just before
# it, that way). Any other failure is the command's own.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
IMAGE="${ISOMER_LINUX_IMAGE:-$(cat "$ROOT/tools/ci/agent_image")}"
VOLUME="${ISOMER_LINUX_VOLUME:-isomer-linux-build}"
# This script's leases are known by their label (--stop releases them).
LABEL="isomer tools/linux/build.sh"

if [ -z "${OSS:-}" ]; then
    OSS="/Applications/OS Server.app/Contents/Helpers/oss"
    [ -x "$OSS" ] || OSS="$(command -v oss || true)"
fi
[ -n "$OSS" ] || { echo "build.sh: no oss (OS Server's command line): install OS Server, put oss on the PATH, or set OSS" >&2; exit 1; }

# An oss command, asked again while no server answered. Its output passes
# through as it comes (a build's log); its errors too, a copy kept to read.
oss_() {
    local err status try=1
    err="$(mktemp)"
    while :; do
        set +e
        { "$OSS" "$@" 2>&1 1>&3 3>&- | tee "$err" >&2; } 3>&1
        status=${PIPESTATUS[0]}
        set -e
        if [ "$status" -ne 0 ] && [ "$try" -lt 5 ] && grep -q "no oss server answered" "$err"; then
            echo "build.sh: no OS Server answered; asking again in 10 s (try $try of 5)" >&2
            try=$((try + 1))
            sleep 10
            continue
        fi
        rm -f "$err"
        return "$status"
    done
}

if [ "${1:-}" = --in-lease ]; then
    # In the lease (below): the options from the environment, the targets
    # the arguments.
    shift
    [ -n "${OSS_ID:-}" ] || { echo "build.sh: --in-lease is the lease's (no OSS_ID)" >&2; exit 1; }
    # /work/isomer whatever isomer's checkout is called here; another
    # repository's by its folder's name.
    source_root="$BUILD_SOURCE_ROOT" name=isomer
    [ "$BUILD_CHECKOUT" = 1 ] && name="$(basename "$BUILD_SOURCE_ROOT")"
    staging="$(mktemp -d)"
    trap 'rm -rf "$staging"' EXIT

    # The checkout as git sees it (tracked, and untracked but not ignored),
    # into the container's home.
    (cd "$source_root" && git ls-files -co --exclude-standard -z | COPYFILE_DISABLE=1 tar --no-xattrs -czf "$staging/src.tgz" --null -T -)
    oss_ machine upload "$OSS_ID" "$staging/src.tgz" "/root/$name-src.tgz" >/dev/null

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
            if ! oss_ machine exec "$OSS_ID" -- test -f "$distdir/$base" </dev/null 2>/dev/null; then
                echo "build.sh: $base onto the volume" >&2
                oss_ machine upload "$OSS_ID" "$archive" "$distdir/$base" >/dev/null </dev/null
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
        command="cd /work/isomer && bazel build $flags //linux/... && cd examples && bazel build $flags //linux/... //playground/linux/..."
    fi
    # A fresh copy of the checkout each run (files deleted here go there
    # too), in the container's own /work; every bazel there (a packaging
    # command's too) keeps its tree on the volume, and Bazelisk its Bazel.
    status=0
    oss_ machine exec "$OSS_ID" -- bash -lc "
        echo 'startup --output_user_root=/var/cache/bazel' >> ~/.bazelrc
        export BAZELISK_HOME=/var/cache/bazel/bazelisk
        rm -rf /work/$name && mkdir -p /work/$name && tar -xzf /root/$name-src.tgz -C /work/$name && rm /root/$name-src.tgz
        $command" </dev/null || status=$?
    # What --out names, from the container's home, as an archive on exec's
    # output (a file or a folder alike).
    if [ "$status" -eq 0 ] && [ -n "$BUILD_OUT" ]; then
        oss_ machine exec "$OSS_ID" -- bash -c 'cd ~ && tar -cz -- "$1"' build "$BUILD_OUT" </dev/null > "$staging/out.tgz" || status=$?
        if [ "$status" -eq 0 ]; then
            mkdir -p "$staging/out"
            tar -xzf "$staging/out.tgz" -C "$staging/out"
            rm -rf "$BUILD_OUT_DIR"
            mkdir -p "$(dirname "$BUILD_OUT_DIR")"
            mv "$staging/out/$BUILD_OUT" "$BUILD_OUT_DIR"
        fi
    fi
    exit "$status"
fi

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
            # reclaimed within five minutes anyway), then the volume, which
            # OS Server deletes from its own Mac only.
            leases="$(oss_ machine list)"
            for lease in $(printf '%s\n' "$leases" | grep -F "  $LABEL" | awk '{print $1}'); do
                oss_ machine release "$lease" || true
            done
            if ! oss_ volume delete "$VOLUME"; then
                echo "build.sh: the volume $VOLUME is still there (oss volume list): delete it on OS Server's Mac with oss volume delete $VOLUME" >&2
                exit 1
            fi
            exit 0 ;;
        *) break ;;
    esac
done

# The rest is the lease's: this script again, --in-lease, with OSS_ID set,
# the options in its environment. exec makes oss this process, so a signal
# sent to the build reaches it, and it releases the container. Asked of the
# server once first, so a slow hello is asked again (above).
export BUILD_SOURCE_ROOT="${checkout:-$ROOT}" BUILD_CHECKOUT="$([ -n "$checkout" ] && echo 1 || echo 0)"
export BUILD_MODULE="$module" BUILD_AFTER="$after" BUILD_OUT="$out" BUILD_OUT_DIR="$out_dir" BUILD_APPLE_SDKS="$apple_sdks"
oss_ machine list >/dev/null
# 6 CPUs and 16 GB, the VMs' size (a Swift build thrashes in less); Rosetta,
# for Android's x86_64 SDK and NDK tools.
exec "$OSS" machine run container --image="$IMAGE" --rosetta --cpus=6 --memory=16 \
    --volume="$VOLUME:/var/cache/bazel:128:keep" --label="$LABEL" -- \
    "$HERE/build.sh" --in-lease "$@"
