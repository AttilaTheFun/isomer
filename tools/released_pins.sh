#!/bin/sh
# Whether every dependency is pinned to a released version: a SwiftPM
# package by version (exact:, from:, a range), by a release's tag
# (`revision: "v0.43.1"`: isomer, whose dependencies SwiftPM allows only
# beneath a revision), or by a release tag's commit where the tag isn't a
# version (`revision:` with a `// tag: <tag>` comment), not another
# revision, a branch or a path outside this repository; a Bazel module from
# a registry (the project's, then the BCR), not a git or archive override,
# and not a local one outside this repository. The examples and the
# Playground are modules of their own over this checkout
# (`local_path_override(path = "..")`, and isomer's package by
# `.package(path:)`): what stays inside the repository is the same commit,
# not a pin.
#
# A branch may pin a revision while what it needs is in development, and so
# may main between releases; a release may not. CI's `pins` job runs this on
# main's commits, which releases are of, and Reviews holds a release until
# it passes (as visor's and agent_ui's tools/released_pins.sh).
cd "$(dirname "$0")/.." || exit 1
root=$(pwd -P)
status=0
for manifest in $(git ls-files 'Package.swift' '*/Package.swift'); do
  if grep -n -E 'branch:[[:space:]]*"' "$manifest"; then
    echo "$manifest: a package pinned to a branch, not a released version" >&2
    status=1
  fi
  for path in $(sed -n 's/.*\.package([[:space:]]*path:[[:space:]]*"\([^"]*\)".*/\1/p' "$manifest"); do
    target=$(cd "$(dirname "$manifest")" && cd "$path" 2>/dev/null && pwd -P)
    case "$target" in
      "$root" | "$root"/*) ;;
      *) echo "$manifest: .package(path: \"$path\") is outside this repository" >&2
         status=1 ;;
    esac
  done
  # A revision is a release only as a tag's commit: one whose version
  # SwiftPM can't read (swift-foundation's swift-6.4.2-RELEASE), named in a
  # `// tag: <tag>` comment on its line, and checked against the tag.
  grep -n -E 'revision:[[:space:]]*"' "$manifest" | grep -v -E '^[0-9]+:[[:space:]]*//' | while IFS= read -r line; do
    url=$(printf '%s\n' "$line" | sed -n 's/.*url:[[:space:]]*"\([^"]*\)".*/\1/p')
    revision=$(printf '%s\n' "$line" | sed -n 's/.*revision:[[:space:]]*"\([^"]*\)".*/\1/p')
    # A release's own tag, which SwiftPM resolves to its commit.
    if printf '%s\n' "$revision" | grep -q -E '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
      if [ -z "$(git ls-remote "$url" "refs/tags/$revision")" ]; then
        echo "$manifest:$line" >&2
        echo "$manifest: a package pinned to a tag that $url doesn't have" >&2
        exit 1
      fi
      continue
    fi
    tag=$(printf '%s\n' "$line" | sed -n 's|.*// tag: *\([^ ]*\).*|\1|p')
    tagged=""
    [ -n "$tag" ] && tagged=$(git ls-remote "$url" "refs/tags/$tag" "refs/tags/$tag^{}" | tail -1 | cut -f1)
    if [ -z "$tag" ] || [ "$tagged" != "$revision" ]; then
      echo "$manifest:$line" >&2
      echo "$manifest: a package pinned to a revision that isn't a named release tag's commit" >&2
      exit 1
    fi
  done || status=1
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
