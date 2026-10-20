// swift_ffi_wamr — the WAMR (WebAssembly Micro Runtime) binding for swift_ffi's
// "wasm mode". It lets a plain C host with NO compiled Swift load a swift_ffi
// module compiled to a wasm reactor, satisfy the reactor's `swift_ffi` foreign
// imports with native implementations, and call its exported functions — the
// engine that turns the generated `c-host-wasm` bindings into a running program.
//
// It is the concrete engine the generated C host (swift_ffi_host.h +
// <module>_c_host.h) leaves abstract: those emit a `SwiftFFIEngine` vtable and a
// foreign-import table; this supplies the vtable over a real WAMR instance and
// registers the imports as WAMR natives.
//
// Usage (one reactor):
//   SwiftFFIWamr *rt = swift_ffi_wamr_new(wasm, wasm_len);
//   <prefix>host *h = swift_ffi_<mod>_host_create(swift_ffi_wamr_engine(rt));
//   const SwiftFFIHostImport *imports;
//   size_t n = swift_ffi_<mod>_host_imports(h, &imports);
//   swift_ffi_wamr_bind_imports(rt, imports, n);
//   swift_ffi_wamr_instantiate(rt, err, sizeof err);   // runs _initialize
//   ... call swift_ffi_<mod>_<function>(h, ...) / install native impls ...
//   swift_ffi_<mod>_host_destroy(h);
//   swift_ffi_wamr_destroy(rt);
#ifndef SWIFT_FFI_WAMR_H
#define SWIFT_FFI_WAMR_H

#include <stddef.h>
#include <stdint.h>

#include "swift_ffi_host.h"  // SwiftFFIEngine, SwiftFFIHostImport, SwiftFFIScalar

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SwiftFFIWamr SwiftFFIWamr;

// Hold `wasm_len` bytes of a reactor (copied) and prepare a `SwiftFFIEngine`
// over the not-yet-instantiated WAMR instance. Returns NULL on allocation
// failure. The engine's calls only work once instantiated (below).
SwiftFFIWamr *swift_ffi_wamr_new(const uint8_t *wasm, size_t wasm_len);

// The `SwiftFFIEngine` (call an export, read/write the reactor's linear memory)
// to hand to the generated `swift_ffi_<mod>_host_create`. Valid for `rt`'s
// lifetime.
const SwiftFFIEngine *swift_ffi_wamr_engine(SwiftFFIWamr *rt);

// Register the generated foreign imports (from `swift_ffi_<mod>_host_imports`)
// as natives in the WAMR module "swift_ffi", so the reactor's foreign_* imports
// resolve at instantiation. Call once, BEFORE swift_ffi_wamr_instantiate.
// Returns non-zero on success.
int swift_ffi_wamr_bind_imports(SwiftFFIWamr *rt,
                                const SwiftFFIHostImport *imports, size_t count);

// Load + instantiate the reactor and run its `_initialize` (WASI reactor init).
// After this the engine works and exported functions are callable. Returns
// non-zero on success; on failure returns 0 and writes a message into `err`
// (when err != NULL).
int swift_ffi_wamr_instantiate(SwiftFFIWamr *rt, char *err, size_t err_len);

// Tear down the instance and free everything (safe on a partially-built rt).
void swift_ffi_wamr_destroy(SwiftFFIWamr *rt);

#ifdef __cplusplus
}
#endif

#endif  // SWIFT_FFI_WAMR_H
