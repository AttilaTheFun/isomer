// Mixed mode's C interface (docs/side_modules.md): what the native part
// (wasm2c's copies of a runtime module's hot functions and the bridge
// tools/wasm_mixed generates for them, linked into the app by
// tools/wasm/mixed.bzl's wasm_mixed_native) gives MixedWasmKitRuntime, and
// the callbacks the runtime gives it (`@_cdecl` in MixedBridge.swift).
// wasm2c's memory type is opaque here: the Swift side only passes it back.
#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The native part's signatures ("ii:i": parameters, a colon, results; i, I,
// f, F for i32, i64, f32, f64), imports, exports and globals.
extern const uint32_t iso_mixed_sig_count;
extern const uint32_t iso_mixed_import_count;
extern const uint32_t iso_mixed_export_count;
const char *iso_mixed_sig(uint32_t index);
const char *iso_mixed_import_module(uint32_t index);
const char *iso_mixed_import_name(uint32_t index);
uint32_t iso_mixed_import_sig(uint32_t index);
const char *iso_mixed_export_name(uint32_t index);
uint32_t iso_mixed_export_sig(uint32_t index);

void iso_mixed_instantiate(void);
// Calls export `index` with raw slots; one result slot.
void iso_mixed_call_export(uint32_t index, const uint64_t *args, uint64_t *results);
uint32_t *iso_mixed_stack_pointer(void);
uint32_t iso_mixed_table_size(void);
void iso_mixed_table_grow(uint32_t size);
// The signature of the native function in table `slot`, or -1 for none.
int32_t iso_mixed_table_native_sig(uint32_t slot);
// Table `slot` calls the interpreter's function there (iso_mixed_slot_call).
void iso_mixed_table_set_interpreted(uint32_t slot, uint32_t sig);
void *iso_mixed_memory(void);
void iso_mixed_memory_sync(void *memory);
// 1 if the native part checks its memory accesses itself (built with
// bounds checks); 0 if it relies on the engine's guard pages.
int32_t iso_mixed_checks_bounds(void);

#ifdef __cplusplus
}
#endif
