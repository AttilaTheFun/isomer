// example_windows_compiled_application — the Windows "compiled mode" cell of the
// swift_ffi example matrix. The shared greeter (//examples/shared/greeter) is
// compiled to native code and linked straight into this program; calls go over
// the generated `swift_ffi_greeter_*` C ABI with no interpreter (the driver
// lives in //examples/shared/greeter_compiled_host). The peer of the wasm cell
// (example_windows_wasm_application), which runs the same greeter under WAMR.
//
//   bazel run //examples/windows/example_windows_compiled_application
#include "run.h"

int main(void) {
    return run_greeter_compiled();
}
