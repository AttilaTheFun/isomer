#!/usr/bin/env bash
# Launches the native Linux **wasm** cell via `bazel run`.
#
# Mirrors the compiled cell's run_linux.sh (LD_LIBRARY_PATH → the swift.org
# Swift runtime), and additionally resolves the `example_full.wasm` reactor from
# the runfiles tree and passes it as the first argument — this binary is a
# loader that runs those bytes under WAMR.
set -euo pipefail

# Locate this script's runfiles tree.
RUNFILES="${RUNFILES_DIR:-}"
if [ -z "${RUNFILES}" ]; then
  if [ -d "${0}.runfiles" ]; then
    RUNFILES="${0}.runfiles"
  elif [ -d "${BASH_SOURCE[0]}.runfiles" ]; then
    RUNFILES="${BASH_SOURCE[0]}.runfiles"
  fi
fi
RUNFILES="$(cd "${RUNFILES}" && pwd)"

REAL="${RUNFILES}/_main/examples/linux/example_full_opengl_wasm_linux_application/example_full_opengl_wasm_linux_application_bin"
# An explicit reactor path argument wins (benchmark cells run other reactors
# through this same loader); otherwise prefer the bundled native x86_64 .aot
# (release builds package it via reactor_artifact), else the interpreted .wasm.
# The loader dispatches on the reactor's magic header either way.
if [ "$#" -ge 1 ] && [ -e "${1}" ]; then
  WASM="${1}"
  shift
else
  REACTOR_DIR="${RUNFILES}/_main/examples/wasm/example_full_feature"
  WASM="${REACTOR_DIR}/example_full_x86.aot"
  if [ ! -e "${WASM}" ]; then
    WASM="${REACTOR_DIR}/example_full.wasm"
  fi
fi
if [ ! -e "${REAL}" ]; then
  echo "error: app binary not found at ${REAL}" >&2
  exit 1
fi
if [ ! -e "${WASM}" ]; then
  echo "error: wasm reactor not found at ${WASM}" >&2
  exit 1
fi

# The Swift runtime (.so files) lives next to the toolchain under the output
# base; find it once and expose it (see the compiled runner for the rationale).
real_resolved="$(readlink -f "${REAL}")"
output_base="${real_resolved%%/execroot/*}"
swift_core="$(find "${output_base}/external" -name libswiftCore.so 2>/dev/null | head -n1 || true)"
if [ -n "${swift_core}" ]; then
  swift_runtime="$(dirname "${swift_core}")"
  export LD_LIBRARY_PATH="${swift_runtime}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

# So the host resolves the bundled image assets from this runfiles tree.
export RUNFILES_DIR="${RUNFILES}"

exec "${REAL}" "${WASM}" "$@"
