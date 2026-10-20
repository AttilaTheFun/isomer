#!/usr/bin/env bash
# Runs the snapshot checker (a swift_binary) as a bazel test, so the test
# doesn't depend on XCTest (whose dylib is awkward to load on a hermetic macOS
# host). The binary exits non-zero on any golden mismatch.
set -euo pipefail

BIN="${TEST_SRCDIR}/${TEST_WORKSPACE}/tests/snapshot/snapshot_check"

# On a Linux host the swift.org toolchain links the Swift stdlib .so files with a
# runfiles-relative RUNPATH that doesn't resolve under `bazel test`, so point
# LD_LIBRARY_PATH at the Swift runtime under the Bazel output base (a no-op on
# macOS, where the runtime resolves through the toolchain's rpath).
if [ "$(uname -s)" = "Linux" ]; then
  real="$(readlink -f "${BIN}")"
  output_base="${real%%/execroot/*}"
  swift_core="$(find "${output_base}/external" -name libswiftCore.so 2>/dev/null | head -n1 || true)"
  if [ -n "${swift_core}" ]; then
    export LD_LIBRARY_PATH="$(dirname "${swift_core}")${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  fi
fi

exec "${BIN}"
