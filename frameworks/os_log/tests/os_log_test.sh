#!/bin/bash
# Runs OSLogCheck.swift (built for wasm) under WasmKit and compares what the
# Logger wrote with what Apple's formats give.
set -euo pipefail
output="$("$1" "$2" 2>&1)"
echo "$output"
expected='[dev.isomer.check:oslog] info: count 42 hex 0xff ratio 0.50
[dev.isomer.check:oslog] error: name   app flag YES type Int
ok'
[ "$output" = "$expected" ] || { echo "FAIL: expected:"; echo "$expected"; exit 1; }
