// Weak stand-in for the one wasm-c-api symbol WAMR core references even with
// wasm_c_api.c excluded from @wamr (see MODULE.bazel): the reference sits in
// wasm_runtime_invoke_c_api_native, which is unreachable when no c-api
// natives are registered (all hosts here register wasm_runtime_* natives).
// Weak, so a real engine exporting the spec API, linked into the same
// binary, wins at link time.
struct wasm_trap_t;

#if defined(_MSC_VER)
void wasm_trap_delete(struct wasm_trap_t *trap) { (void)trap; }
#else
__attribute__((weak)) void wasm_trap_delete(struct wasm_trap_t *trap) { (void)trap; }
#endif
