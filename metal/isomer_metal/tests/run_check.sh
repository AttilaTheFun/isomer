#!/bin/bash
# Runs a check program built for wasm under WasmKit's WASI command runner
# (//tools/wasm/wasi_run); fails on any "FAIL" line or a missing "ok".
set -euo pipefail
runner="$1"
module="$2"
output="$("$runner" "$module" 2>&1)" || { echo "$output"; exit 1; }
echo "$output"
if grep -q "^FAIL" <<<"$output" || ! grep -q "^ok" <<<"$output"; then
  exit 1
fi
