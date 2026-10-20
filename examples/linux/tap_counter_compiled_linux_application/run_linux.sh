#!/usr/bin/env bash
# Launches the compiled tap-counter benchmark cell via `bazel run`: points
# LD_LIBRARY_PATH at the swift.org Swift runtime (whose runfiles-relative
# RUNPATH doesn't resolve under `bazel run`) and execs the real binary — the
# same wrapper shape as the full example app's runner.
set -euo pipefail

RUNFILES="${RUNFILES_DIR:-}"
if [ -z "${RUNFILES}" ]; then
  if [ -d "${0}.runfiles" ]; then
    RUNFILES="${0}.runfiles"
  elif [ -d "${BASH_SOURCE[0]}.runfiles" ]; then
    RUNFILES="${BASH_SOURCE[0]}.runfiles"
  fi
fi
RUNFILES="$(cd "${RUNFILES}" && pwd)"

REAL="${RUNFILES}/_main/examples/linux/tap_counter_compiled_linux_application/tap_counter_compiled_linux_application_bin"
if [ ! -e "${REAL}" ]; then
  echo "error: app binary not found at ${REAL}" >&2
  exit 1
fi

real_resolved="$(readlink -f "${REAL}")"
output_base="${real_resolved%%/execroot/*}"
swift_core="$(find "${output_base}/external" -name libswiftCore.so 2>/dev/null | head -n1 || true)"
if [ -n "${swift_core}" ]; then
  swift_runtime="$(dirname "${swift_core}")"
  export LD_LIBRARY_PATH="${swift_runtime}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

export RUNFILES_DIR="${RUNFILES}"

exec "${REAL}" "$@"
