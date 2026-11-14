#!/usr/bin/env bash
# Fills chot/ and resources/ for the iPhone benchmark from tools/mixed's
# outputs (tools/mixed/README.md, "The 2048 drag benchmark"):
#
#   prepare.sh <round dir> <reactor.wasm> <runtime.wasm> <runtime_named.wasm> \
#              <game2048 side.wasm> <routed.txt>
#
#   <round dir>          tools/mixed/split/round.sh's WORK/round (its c/ has
#                        the generated C, shim.wasm; slots.txt beside it)
#   <reactor.wasm>       //wasm/game2048_feature:game2048_release.wasm
#   <runtime.wasm>       split_link.py's runtime, stripped (--strip)
#   <runtime_named.wasm> the runtime the round split (not stripped)
#   <side.wasm>          split_link.py's side module of game2048_lib
#   <routed.txt>         the routed list the round used
# The C is tools/mixed/host/Sources/CHot, which round.sh also fills.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROUND=$1
CHOT=$(cd "$HERE/../../../../tools/mixed/host/Sources/CHot" && pwd)
rm -rf "$HERE/chot" "$HERE/resources"
mkdir -p "$HERE/chot/include" "$HERE/resources"
cp "$CHOT"/*.c "$CHOT"/*.h "$CHOT"/*.inc "$HERE/chot/"
cp "$CHOT"/include/*.h "$HERE/chot/include/"
cp "$2" "$HERE/resources/game2048_release.wasm"
cp "$3" "$HERE/resources/runtime.wasm"
cp "$4" "$HERE/resources/runtime_named.wasm"
cp "$5" "$HERE/resources/game2048_side.wasm"
cp "$ROUND/c/shim.wasm" "$HERE/resources/shim.wasm"
cp "$ROUND/slots.txt" "$HERE/resources/slots.txt"
cp "$6" "$HERE/resources/routed.txt"
chmod -R u+w "$HERE/chot" "$HERE/resources"
echo "chot/ and resources/ filled"
