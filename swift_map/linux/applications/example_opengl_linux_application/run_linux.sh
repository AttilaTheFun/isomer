#!/usr/bin/env bash
# Launches the native Linux SwiftMap example via `bazel run`.
#
# The swift.org toolchain links the Swift standard-library .so files with a
# runfiles-relative RUNPATH that doesn't resolve from `bazel run`'s working
# directory, so this thin wrapper points LD_LIBRARY_PATH at the Swift runtime
# (located under the Bazel output base) and execs the real binary — the same
# pattern as isomer's Linux target.
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

REAL="${RUNFILES}/_main/linux/applications/example_opengl_linux_application/example_opengl_linux_application_bin"
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

exec "${REAL}" "$@"
