// example_linux_wasm_application — the Linux "wasm mode" cell of the swift_ffi
// example matrix. The shared greeter (//examples/shared/greeter) is compiled to
// a WebAssembly reactor and run under WAMR with NO compiled Swift on the host;
// the generated c-host bindings drive it (see //examples/shared/greeter_wasm_host
// for the driver). The peer of the compiled cell
// (example_linux_compiled_application), which links the same greeter natively.
//
//   bazel run //examples/linux/example_linux_wasm_application
//
// Bazel passes the reactor path (args + data in the BUILD), so it runs with no
// manual arguments; pass a path explicitly to load a different reactor.
#include <stdio.h>

#include "run.h"

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <greeter_reactor.wasm>\n", argv[0]);
        return 2;
    }
    return run_greeter_reactor(argv[0], argv[1]);
}
