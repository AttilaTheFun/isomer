#!/bin/bash
# Stamps a publishing job's checkout with its builds' version, before they
# are built: the Storybook's, on every platform (AGENTS.md, "Versions").
# MODULE.bazel and the apps commit MAJOR.MINOR.0; a build is MAJOR.MINOR.N,
# N the Storybook's (the number releases are tagged with, v0.47.N; the
# Playground's until it moved to AttilaTheFun/playground in 0.47), from the
# repository's own releases (tools/ci/version_from_tags.sh, which writes it
# into the Info.plists' CFBundleShortVersionString): the version of a
# release already made on the job's commit (a proposal run again, or the
# release job of a published one), else one past the highest v<line>.N
# among the releases, drafts included, and tags. A new line (a minor bumped
# and committed as MAJOR.MINOR.0) has none yet, so its builds count from
# MAJOR.MINOR.1. Then examples/tools/stamp_storybook.py writes the same
# version wherever else the app shows it: Android's versionName and
# versionCode (MAJOR x 1,000,000 + MINOR x 1,000 + N), the web page's, the
# desktop hosts'. Never committed: each job checks out afresh.
#
#   tools/ci/stamp_apps.sh             # the version from the releases
#   tools/ci/stamp_apps.sh <version>   # that version, of the committed line,
#                                      # as another job of the run found it
#
# The version is also written to $GITHUB_OUTPUT as `version`, when there is
# one, so the run's other jobs stamp the same: a workflow's jobs build on
# several machines (the Apple apps on a Mac, Android on an x86_64 runner).
#
# From the job's environment, with no <version>, as version_from_tags.sh's:
# GH_TOKEN, the job's (with `contents: write`, which lists drafts; a
# published release is listed with `contents: read`), GITHUB_REPOSITORY and
# GITHUB_SHA.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
examples="$ROOT/examples"
# version_from_tags.sh takes the line from the first Info.plist.
plists=(
    "$examples/apple/storybook_ios_application/Info.plist"
    "$examples/apple/storybook_macos_application/Info.plist"
)
if [ $# -eq 0 ]; then
    "$ROOT/tools/ci/version_from_tags.sh" "${plists[@]}"
else
    # The version given: of the line the first Info.plist commits, written
    # into each CFBundleShortVersionString (its first <string> after the key).
    given="$1"
    committed="$(awk '
        /<key>CFBundleShortVersionString<\/key>/ { found = 1 }
        found && match($0, /<string>[^<]*<\/string>/) { print substr($0, RSTART + 8, RLENGTH - 17); exit }' "${plists[0]}")"
    line="$(printf '%s' "$committed" | cut -d. -f1,2)"
    case "$given" in
        "$line".[0-9]*) [[ "${given#"$line".}" =~ ^[0-9]+$ ]] ||
            { echo "stamp_apps: $given is not $line.N" >&2; exit 1; } ;;
        *) echo "stamp_apps: $given is not of the committed line, $line" >&2; exit 1 ;;
    esac
    for plist in "${plists[@]}"; do
        awk -v version="$given" '
            /<key>CFBundleShortVersionString<\/key>/ { found = 1 }
            found && !done && sub(/<string>[^<]*<\/string>/, "<string>" version "</string>") { done = 1 }
            { print }
            END { exit done ? 0 : 1 }' "$plist" > "$plist.stamped" ||
            { rm -f "$plist.stamped"; echo "stamp_apps: $plist was not stamped" >&2; exit 1; }
        cat "$plist.stamped" > "$plist" && rm -f "$plist.stamped"
    done
fi

# What was written.
version="$(awk '
    /<key>CFBundleShortVersionString<\/key>/ { found = 1 }
    found && match($0, /<string>[^<]*<\/string>/) { print substr($0, RSTART + 8, RLENGTH - 17); exit }' "${plists[0]}")"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "stamp_apps: ${plists[0]}'s version, \"$version\", is not MAJOR.MINOR.BUILD" >&2; exit 1 ;;
esac

python3 "$examples/tools/stamp_storybook.py" "$version"
[ -z "${GITHUB_OUTPUT:-}" ] || echo "version=$version" >> "$GITHUB_OUTPUT"
echo "stamp_apps: the Storybook is $version"
