#!/usr/bin/env bash

# `bazel run //swift_ffi/examples/web/example_web_wasm_application`: opens the wasm example
# in a desktop window using the hermetically downloaded Electron (macOS/arm64).

set -euo pipefail

RUNFILES_ROOT="$PWD/.."
ELECTRON="$(cat "$RUNFILES_ROOT/$1")"
APP_DIR="$RUNFILES_ROOT/$(dirname "$2")"

# main.js serves this directory (index.html + app.js + greeter_web.wasm) over
# loopback HTTP; __dirname would resolve through the main.js symlink to the
# source tree, so the runfiles location is passed explicitly.
export GREETER_SITE_DIR="$APP_DIR"

exec "$ELECTRON" "$APP_DIR"
