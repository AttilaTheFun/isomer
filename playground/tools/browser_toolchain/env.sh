# Shared environment for the browser toolchain phases.
export ISO_WORKSPACE="${ISO_WORKSPACE:-$HOME/Developer/ios-toolchain}"   # swift/llvm-project/... worktrees @ swift-6.3.2-RELEASE
export ISO_BASE_TC="${ISO_BASE_TC:-$HOME/Developer/swiftwasm-source/build/Packaging/base-toolchain/swift-6.3.2-RELEASE/usr/bin}"
# The SwiftWasm SDK's wasm32-unknown-wasip1 slice: by default the one Bazel
# fetched for this module (`bazel build //apple/playground_ios_application:playground_sdk`
# from playground/ fetches it), found under its output base.
if [ -z "${ISO_WASM_SDK:-}" ]; then
    _iso_output_base="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && bazel info output_base 2>/dev/null)"
    export ISO_WASM_SDK="$_iso_output_base/external/rules_swift++swift+swift_toolchain_wasm_sdk_xcode/swift-6.3.2-RELEASE_wasm.artifactbundle/swift-6.3.2-RELEASE_wasm/wasm32-unknown-wasip1"
fi
NINJA=$HOME/Developer/swiftwasm-source/ninja/ninja
[ -x "$NINJA" ] || NINJA=$(command -v ninja)
export NINJA
export JOBS="${JOBS:-8}"
# Link-time extras every wasm executable needs (see wasi-toolchain.cmake).
export ISO_WASI_LINK_EXTRA="$ISO_WORKSPACE/build/wasi-stubs/wasi_stubs.o $ISO_WORKSPACE/build/wasi-cxxthreads/libiso_cxxthreads.a"
