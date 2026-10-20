// Shared driver for the "compiled mode" example cells (Linux, Windows): call the
// greeter over its generated native C ABI (no interpreter), exercise the same
// surface the wasm cells do, and print a report. The per-platform applications
// are a thin `main` over this.
#ifndef EXAMPLES_GREETER_COMPILED_HOST_RUN_H
#define EXAMPLES_GREETER_COMPILED_HOST_RUN_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns 0 if every greeter call returned the expected value, 1 otherwise.
int run_greeter_compiled(void);

#ifdef __cplusplus
}
#endif

#endif  // EXAMPLES_GREETER_COMPILED_HOST_RUN_H
