#!/usr/bin/env bash
# Runs the Isomer app on this Linux desktop (`bazel run`): the swift.org
# toolchain links the Swift runtime with a runfiles-relative RUNPATH that
# doesn't resolve from here, so LD_LIBRARY_PATH names it, and RUNFILES_DIR
# tells the app where its files (the Gallery's images and reactor, the
# loader) are.
set -euo pipefail
RUNFILES="${RUNFILES_DIR:-${0}.runfiles}"
RUNFILES="$(cd "${RUNFILES}" && pwd)"
REAL="${RUNFILES}/_main/linux/isomer_linux_application/isomer_linux_application_bin"
output_base="$(readlink -f "${REAL}")"
output_base="${output_base%%/execroot/*}"
swift_core="$(find "${output_base}/external" -name libswiftCore.so 2>/dev/null | head -n1 || true)"
if [ -n "${swift_core}" ]; then
  export LD_LIBRARY_PATH="$(dirname "${swift_core}")${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
fi
export RUNFILES_DIR="${RUNFILES}"
exec "${REAL}" "$@"
