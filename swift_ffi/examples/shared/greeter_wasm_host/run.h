// Shared driver for the "wasm mode" example cells (Linux, Windows): load the
// greeter reactor, run it under WAMR with NO compiled Swift, exercise the
// c-host-representable surface, and print a report. The per-platform
// applications are a thin `main` that hands their reactor path to this.
#ifndef EXAMPLES_GREETER_WASM_HOST_RUN_H
#define EXAMPLES_GREETER_WASM_HOST_RUN_H

// `argv0` (the program's argv[0]) lets the reactor be located in the runfiles
// when `wasm_path` is a Bazel rootpath that doesn't open directly (Windows).
// Returns 0 if every greeter call returned the expected value, 1 on a runtime
// failure, 2 if the reactor file could not be read.
int run_greeter_reactor(const char *argv0, const char *wasm_path);

#endif  // EXAMPLES_GREETER_WASM_HOST_RUN_H
