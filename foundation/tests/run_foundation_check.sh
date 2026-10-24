#!/bin/bash
# Runs Isomer's Foundation check (FoundationCheck.swift, built for wasm) under
# WasmKit's WASI command runner (//tools/wasm/wasi_run); fails on any "FAIL"
# line or a missing "ok".
set -euo pipefail
runner="$1"
module="$2"
shift 2
# What follows: the runner's --env= options, and the guest's own arguments.
options=()
arguments=()
for argument in "$@"; do
  case "$argument" in
    --env=*) options+=("$argument") ;;
    *) arguments+=("$argument") ;;
  esac
done
# The test's own temporary directory as the guest's /tmp (swift-foundation's
# temporary directory on WASI).
tmp="${TEST_TMPDIR:-$(mktemp -d)}"
output="$("$runner" --map-dir=/tmp::"$tmp" ${options[@]+"${options[@]}"} "$module" ${arguments[@]+"${arguments[@]}"} 2>&1)" || { echo "$output"; exit 1; }
echo "$output"
if grep -q "^FAIL" <<<"$output" || ! grep -q "^ok" <<<"$output"; then
  exit 1
fi
