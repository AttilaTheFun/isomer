#!/usr/bin/env bash
# Launches the native Linux compiled cell via `bazel run`.
#
# The swift.org toolchain links the Swift standard-library .so files with a
# runfiles-relative RUNPATH that doesn't resolve from `bazel run`'s working
# directory, so this thin wrapper points LD_LIBRARY_PATH at the Swift runtime
# (under the Bazel output base) and execs the real binary. The wasm cell needs
# no such wrapper: it has no compiled Swift, so no Swift runtime to find.
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

REAL="${RUNFILES}/_main/examples/linux/example_linux_compiled_application/example_linux_compiled_application_bin"
if [ ! -e "${REAL}" ]; then
  echo "error: app binary not found at ${REAL}" >&2
  exit 1
fi

# The Swift runtime (.so files) lives next to the toolchain under the output
# base; find it once and expose it. `readlink -f` resolves the runfiles symlink
# to the real path in the Bazel cache (.../<output_base>/execroot/_main/...).
real_resolved="$(readlink -f "${REAL}")"
output_base="${real_resolved%%/execroot/*}"
swift_core="$(find "${output_base}/external" -name libswiftCore.so 2>/dev/null | head -n1 || true)"
if [ -n "${swift_core}" ]; then
  swift_runtime="$(dirname "${swift_core}")"
  export LD_LIBRARY_PATH="${swift_runtime}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi

exec "${REAL}" "$@"
