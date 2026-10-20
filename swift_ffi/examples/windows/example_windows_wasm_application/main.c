// example_windows_wasm_application — the Windows "wasm mode" cell of the
// swift_ffi example matrix. The shared greeter (//examples/shared/greeter) runs
// as a WebAssembly reactor under WAMR with NO compiled Swift on the host; the
// generated c-host bindings drive it (see //examples/shared/greeter_wasm_host
// for the driver). The peer of the compiled cell
// (example_windows_compiled_application), which links the same greeter natively.
//
//   bazel run //examples/windows/example_windows_wasm_application
//
// The SwiftWasm cross-compile toolchain is only registered on Linux/macOS, so
// Windows can't build the reactor from source — a prebuilt greeter_reactor.wasm
// is committed next to this file and bundled as a data dep, and Bazel passes its
// path (args + data in the BUILD) so `bazel run` needs no arguments. Rebuild the
// bundle from //examples/shared/greeter:greeter_reactor.wasm under WSL/Linux.
#include <stdio.h>

#include "run.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <greeter_reactor.wasm>\n", argv[0]);
        return 2;
    }
    return run_greeter_reactor(argv[0], argv[1]);
}
