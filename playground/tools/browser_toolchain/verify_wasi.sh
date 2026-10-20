#!/bin/bash
# Definition of done for Phase 0: the wasm-hosted frontend compiles a hello
# world to an object, the wasm-hosted lld links it against the SDK, and the
# result runs — all as WASI commands, outside any browser. Flags mirror
# `swiftc -driver-print-jobs` / `clang -###` for the same job natively (do not
# guess flags).
#
# WASI_RUN is the command that runs a WASI module, taking `--dir=<path>`
# preopens before it: by default Isomer's `iwasm` (WAMR;
# `bazel build @isomer//tools/wasm/wasi_command:iwasm` from playground/, and
# `--define wamr_aot=1` with a wamrc-compiled module to run it at native
# speed: interpreted, a 100 MB compiler is slow), or any standalone WASI
# runtime's equivalent.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/env.sh"
read -r -a RUN <<< "${WASI_RUN:-iwasm}"
FRONTEND="${1:-$ISO_WORKSPACE/build/wasi-swift/bin/swift-frontend}"
LLD="${2:-$ISO_WORKSPACE/build/wasi-llvm/bin/lld}"
W="$ISO_WORKSPACE/build/browser-work"
SDK="$ISO_WASM_SDK"
STATIC="$SDK/swift.xctoolchain/usr/lib/swift_static"
mkdir -p "$W"
printf 'print("hello from swift compiled in wasm")\n' > "$W/main.swift"
rm -f "$W/main.o" "$W/main.wasm"
# The clang module cache must live inside a preopened dir (the driver's
# default per-user cache path does not exist in the sandbox).
mkdir -p "$W/module-cache"
echo "== frontend (${RUN[0]})"
/usr/bin/time -l "${RUN[@]}" --dir="$SDK" --dir="$W" "$FRONTEND" \
    -frontend -c -primary-file "$W/main.swift" -target wasm32-unknown-wasip1 \
    -disable-objc-interop -sdk "$SDK/WASI.sdk" -no-color-diagnostics -Xcc -fno-color-diagnostics \
    -Onone -empty-abi-descriptor -resource-dir "$STATIC" -use-static-resource-dir \
    -no-auto-bridging-header-chaining -module-name main -module-cache-path "$W/module-cache" -o "$W/main.o" 2>&1 | grep -vE "^\s+[0-9]+  (page|voluntary|involuntary|signals|messages|block|swap|instructions|cycles|peak)" || true
ls -la "$W/main.o"
echo "== wasm-ld (${RUN[0]})"
/usr/bin/time -l "${RUN[@]}" --dir="$SDK" --dir="$W" "$LLD" -flavor wasm -m wasm32 \
    -L"$STATIC/wasi" -L"$SDK/WASI.sdk/lib/wasm32-wasip1" \
    "$SDK/WASI.sdk/lib/wasm32-wasip1/crt1-command.o" "$STATIC/wasi/wasm32/swiftrt.o" "$W/main.o" \
    -lswiftSwiftOnoneSupport -lswiftCore -lswift_Concurrency -lswift_StringProcessing -lswift_RegexParser \
    -lswiftSwiftOnoneSupport -ldl -lc++ -lc++abi -lm -lwasi-emulated-mman -lwasi-emulated-signal \
    -lwasi-emulated-process-clocks --error-limit=0 --threads=1 --global-base=4096 --table-base=4096 \
    -z stack-size=131072 -lc "$STATIC/clang/lib/wasip1/libclang_rt.builtins-wasm32.a" \
    -o "$W/main.wasm" --keep-section=target_features 2>&1 | grep -E "error|real|maximum resident" || true
ls -la "$W/main.wasm"
echo "== run"
"${RUN[@]}" "$W/main.wasm"
