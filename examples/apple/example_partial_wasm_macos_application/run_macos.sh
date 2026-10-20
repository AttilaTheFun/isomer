#!/bin/bash
# One-command launcher: run the macOS host app connected to the hot-reload
# server. Mirrors the iOS package's `:run`. (macOS is simpler than iOS - no
# simulator to boot/install - so this just sets the server env and launches.)
#
# Usage (pairs with `:hot_reload_server` in another shell):
#   bazel run //apple/example_partial_wasm_macos_application:run
# Point at a non-default server with ISO_HOT_RELOAD_SERVER=... bazel run ...:run
set -euo pipefail

: "${BUILD_WORKSPACE_DIRECTORY:?run via 'bazel run', not directly}"
cd "$BUILD_WORKSPACE_DIRECTORY"

export ISO_HOT_RELOAD_SERVER="${ISO_HOT_RELOAD_SERVER:-http://localhost:8787}"
echo "==> Launching the macOS host, connected to $ISO_HOT_RELOAD_SERVER"
echo "    (start the server in another shell: bazel run //apple/example_partial_wasm_macos_application:hot_reload_server)"
exec bazel run //apple/example_partial_wasm_macos_application:example_partial_wasm_macos_application
