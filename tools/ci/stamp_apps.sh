#!/bin/bash
# Stamps a publishing job's checkout with its builds' version, before they
# are built: the Storybook's and the Playground's, on every platform, one
# version for both (AGENTS.md, "Versions"). MODULE.bazel and the apps
# commit MAJOR.MINOR.0; a build is MAJOR.MINOR.N, N the Playground's (the
# number releases are tagged with, v0.39.N), the next of the line for the
# job's commit, from Applications Server (tools/ci/next_version.sh, which
# writes it into the four Info.plists' CFBundleShortVersionString). Then
# the apps' own stamps (examples/tools/stamp_storybook.py, the Playground's
# tools/playground/stamp.py) write the same version wherever else each app
# shows it: Android's versionName and versionCode (MAJOR x 1,000,000 +
# MINOR x 1,000 + N), the web page's, the desktop hosts'. Never committed:
# each job checks out afresh.
#
#   tools/ci/stamp_apps.sh
#
# From the job's environment, as next_version.sh's: its `permissions:
# id-token: write`, APPLICATIONS_CI_CODE and APPLICATIONS_AUDIENCE. A server
# without POST /api/next-version leaves the committed MAJOR.MINOR.0, with a
# warning (next_version.sh), and the stamps then write that.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
examples="$ROOT/examples"
# The Playground's iPhone app first: next_version.sh takes the line from
# the first Info.plist.
plists=(
    "$examples/playground/apple/playground_ios_application/Info.plist"
    "$examples/playground/apple/playground_macos_application/Info.plist"
    "$examples/apple/storybook_ios_application/Info.plist"
    "$examples/apple/storybook_macos_application/Info.plist"
)
"$ROOT/tools/ci/next_version.sh" Playground "${plists[@]}"

# What next_version.sh wrote (or, from an older server, what was committed).
version="$(awk '
    /<key>CFBundleShortVersionString<\/key>/ { found = 1 }
    found && match($0, /<string>[^<]*<\/string>/) { print substr($0, RSTART + 8, RLENGTH - 17); exit }' "${plists[0]}")"
case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "stamp_apps: ${plists[0]}'s version, \"$version\", is not MAJOR.MINOR.BUILD" >&2; exit 1 ;;
esac

python3 "$examples/tools/stamp_storybook.py" "$version"
python3 "$examples/playground/tools/playground/stamp.py" "$version"
echo "stamp_apps: the Storybook and the Playground are $version"
