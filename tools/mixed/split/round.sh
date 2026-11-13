#!/usr/bin/env bash
# One round of the mixed-mode build: a native set in, a measured run out.
#
#   round.sh <native set>
#
# Splits the runtime on the set (Binaryen's wasm-split: the set as the
# "primary" part, everything else "secondary"), slims the primary part (no
# data, only the host's entry points and the ROUTED functions exported),
# maps the table slots the split added back to the runtime's functions,
# compiles the part to C (WABT's wasm2c), generates the bridge
# (gen_mixed.py), builds the host (../host, its MixedCheck product) and runs
# it: once to time it and compare its frames with BASELINE, once counting
# crossings (crossings.txt, for grow_set.py).
#
# Environment (all paths absolute):
#   RUNTIME     the runtime module, with a name section (link it without
#               --strip-all), interpreted whole by the host
#   SPLIT_INPUT the same module with only the entry points (and the ROUTED
#               functions) exported: wasm-split keeps every exported function
#               in the primary part. slim_native.py makes it from RUNTIME.
#   SIDE        the feature, a side module (wasm-ld -shared, the patched lld)
#   BASELINE    the render stream the self-contained build writes, to compare
#   ROUTED      runtime functions features call natively (pick_routed.py);
#               optional
#   WORK        a scratch directory (default /tmp/isomer-mixed)
# wasm-split, wasm2c and wat2wasm come from nix (nixpkgs#binaryen, #wabt).
set -euo pipefail
SET=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
HERE=$(cd "$(dirname "$0")" && pwd)
HOST=$(cd "$HERE/../host" && pwd)
WORK=${WORK:-/tmp/isomer-mixed}
ROUTED=${ROUTED:-}
ENTRIES=memory,__indirect_function_table,__stack_pointer,iso_hot_start,iso_hot_render,iso_hot_render_pending,iso_hot_event,iso_hot_resize,iso_hot_alloc,iso_hot_free,iso_hot_shutdown,iso_hot_pending_tasks,iso_hot_configure,iso_hot_set_color_scheme
KEEP=$ENTRIES${ROUTED:+,@$ROUTED}

R=$WORK/round
rm -rf "$R" && mkdir -p "$R/c" && cd "$R"
nix shell nixpkgs#binaryen --command wasm-split --split --no-placeholders --symbolmap \
  --keep-funcs=@"$SET" -o1 hot_full.wasm -o2 cold.wasm "$SPLIT_INPUT" 2>&1 | grep -v "does not exist" | tail -2 || true
python3 "$HERE/slim_native.py" hot_full.wasm hot.wasm "$KEEP"
node "$HERE/../node/sections.js" hot.wasm
python3 "$HERE/map_slots.py" "$RUNTIME" cold.wasm cold.wasm.symbols hot_full.wasm hot_full.wasm.symbols slots.txt

cd c
nix shell nixpkgs#wabt --command wasm2c --num-outputs=8 ../hot.wasm -o hot.c
python3 "$HERE/gen_mixed.py" ../hot.wasm hot.h .
nix shell nixpkgs#wabt --command wat2wasm shim.wat -o shim.wasm

# The host's C target: the generated module and bridge, and WABT's runtime
# (without its memory implementation: the bridge's is over WasmKit's memory).
WABT=$(nix shell nixpkgs#wabt --command sh -c 'dirname $(dirname $(command -v wasm2c))')
D=$HOST/Sources/CHot
rm -rf "$D" && mkdir -p "$D/include"
cp hot_*.c hot.h hot-impl.h mixed_glue.c "$D/"
cp mixed_glue.h "$WABT/include/wasm-rt.h" "$WABT/include/wasm-rt-exceptions.h" "$D/include/"
cp "$WABT/share/wabt/wasm2c/"{wasm-rt-impl.c,wasm-rt-impl.h,wasm-rt-impl-tableops.inc,wasm-rt-exceptions-impl.c} "$D/"
chmod -R u+w "$D"

cd "$HOST" && swift build -c release --product MixedCheck 2>&1 | grep -E "error|Build complete"
cd "$R"
rm -f round.bin
ROUTED=$ROUTED "$HOST/.build/release/MixedCheck" round.bin "$RUNTIME" "$R/c/shim.wasm" "$R/slots.txt" "$SIDE" 2>&1 | tail -2
cmp "$BASELINE" round.bin && echo BYTE-IDENTICAL
ROUTED=$ROUTED COUNT=1 "$HOST/.build/release/MixedCheck" /dev/null "$RUNTIME" "$R/c/shim.wasm" "$R/slots.txt" "$SIDE" 2>&1 | grep " slot " > "$R/crossings.txt" || true
