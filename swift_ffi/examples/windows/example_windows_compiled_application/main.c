// example_windows_compiled_application — the Windows "compiled mode" cell of the
// swift_ffi example matrix. The shared greeter (//examples/shared/greeter) is
// compiled to native code and linked straight into this program; calls go over
// the generated `swift_ffi_greeter_*` C ABI with no interpreter (the driver
// lives in //examples/shared/greeter_compiled_host). (Its wasm peer, which ran
// the same greeter under WAMR from C, went with WAMR in 0.38.)
//
//   bazel run //examples/windows/example_windows_compiled_application
#include "run.h"

int main(void) {
    return run_greeter_compiled();
}
