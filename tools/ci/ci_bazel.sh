#!/bin/bash
# CI's Bazel settings, on GitHub's runners alone (nothing of the project's
# own servers): written before a job's first Bazel command, as the
# .bazelrc.user of isomer's module and of the examples' (both try-import
# it), so every Bazel the job runs reads them, its scripts' and
# tools/proof/proof.py's alike.
#
#   tools/ci/ci_bazel.sh setup [<cache>]   # the settings (<cache>: ISOMER_BAZEL_CACHE)
#   tools/ci/ci_bazel.sh trim <cache> <GB> # the disk cache cut to <GB>, before it is saved
#   tools/ci/ci_bazel.sh maven <cache>     # the Maven artifacts' cache, before it is saved
#
# setup writes:
# - Bazel's disk cache and repository cache in <cache>/disk and
#   <cache>/repository, which the workflow keeps in GitHub's cache
#   (actions/cache, by job and MODULE.bazel), when a cache is named; the
#   Maven artifacts' cache (<cache>/maven, below) copied into the
#   repository cache first;
# - the same downloads and repository cache for tests/sdk_consumer (a
#   consumer's module, which tools/ci/sdk_smoke builds), and nothing else
#   of CI's there: its builds are a consumer's own;
# - GitHub's downloads tried at GitHub, then at Bazel's mirror (GitHub's
#   release downloads have failed with 504s for hours), and Maven Central's
#   at Central, then at Google's mirror of it (Central has answered 404 for
#   artifacts it has), each retried: tools/ci/downloader.cfg;
# - Bazel's tree (--output_user_root) in ISOMER_BAZEL_ROOT when it is set
#   and can be made: the x86_64 runner's second disk (/mnt), its first
#   being too small for an Android build's; C:/b on Windows (short paths);
# - Windows on Linux (--config=windows_on_linux's toolchains), when
#   ISOMER_WINDOWS_SDKS says where the Windows Swift SDK and Microsoft's
#   sysroot are (tools/windows/README.md): a folder holding them (Bazel's
#   --distdir), or a URL serving each file by its SHA-256 (<url>/<sha256>,
#   as MODULE.bazel's windows-sdks.invalid placeholders name them).
#   Microsoft's may not be redistributed, so nothing public serves it, and
#   CI names none: CI builds Windows on Windows itself
#   (tools/ci/windows_build.ps1, the runner image's Visual Studio).
# - BuildBuddy's remote cache (.bazelrc's --config=buildbuddy), when
#   BUILDBUDDY_API_KEY is set: the config and the key's headers in a file of
#   the job's own outside the checkout (mode 600), which .bazelrc.user
#   imports by its path, the key never on a command line nor in the log.
#   The workflow hands the key to every job on GitHub's runners, before a
#   merge and after it (the owner, 2026-11-23): each reads and writes. A
#   fork's pull request gets no secrets from GitHub, so it builds on
#   GitHub's cache alone. main's builds (a push to main: populate, bazel8)
#   and the release jobs (alpha and alpha-apple on main, a published
#   release's) download every output, so the disk cache GitHub's cache
#   keeps (above) stays whole for the runs with no key; the others download
#   only the top-level outputs (Bazel's default, the files the jobs copy and
#   run).
# BuildBuddy's cache is partitioned by the dependency graph
# (--remote_instance_name, a hash of both modules' MODULE.bazel and both
# SwiftPM graphs' Package.resolved): a cache from before a Swift SDK
# change served the changed tree a stale object (the Playground's CI,
# isomer 0.55.1's cache to 0.56.1: the Android link failed on the old
# Foundation's symbols). Its cause isn't pinned down: the SDK's files are
# SwiftCompile's inputs (rules_swift 4.3.0; a wasm SDK swapped, the compile
# ran again), but SwiftCompile runs unsandboxed here (.bazelrc), so a file
# it reads undeclared is outside its key. So one graph's outputs are never
# served to another's. The disk cache GitHub keeps is restored by the same
# graph alone (.github/actions/bazel_cache).
# Never the Apple targets on Linux (.bazelrc's apple_on_linux, which takes
# Xcode's SDK archive): Apple's SDKs may not be redistributed, so CI builds
# the Apple targets on GitHub's Macs with their own Xcode (the owner,
# 2026-11-15). A builder with the archive turns apple_on_linux on in a
# .bazelrc.user of its own, as tools/linux/build.sh does.
# It refuses to replace a .bazelrc.user it didn't write (a builder's own).
#
# maven: the Maven artifacts the job's builds downloaded, out of the
# repository cache into <cache>/maven (the repository cache's own layout),
# which .github/actions/bazel_cache_save keeps in GitHub's cache on its
# own, by the Maven lock files: tools/ci/maven_cache.swift. It is small
# (Maven's jars, no toolchains), so it outlasts the repository cache, which
# GitHub's 10 GB a repository evicts (main's ubuntu one has been, while
# Central answered 404: every Maven artifact then came from Central again).
#
# trim: Bazel collects its disk cache's garbage only when its server is
# idle, which a CI job's seldom is, so the oldest entries (Bazel touches an
# entry each time it is read) are removed until the cache is under <GB>:
# the caches a workflow keeps share GitHub's 10 GB a repository.
set -euo pipefail
# A folder as Bazel names it: on Windows (Git's bash, CI's windows-11-arm
# job) D:/a/…, not /d/a/….
here() { case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) pwd -W ;; *) pwd ;; esac; }
ROOT="$(cd "$(dirname "$0")/../.." && here)"
MARK="# tools/ci/ci_bazel.sh's: CI's Bazel settings"
fail() { echo "ci_bazel: $*" >&2; exit 1; }

case "${1:-}" in
setup)
    cache="${2:-${ISOMER_BAZEL_CACHE:-}}"
    mkdir -p "$ROOT/.ci"
    cp "$ROOT/tools/ci/downloader.cfg" "$ROOT/.ci/downloader.cfg"
    # No bazel-* convenience symlinks in the checkout: rules_swift_package_manager
    # copies the local isomer package with `cp -RL`, which follows them into
    # Bazel's output tree and its dangling links, and fails the fetch.
    lines=("$MARK" "common --downloader_config=$ROOT/.ci/downloader.cfg"
           "common --experimental_repository_downloader_retries=5"
           "common --experimental_convenience_symlinks=ignore")
    if [ -n "${ISOMER_BAZEL_ROOT:-}" ]; then
        if mkdir -p "$ISOMER_BAZEL_ROOT" 2> /dev/null && [ -w "$ISOMER_BAZEL_ROOT" ]; then
            lines+=("startup --output_user_root=$ISOMER_BAZEL_ROOT")
        else
            echo "::warning::ci_bazel: $ISOMER_BAZEL_ROOT can't be made: Bazel's tree stays in its default place"
        fi
    fi
    # BuildBuddy, with the key: never traced, never echoed.
    if [ -n "${BUILDBUDDY_API_KEY:-}" ]; then
        set +x
        # Whether this run downloads every output (above).
        whole=0
        case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
            push:refs/heads/main | release:*) whole=1 ;;
            workflow_dispatch:refs/heads/main)
                case "${GITHUB_JOB:-}" in alpha | alpha-apple) whole=1 ;; esac ;;
        esac
        secret_dir="$HOME/.config/isomer-ci"
        (umask 077 && mkdir -p "$secret_dir")
        chmod 700 "$secret_dir"
        secret_rc="$secret_dir/buildbuddy.bazelrc"
        (umask 077 && : > "$secret_rc")
        chmod 600 "$secret_rc"
        # The graph's hash (above): the files that exist of the four, in
        # this order, so a missing one changes the hash rather than failing.
        graph="$(for file in MODULE.bazel examples/MODULE.bazel \
                third_party/swift_packages/Package.resolved \
                examples/third_party/swift_packages/Package.resolved; do
                    if [ -f "$ROOT/$file" ]; then echo "== $file"; cat "$ROOT/$file"; fi
                done |
            { if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi; } | cut -c1-16)"
        {
            echo "common --config=buildbuddy"
            echo "common --remote_instance_name=isomer-$graph"
            printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            printf 'common --bes_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            if [ $whole -eq 1 ]; then echo "common --remote_download_all"; fi
        } >> "$secret_rc"
        unset BUILDBUDDY_API_KEY
        secret_rc="$(cd "$secret_dir" && here)/buildbuddy.bazelrc"
        lines+=("try-import $secret_rc")
        echo "ci_bazel: BuildBuddy's remote cache, read and written$([ $whole -eq 1 ] && echo ", every output downloaded") (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
    else
        # A fork's pull request (GitHub gives it no secrets), or a builder's own.
        echo "ci_bazel: no BUILDBUDDY_API_KEY: no remote cache, GitHub's cache alone"
    fi
    consumer=("$MARK" "common --downloader_config=$ROOT/.ci/downloader.cfg"
              "common --experimental_repository_downloader_retries=5")
    if [ -n "$cache" ]; then
        mkdir -p "$cache/disk" "$cache/repository"
        cache="$(cd "$cache" && here)"
        lines+=("common --disk_cache=$cache/disk" "common --repository_cache=$cache/repository")
        consumer+=("common --repository_cache=$cache/repository")
        # The Maven artifacts' cache (bazel_cache restored it), into the
        # repository cache: both are content_addressable/sha256/<hex>/,
        # an entry named by its file's checksum (one already there is kept).
        if [ -d "$cache/maven/content_addressable/sha256" ]; then
            mkdir -p "$cache/repository/content_addressable/sha256"
            for entry in "$cache/maven/content_addressable/sha256"/*; do
                [ -e "$cache/repository/content_addressable/sha256/${entry##*/}" ] ||
                    cp -R "$entry" "$cache/repository/content_addressable/sha256/"
            done
            echo "ci_bazel: the Maven artifacts' cache, $(find "$cache/maven/content_addressable" -name file | wc -l | tr -d ' ') files, in the repository cache"
        fi
    fi
    # sdks <ISOMER_*_SDKS's value> <placeholder host> <rewrite of it>: a
    # folder as a distdir, a URL as the placeholder's rewrite.
    sdks() {
        case "$1" in
            http://* | https://*)
                printf '%s\n' "$3" | sed "s|@URL@|${1%/}|" >> "$ROOT/.ci/downloader.cfg" ;;
            *)
                [ -d "$1" ] || fail "$2: no folder $1"
                lines+=("common --distdir=$(cd "$1" && here)") ;;
        esac
    }
    if [ -n "${ISOMER_WINDOWS_SDKS:-}" ]; then
        sdks "$ISOMER_WINDOWS_SDKS" ISOMER_WINDOWS_SDKS "rewrite windows-sdks\\.invalid/sha256/(.*) @URL@/\$1"
    fi
    for module in "$ROOT" "$ROOT/examples" "$ROOT/tests/sdk_consumer"; do
        rc="$module/.bazelrc.user"
        if [ -e "$rc" ] && ! head -1 "$rc" | grep -qxF "$MARK"; then
            fail "$rc is a builder's own: not replaced"
        fi
        if [ "$module" = "$ROOT/tests/sdk_consumer" ]; then
            printf '%s\n' "${consumer[@]}" > "$rc"
        else
            printf '%s\n' "${lines[@]}" > "$rc"
        fi
    done
    echo "ci_bazel: Bazel's settings written ($ROOT/.bazelrc.user, $ROOT/examples/.bazelrc.user; $ROOT/tests/sdk_consumer/.bazelrc.user its downloads alone):"
    sed 's/^/  /' "$ROOT/examples/.bazelrc.user"
    ;;
trim)
    cache="${2:?usage: ci_bazel.sh trim <cache> <GB>}"
    gb="${3:?usage: ci_bazel.sh trim <cache> <GB>}"
    [[ "$gb" =~ ^[0-9]+$ ]] || fail "<GB> is a whole number of gigabytes"
    [ -d "$cache/disk" ] || { echo "ci_bazel: no disk cache in $cache"; exit 0; }
    limit=$((gb * 1024 * 1024))
    # Every entry's time and size (KB), the newest first; what is past the
    # limit, counted from the newest, goes. python3: find's -printf is
    # GNU's alone, and a Mac's runner trims too. Windows' Python may be
    # `python` alone (its `python3` the Store's stub).
    python=""
    for candidate in python3 python; do
        if command -v "$candidate" > /dev/null && "$candidate" -c "" 2> /dev/null; then python="$candidate"; break; fi
    done
    [ -n "$python" ] || fail "no Python here"
    "$python" -I - "$cache/disk" "$limit" << 'PY'
import os, sys
root, limit = sys.argv[1], int(sys.argv[2]) * 1024
entries = []
for folder, _, names in os.walk(root):
    for name in names:
        path = os.path.join(folder, name)
        try:
            stat = os.lstat(path)
        except OSError:
            continue
        entries.append((stat.st_mtime, stat.st_size, path))
entries.sort(reverse=True)
kept = removed = 0
for _, size, path in entries:
    if kept + size <= limit:
        kept += size
    else:
        os.remove(path)
        removed += size
print(f"ci_bazel: the disk cache is {kept / 2**30:.2f} GB ({removed / 2**30:.2f} GB of its oldest entries removed)")
PY
    ;;
maven)
    cache="${2:?usage: ci_bazel.sh maven <cache>}"
    [ -d "$cache/repository" ] || { echo "ci_bazel: no repository cache in $cache"; exit 0; }
    # The lock files: the checkout's, and those of the modules the builds
    # fetched (rules_jvm_external's own tools'), in each module's output base.
    externals=()
    for module in "$ROOT" "$ROOT/examples"; do
        base="$(cd "$module" && bazel info output_base 2> /dev/null)" && [ -d "$base/external" ] && externals+=("$base/external")
    done
    work="$(mktemp -d)"
    swiftc -O -o "$work/maven_cache" "$ROOT/tools/ci/maven_cache.swift"
    rm -rf "$cache/maven"
    "$work/maven_cache" "$cache/repository" "$cache/maven" "$ROOT" ${externals[@]+"${externals[@]}"}
    rm -rf "$work"
    ;;
*)
    echo "usage: tools/ci/ci_bazel.sh setup [<cache>] | trim <cache> <GB> | maven <cache>" >&2
    exit 2
    ;;
esac
