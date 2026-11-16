#!/bin/bash
# CI's Bazel settings, on GitHub's runners alone (nothing of the project's
# own servers): written before a job's first Bazel command, as the
# .bazelrc.user of isomer's module and of the examples' (both try-import
# it), so every Bazel the job runs reads them, its scripts' and
# tools/proof/proof.py's alike.
#
#   tools/ci/ci_bazel.sh setup [<cache>]   # the settings (<cache>: ISOMER_BAZEL_CACHE)
#   tools/ci/ci_bazel.sh trim <cache> <GB> # the disk cache cut to <GB>, before it is saved
#
# setup writes:
# - Bazel's disk cache and repository cache in <cache>/disk and
#   <cache>/repository, which the workflow keeps in GitHub's cache
#   (actions/cache, by job and MODULE.bazel), when a cache is named;
# - GitHub's downloads tried at GitHub, then at Bazel's mirror (GitHub's
#   release downloads have failed with 504s for hours), each retried;
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
#   BUILDBUDDY_API_KEY is set (the repository's secret, which the workflow
#   hands this step alone; a fork's pull request has none and builds on
#   GitHub's cache alone): the config and the key's headers in a file of
#   the job's own outside the checkout (mode 600), which .bazelrc.user
#   imports by its path, the key never on a command line nor in the log.
#   Only main's builds (a push to main: populate, bazel8) and the release
#   jobs (alpha and alpha-apple on main, a published release's) upload;
#   every other run reads (--noremote_upload_local_results), so a pull
#   request's results never enter the cache. A reader downloads only the
#   top-level outputs (Bazel's default, the files the jobs copy and run); a
#   writer downloads them all, so the disk cache GitHub's cache keeps
#   (above) stays whole for the runs that have no key.
# Never the Apple targets on Linux (.bazelrc's apple_on_linux, which takes
# Xcode's SDK archive): Apple's SDKs may not be redistributed, so CI builds
# the Apple targets on GitHub's Macs with their own Xcode (the owner,
# 2026-11-15). A builder with the archive turns apple_on_linux on in a
# .bazelrc.user of its own, as tools/linux/build.sh does.
# It refuses to replace a .bazelrc.user it didn't write (a builder's own).
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
    # TEMPORARY (this pull request's cold test of the combined job): no cache.
    [ "${GITHUB_JOB:-}" != container-android ] || cache=""
    mkdir -p "$ROOT/.ci"
    {
        echo 'rewrite (github\.com/.*) $1'
        echo 'rewrite (github\.com/.*) mirror.bazel.build/$1'
    } > "$ROOT/.ci/downloader.cfg"
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
        writer=0
        case "${GITHUB_EVENT_NAME:-}:${GITHUB_REF:-}" in
            push:refs/heads/main | release:*) writer=1 ;;
            workflow_dispatch:refs/heads/main)
                case "${GITHUB_JOB:-}" in alpha | alpha-apple) writer=1 ;; esac ;;
        esac
        secret_dir="$HOME/.config/isomer-ci"
        (umask 077 && mkdir -p "$secret_dir")
        chmod 700 "$secret_dir"
        secret_rc="$secret_dir/buildbuddy.bazelrc"
        (umask 077 && : > "$secret_rc")
        chmod 600 "$secret_rc"
        {
            echo "common --config=buildbuddy"
            printf 'common --remote_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            printf 'common --bes_header=x-buildbuddy-api-key=%s\n' "$BUILDBUDDY_API_KEY"
            if [ $writer -eq 1 ]; then
                echo "common --remote_download_all"
            else
                echo "common --noremote_upload_local_results"
            fi
        } >> "$secret_rc"
        unset BUILDBUDDY_API_KEY
        secret_rc="$(cd "$secret_dir" && here)/buildbuddy.bazelrc"
        lines+=("try-import $secret_rc")
        if [ $writer -eq 1 ]; then
            echo "ci_bazel: BuildBuddy's remote cache, read and written (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
        else
            echo "ci_bazel: BuildBuddy's remote cache, read only (${GITHUB_EVENT_NAME:-}, ${GITHUB_REF:-}, ${GITHUB_JOB:-})"
        fi
    else
        echo "ci_bazel: no BUILDBUDDY_API_KEY: no remote cache, GitHub's cache alone"
    fi
    if [ -n "$cache" ]; then
        mkdir -p "$cache/disk" "$cache/repository"
        cache="$(cd "$cache" && here)"
        lines+=("common --disk_cache=$cache/disk" "common --repository_cache=$cache/repository")
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
    for module in "$ROOT" "$ROOT/examples"; do
        rc="$module/.bazelrc.user"
        if [ -e "$rc" ] && ! head -1 "$rc" | grep -qxF "$MARK"; then
            fail "$rc is a builder's own: not replaced"
        fi
        printf '%s\n' "${lines[@]}" > "$rc"
    done
    echo "ci_bazel: Bazel's settings written ($ROOT/.bazelrc.user, $ROOT/examples/.bazelrc.user):"
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
*)
    echo "usage: tools/ci/ci_bazel.sh setup [<cache>] | trim <cache> <GB>" >&2
    exit 2
    ;;
esac
