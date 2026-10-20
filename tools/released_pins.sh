#!/bin/sh
# Whether every dependency is pinned to a released version: a SwiftPM
# package by version (exact:, from:, a range), not a revision, a branch or a
# path; a Bazel module from a registry (the project's, then the BCR), not a
# git or archive override, and not a local one outside this repository.
# The examples and the Playground are modules of their own over this
# checkout (`local_path_override(path = "..")`): an override that stays
# inside the repository is the same commit, not a pin.
#
# A branch may pin a revision while what it needs is in development, and so
# may main between releases; a release may not. CI's `pins` job runs this on
# main's commits, which releases are of, and Reviews holds a release until
# it passes (as visor's and agent_ui's tools/released_pins.sh).
cd "$(dirname "$0")/.." || exit 1
root=$(pwd -P)
status=0
for manifest in $(git ls-files 'Package.swift' '*/Package.swift'); do
  if grep -n -E '(revision|branch):[[:space:]]*"|\.package\([[:space:]]*path:' "$manifest"; then
    echo "$manifest: a package pinned to a revision, a branch or a path, not a released version" >&2
    status=1
  fi
done
for module in $(git ls-files 'MODULE.bazel' '*/MODULE.bazel'); do
  if grep -n -E '^[[:space:]]*(git_override|archive_override)\(' "$module"; then
    echo "$module: a module from git or an archive, not a registry release" >&2
    status=1
  fi
  # Each local_path_override's path, relative to its MODULE.bazel's folder.
  for path in $(awk '/^[[:space:]]*local_path_override\(/ { inside = 1 }
                     inside && match($0, /path[[:space:]]*=[[:space:]]*"[^"]*"/) {
                       value = substr($0, RSTART, RLENGTH); sub(/^[^"]*"/, "", value); sub(/"$/, "", value)
                       print value; inside = 0 }' "$module"); do
    target=$(cd "$(dirname "$module")" && cd "$path" 2>/dev/null && pwd -P)
    case "$target/" in
      "$root"/*) ;;
      *) echo "$module: local_path_override(path = \"$path\") is outside this repository" >&2
         status=1 ;;
    esac
  done
done
[ "$status" = 0 ] && echo "Every dependency is pinned to a released version."
exit "$status"
