#!/usr/bin/env bash
# Launches the native Linux app via `bazel run`.
#
# The swift.org toolchain links the Swift standard-library .so files with a
# runfiles-relative RUNPATH that doesn't resolve from `bazel run`'s working
# directory, so this thin wrapper points LD_LIBRARY_PATH at the Swift runtime
# (located under the Bazel output base) and execs the real binary. It mirrors
# how the Android/wasm example targets wrap their real build in a runner.
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

REAL="${RUNFILES}/_main/examples/linux/storybook_linux_application/storybook_linux_application_bin"
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

# So the app resolves its bundled image assets from this runfiles tree.
export RUNFILES_DIR="${RUNFILES}"

exec "${REAL}" "$@"
