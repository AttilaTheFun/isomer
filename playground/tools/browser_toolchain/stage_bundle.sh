#!/bin/bash
# Stages the in-browser toolchain bundle the web Playground's compile worker
# loads (`toolchain/manifest.json` + files), from:
#   --frontend swift-frontend.wasm   --linker wasm-ld.wasm   (tools/browser_toolchain builds)
#   --slice <wasm32-unknown-wasip1 slice of the swift SDK artifact bundle>
#   --sdk   <playground_sdk dir> (bazel-bin/apple/playground_ios_application/playground_sdk)
#   --out   <site>/playground/toolchain
#   --plugin <plugin.wasm>#<module>[,<module>…]   (repeatable: macro plugins
#           built by build_macro_plugins.sh, for the modules they serve)
# Copies only what a `-frontend -c` + reactor link needs: the wasi
# swiftmodules + shims + clang resource headers/builtins from swift_static,
# the sysroot's headers + the archives the link pulls, and the Playground SDK
# (SwiftUI/PlatformServices modules + archives). Prints the total size.
set -euo pipefail
FRONTEND=""; LINKER=""; SLICE=""; SDK=""; OUT=""; PLUGINS=()
while [ $# -gt 0 ]; do case "$1" in
  --frontend) FRONTEND="$2"; shift 2;; --linker) LINKER="$2"; shift 2;; --slice) SLICE="$2"; shift 2;;
  --sdk) SDK="$2"; shift 2;; --out) OUT="$2"; shift 2;; --plugin) PLUGINS+=("$2"); shift 2;;
  *) echo "unknown $1"; exit 2;; esac; done
[ -n "$SLICE" ] && [ -n "$SDK" ] && [ -n "$OUT" ] || { echo "usage: --slice --sdk --out [--frontend --linker]"; exit 2; }
[ -d "$OUT" ] && chmod -R u+w "$OUT"; rm -rf "$OUT"; mkdir -p "$OUT"
# The compiler binaries ship OUTSIDE the blob, gzipped, split into <90 MB
# parts (GitHub Pages' per-file limit); the manifest lists the parts.
split_binary() {  # <src> <name> → prints the JSON entry
  local src="$1" name="$2"
  gzip -6 -c "$src" > "$OUT/$name.gz.whole"
  local size; size=$(stat -f %z "$OUT/$name.gz.whole")
  if [ "$size" -le 94371840 ]; then
    mv "$OUT/$name.gz.whole" "$OUT/$name.gz"; echo "\"$name\""
  else
    rm "$OUT/$name.gz.whole"
    split -b 90m -a 1 "$src" "$OUT/$name.part"
    local parts=""
    for p in "$OUT"/$name.part?; do gzip -6 -f "$p"; parts="$parts,\"$(basename "$p")\""; done
    echo "[${parts#,}]"
  fi
}
FRONTEND_ENTRY='"swift-frontend.wasm"'; LINKER_ENTRY='"wasm-ld.wasm"'
[ -n "$FRONTEND" ] && FRONTEND_ENTRY=$(split_binary "$FRONTEND" swift-frontend.wasm)
[ -n "$LINKER" ] && LINKER_ENTRY=$(split_binary "$LINKER" wasm-ld.wasm)
export FRONTEND_ENTRY LINKER_ENTRY
STATIC="$SLICE/swift.xctoolchain/usr/lib/swift_static"
# The driver compiles for wasm32-unknown-wasip1: a slice of any other target
# (the -threads SDK, say) stages without complaint and then every build in
# the browser fails with "could not find module 'Swift' for target".
[ -e "$STATIC/wasi/Swift.swiftmodule/wasm32-unknown-wasip1.swiftmodule" ] || {
  echo "the slice at $SLICE is not a wasm32-unknown-wasip1 slice (no wasi/Swift.swiftmodule/wasm32-unknown-wasip1.swiftmodule)"; exit 2; }
# Resource dir: the wasi stdlib modules + archives, shims, clang headers/builtins.
mkdir -p "$OUT/resource-dir/wasi/wasm32" "$OUT/resource-dir/shims" "$OUT/resource-dir/clang/lib/wasip1"
# The SDK slice's Foundation is NOT shipped: user code's `import Foundation`
# is Isomer's, in the Playground SDK (sdk/modules), which keeps the bundle
# small (corelibs Foundation + ICU alone are ~65 MB).
for m in "$STATIC"/wasi/*.swiftmodule; do
  case "$(basename "$m")" in Foundation*|FoundationEssentials*|FoundationInternationalization*|FoundationXML*|FoundationNetworking*|XCTest*|Testing*|CoreFoundation*|_FoundationCShims*|_FoundationCollections*) continue;; esac
  if [ -d "$m" ]; then cp -R "$m" "$OUT/resource-dir/wasi/"; else cp "$m" "$OUT/resource-dir/wasi/"; fi
done
for lib in libswiftCore.a libswiftSwiftOnoneSupport.a libswiftWASILibc.a libswift_Concurrency.a libswift_RegexParser.a libswift_StringProcessing.a libswiftSynchronization.a libswiftObservation.a libswiftDistributed.a; do
  cp "$STATIC/wasi/$lib" "$OUT/resource-dir/wasi/" 2>/dev/null || true
done
cp "$STATIC"/wasi/wasm32/swiftrt.o "$OUT/resource-dir/wasi/wasm32/" 2>/dev/null || true
cp "$STATIC"/wasi/wasm32/*.modulemap "$OUT/resource-dir/wasi/wasm32/" 2>/dev/null || true
cp -R "$STATIC"/shims/. "$OUT/resource-dir/shims/"
cp -R "$STATIC"/clang/include "$OUT/resource-dir/clang/" 2>/dev/null || true
cp "$STATIC"/clang/lib/wasip1/libclang_rt.builtins-wasm32.a "$OUT/resource-dir/clang/lib/wasip1/" 2>/dev/null || true
[ -d "$STATIC/apinotes" ] && cp -R "$STATIC/apinotes" "$OUT/resource-dir/apinotes"
# Sysroot: headers + the link archives.
mkdir -p "$OUT/sysroot/lib/wasm32-wasip1"
cp -R "$SLICE/WASI.sdk/include" "$OUT/sysroot/include"
for lib in crt1-reactor.o libc.a libc++.a libc++abi.a libdl.a libm.a libwasi-emulated-mman.a libwasi-emulated-signal.a libwasi-emulated-process-clocks.a libwasi-emulated-getpid.a; do
  cp "$SLICE/WASI.sdk/lib/wasm32-wasip1/$lib" "$OUT/sysroot/lib/wasm32-wasip1/" 2>/dev/null || true
done
# The Playground SDK (SwiftUI, PlatformServices, hot bridge, skim Foundation).
cp -R "$SDK" "$OUT/sdk"
chmod -R u+w "$OUT"
# Macro plugins (wasm modules the compile worker runs beside the compiler),
# shrunk as the compiler is, in plugins/ with the modules each serves.
PLUGINS_JSON="[]"
if [ ${#PLUGINS[@]} -gt 0 ]; then
  mkdir -p "$OUT/plugins"
  PLUGINS_JSON="["
  for spec in "${PLUGINS[@]}"; do
    file="${spec%%#*}"; modules="${spec#*#}"; name="$(basename "$file")"
    if command -v wasm-opt >/dev/null; then
      wasm-opt -Oz --strip-debug --strip-producers --enable-bulk-memory --enable-sign-ext --enable-mutable-globals --enable-nontrapping-float-to-int "$file" -o "$OUT/plugins/$name"
    else
      cp "$file" "$OUT/plugins/$name"
    fi
    PLUGINS_JSON="$PLUGINS_JSON{\"path\":\"plugins/$name\",\"modules\":[\"${modules//,/\",\"}\"]},"
  done
  PLUGINS_JSON="${PLUGINS_JSON%,}]"
fi
export PLUGINS_JSON
python3 - "$OUT" "$SDK" <<'PY'
import json, os, sys
out, sdk = sys.argv[1], sys.argv[2]
manifest = json.load(open(os.path.join(sdk, "manifest.json")))
files = []
for root, _, names in os.walk(out):
    for name in names:
        path = os.path.join(root, name)
        rel = os.path.relpath(path, out)
        if rel == "manifest.json" or rel.endswith(".gz") or ".part" in rel or rel.startswith("swift-frontend.wasm") or rel.startswith("wasm-ld.wasm"): continue
        files.append({"path": rel, "size": os.path.getsize(path)})
files.sort(key=lambda f: f["path"])
# One blob for one fetch: every file concatenated, offsets in the manifest
# (the worker slices it into its MemFS). Individual files stay too, for
# debugging with a standalone WASI runtime against the same directory.
offset = 0
with open(os.path.join(out, "bundle.bin"), "wb") as blob:
    for f in files:
        data = open(os.path.join(out, f["path"]), "rb").read()
        blob.write(data)
        f["offset"] = offset
        offset += len(data)
# The version is the content's hash: the worker fetches the big files under
# it and keeps them in a cache named for it, so a browser that loaded an
# earlier toolchain can't pair its cached compiler or SDK with a newer page.
import hashlib
digest = hashlib.sha256()
for name in sorted(os.listdir(out)):
    if name == "bundle.bin" or name.startswith("swift-frontend.wasm") or name.startswith("wasm-ld.wasm"):
        with open(os.path.join(out, name), "rb") as part:
            for chunk in iter(lambda: part.read(1 << 20), b""): digest.update(chunk)
json.dump({
    "version": digest.hexdigest()[:16],
    "bundle": "bundle.bin",
    "frontend": json.loads(os.environ.get("FRONTEND_ENTRY", '"swift-frontend.wasm"')),
    "linker": json.loads(os.environ.get("LINKER_ENTRY", '"wasm-ld.wasm"')),
    "sdk": {
        "resourceDir": "resource-dir", "sysroot": "sysroot", "modules": "sdk/modules",
        "archives": ["sdk/" + a for a in manifest["archives"]],
        # The hosts' entries (isomer 0.31's SDKs list them): the link
        # exports these and dead-strips the rest; without them it exports
        # everything.
        "exports": manifest.get("exports"),
        "clangModules": [{k: "sdk/" + v for k, v in entry.items()} for entry in manifest.get("clang_modules", [])],
    },
    "plugins": json.loads(os.environ.get("PLUGINS_JSON", "[]")),
    "files": files,
}, open(os.path.join(out, "manifest.json"), "w"), indent=1)
total = sum(f["size"] for f in files)
print(f"{len(files)} files, {total/1048576:.1f} MB")
PY
# The blob is shipped gzipped (DecompressionStream("gzip") is universal in
# browsers; static hosts rarely compress binaries on the fly).
gzip -6 -f -k "$OUT/bundle.bin"
du -sh "$OUT"/* | sort -h | tail -8
