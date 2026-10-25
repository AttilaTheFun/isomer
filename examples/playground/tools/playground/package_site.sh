#!/bin/bash
# Packages Isomer's web site as isomer-site.tar.gz, the asset a GitHub
# release carries and .github/workflows/pages.yml (in the isomer checkout
# above) deploys to https://attilathefun.github.io/isomer/. NOT run by any
# build or test: publishing is deliberate (docs/playground_web.md,
# "Publishing").
#
#   tools/playground/package_site.sh --toolchain-from <dir> [--out <file>] [--slice <dir>]
#
#   --toolchain-from  a staged in-browser toolchain: an earlier site's
#                     playground/toolchain (manifest.json, bundle.bin.gz,
#                     swift-frontend.wasm*.gz, wasm-ld.wasm*.gz), or what
#                     tools/browser_toolchain/stage_bundle.sh writes from a
#                     fresh compiler build. Its compiler, linker and macro
#                     plugins don't depend on Isomer and are reused as they
#                     are; everything that does is staged fresh from this tree.
#   --out             the archive (default: isomer-site.tar.gz in the
#                     current directory)
#   --slice           the Swift SDK's wasm32-unknown-wasip1 slice (default:
#                     the one in the examples' Bazel output base)
#
# What it does, from examples/playground/:
#   1. `bazel build -c opt` the whole site (//playground/web/splash_web_application:site:
#      the front page at the root, the Playground under playground/; -c opt
#      because iOS Safari overflows its stack on an -Onone page) and the SDK
#      the Playground's projects compile against
#      (//playground/apple/playground_ios_application:playground_sdk).
#   2. Unpacks the compiler and the linker from the given toolchain (gunzips
#      them, joining their parts in the manifest's order) and its macro
#      plugins (out of bundle.bin.gz, at the manifest's offsets).
#   3. Stages the toolchain with tools/browser_toolchain/stage_bundle.sh
#      against this tree's SDK and the Swift SDK's wasip1 slice, and puts
#      what the page loads (manifest.json, bundle.bin.gz and the gzipped
#      binaries) in playground/toolchain/.
#   4. Writes the archive: the site at its root, with a .nojekyll, every file
#      under 95 MB (stage_bundle.sh splits a binary that would not be).
#
# Then: `gh release upload <tag> isomer-site.tar.gz` (before the release is
# published, or run pages.yml by hand after). macOS only, as stage_bundle.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"   # the playground module
FROM=""; OUT="$PWD/isomer-site.tar.gz"; SLICE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --toolchain-from) FROM="$2"; shift 2;;
        --out) OUT="$2"; shift 2;;
        --slice) SLICE="$2"; shift 2;;
        *) echo "unknown argument $1" >&2; exit 2;;
    esac
done
[ -f "$FROM/manifest.json" ] && [ -f "$FROM/bundle.bin.gz" ] || {
    echo "usage: package_site.sh --toolchain-from <staged toolchain dir> [--out <file>] [--slice <dir>]" >&2
    echo "  (a staged toolchain has manifest.json and bundle.bin.gz)" >&2; exit 2; }
FROM="$(cd "$FROM" && pwd)"
[ -z "$SLICE" ] || SLICE="$(cd "$SLICE" && pwd)"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac
WORK="$(mktemp -d)"
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# 1. The site and the SDK.
cd "$ROOT"
SITE_TARGET=//playground/web/splash_web_application:site
SDK_TARGET=//playground/apple/playground_ios_application:playground_sdk
bazel build -c opt "$SITE_TARGET" "$SDK_TARGET"
EXEC_ROOT="$(bazel info -c opt execution_root)"
output_of() { echo "$EXEC_ROOT/$(bazel cquery -c opt --output=files "$1" 2>/dev/null)"; }
SITE="$(output_of "$SITE_TARGET")"; SDK_OUT="$(output_of "$SDK_TARGET")"
[ -f "$SITE/index.html" ] && [ -f "$SITE/playground/index.html" ] || { echo "no site at $SITE" >&2; exit 1; }
[ -f "$SDK_OUT/manifest.json" ] || { echo "no Playground SDK at $SDK_OUT" >&2; exit 1; }
if [ -z "$SLICE" ]; then
    # rules_swift's wasm SDK repository (named for the host: _xcode on a Mac).
    SLICE="$(ls -d "$(bazel info output_base)"/external/rules_swift++swift+swift_toolchain_wasm_sdk*/*.artifactbundle/*/wasm32-unknown-wasip1 2>/dev/null | head -1)"
    [ -n "$SLICE" ] || { echo "no wasm32-unknown-wasip1 slice in the output base; pass --slice" >&2; exit 1; }
fi
mkdir -p "$WORK/sdk"
cp -RL "$SDK_OUT"/. "$WORK/sdk"/   # dereference: bazel outputs can be symlink trees
chmod -R u+w "$WORK/sdk"

# 2. The compiler, the linker and the macro plugins of the given toolchain.
mkdir -p "$WORK/bin"
python3 -I - "$FROM" "$WORK/bin" > "$WORK/plugins.txt" <<'PY'
import gzip, json, os, shutil, sys
src, out = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(src, "manifest.json")))

def unpack(entry, name):
    # An entry is a file name or a list of parts, each served gzipped as
    # <name>.gz (or raw), joined in order (compiler_worker.js's partStream).
    target = os.path.join(out, name)
    with open(target, "wb") as dest:
        for part in entry if isinstance(entry, list) else [entry]:
            path = os.path.join(src, part)
            if os.path.exists(path + ".gz"):
                with gzip.open(path + ".gz", "rb") as data: shutil.copyfileobj(data, dest, 1 << 20)
            else:
                with open(path, "rb") as data: shutil.copyfileobj(data, dest, 1 << 20)
    with open(target, "rb") as check:
        if check.read(4) != b"\0asm": sys.exit(f"{name} from {src} is not WebAssembly")

unpack(manifest["frontend"], "swift-frontend.wasm")
unpack(manifest["linker"], "wasm-ld.wasm")
# Plugins live inside the bundle: its files are concatenated in the
# manifest's order, each at its offset.
files = {f["path"]: f for f in manifest["files"]}
with gzip.open(os.path.join(src, manifest["bundle"] + ".gz"), "rb") as bundle:
    for plugin in manifest.get("plugins", []):
        entry = files[plugin["path"]]
        bundle.seek(entry["offset"])
        data = bundle.read(entry["size"])
        if len(data) != entry["size"] or data[:4] != b"\0asm": sys.exit(f"{plugin['path']} is not in the bundle")
        path = os.path.join(out, os.path.basename(plugin["path"]))
        open(path, "wb").write(data)
        # stage_bundle.sh's --plugin spec: <file>#<module>,<module>…
        print(path + "#" + ",".join(plugin["modules"]))
PY
PLUGIN_ARGS=()
while read -r spec; do PLUGIN_ARGS+=(--plugin "$spec"); done < "$WORK/plugins.txt"
[ ${#PLUGIN_ARGS[@]} -gt 0 ] || echo "warning: $FROM has no macro plugins; @Observable will not compile" >&2

# 3. The toolchain against this tree's SDK.
"$ROOT/tools/browser_toolchain/stage_bundle.sh" \
    --frontend "$WORK/bin/swift-frontend.wasm" --linker "$WORK/bin/wasm-ld.wasm" \
    ${PLUGIN_ARGS[@]+"${PLUGIN_ARGS[@]}"} \
    --slice "$SLICE" --sdk "$WORK/sdk" --out "$WORK/toolchain"

# 4. The site: the Bazel tree dereferenced (bazel-bin sites are symlink
# trees; the first publish once pushed dangling symlinks) and the toolchain
# files the page fetches (the stage's loose files are for debugging only).
mkdir -p "$WORK/site"
cp -RL "$SITE"/. "$WORK/site"/
chmod -R u+w "$WORK/site"
mkdir -p "$WORK/site/playground/toolchain"
cp "$WORK/toolchain/manifest.json" "$WORK/toolchain/bundle.bin.gz" \
    "$WORK/toolchain"/swift-frontend.wasm*.gz "$WORK/toolchain"/wasm-ld.wasm*.gz \
    "$WORK/site/playground/toolchain/"
touch "$WORK/site/.nojekyll"
if find "$WORK/site" -type f -size +95M | grep -q .; then
    find "$WORK/site" -type f -size +95M -print | sed 's/^/over 95 MB: /' >&2; exit 1
fi
# No owner names and no macOS metadata (._ files, xattrs) in the archive.
rm -f "$OUT"
tar --no-mac-metadata --no-xattrs --numeric-owner --uid 0 --gid 0 -czf "$OUT" -C "$WORK/site" .
largest="$(find "$WORK/site" -type f -exec stat -f '%z %N' {} + | sort -n | tail -1)"
echo "wrote $OUT: $(stat -f %z "$OUT") bytes, $(find "$WORK/site" -type f | wc -l | tr -d ' ') files"
echo "largest file: ${largest#* "$WORK/site/"} (${largest%% *} bytes)"
echo "next: gh release upload <tag> $OUT"
