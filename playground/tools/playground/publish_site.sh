#!/bin/bash
# Publishes the built site (splash + Playground + toolchain bundle) to a
# GitHub Pages branch. NOT run automatically — the site is the framework's
# public announcement; publish deliberately.
#
#   tools/playground/publish_site.sh <site-dir> <toolchain-stage-dir> <checkout> [subdir]
#
# Copies the site (+ the staged in-browser toolchain under playground/toolchain:
# manifest.json, bundle.bin.gz, swift-frontend.wasm*.gz, wasm-ld.wasm*.gz)
# into <subdir> (default "web") of an existing checkout of the Pages repo,
# commits and pushes its current branch. Everything must stay under GitHub's
# 100 MB per-file limit (the staging script splits the compiler into parts).
set -euo pipefail
SITE="${1:?site dir}"; STAGE="${2:?toolchain stage dir}"; CHECKOUT="${3:?pages repo checkout}"; SUBDIR="${4:-web}"
DEST="$CHECKOUT/$SUBDIR"
rm -rf "$DEST"; mkdir -p "$DEST"
cp -RL "$SITE"/. "$DEST"/   # dereference: bazel-bin sites are symlink trees
chmod -R u+w "$DEST"
mkdir -p "$DEST/playground/toolchain"
cp "$STAGE/manifest.json" "$STAGE/bundle.bin.gz" "$DEST/playground/toolchain/"
cp "$STAGE"/swift-frontend.wasm*.gz "$STAGE"/wasm-ld.wasm*.gz "$DEST/playground/toolchain/"
touch "$CHECKOUT/.nojekyll"
if find "$DEST" -size +95M | grep -q .; then find "$DEST" -size +95M -print | sed 's/^/too large for GitHub: /'; exit 1; fi
cd "$CHECKOUT"
git add -A
git commit -qm "Publish site $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git push
echo "pushed $SUBDIR to $(git remote get-url origin)"
