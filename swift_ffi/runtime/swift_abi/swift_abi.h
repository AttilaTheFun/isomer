/* bridge_ffi — the common C ABI vocabulary shared by every swift_ffi bridge.
 *
 * Every generated C header includes this file; the `SwiftFFI` module imports
 * it as the clang module `SwiftABI`; the generated C++ layer and the JNI
 * adapter build on it. It defines what is genuinely shared between all
 * bridges: the erased value *wire encoding* (tags + blob format), the buffer
 * pair, the closure vtable native consumers implement, the shared allocator,
 * and the fixed-name runtime entry points the `SwiftFFI` module exports once
 * per linked image. See docs/abi.md.
 *
 * THE ERASED WIRE ENCODING ("blob"). Wherever a statically-typed ABI is
 * impossible — generic positions, container values (Result/Array/Dictionary),
 * struct copies, interface method arguments, closure arguments, Lazy
 * payloads — a value crosses as a self-contained, little-endian byte blob:
 *
 *     i32 tag, i32 aux, then per tag:
 *       VOID                 (nothing)
 *       INT / BOOL           i64 (bool 0/1)
 *       INT32                i64 (widened)
 *       DOUBLE               f64 bits
 *       STRING/BYTES/ERROR   i64 byte length, then the bytes
 *       STRUCT               aux = the struct NAME's byte length; the name's
 *                            UTF-8 bytes; i64 field count; then each field's
 *                            blob in declaration order
 *       LIST                 i64 element count, then each element's blob —
 *                            the general ordered composite generic container
 *                            conformances encode through (Result crosses as
 *                            [isError, payload], Array as its elements,
 *                            Dictionary as alternating key/value)
 *       HANDLE               aux = the interface NAME's byte length; the
 *                            name's UTF-8 bytes; i64 = a +1 Swift box handle
 *
 * Closures never appear inside blobs (they are direct parameters). Types are
 * identified on the wire BY NAME (self-describing) — there are no
 * generation-time ordinal tables.
 *
 * Blobs travel like strings do: (pointer, length) borrowed for the call on
 * the way in; a +1 box handle (drained with `swift_ffi_string_len` /
 * `swift_ffi_string_copy` / `swift_ffi_string_release`) on the way out.
 */

#ifndef SWIFT_FFI_BRIDGE_FFI_H
#define SWIFT_FFI_BRIDGE_FFI_H

#include <stdint.h>
#include <stdlib.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The dynamic type of an erased value (the blob's leading i32). */
typedef enum bridge_tag {
    BRIDGE_TAG_VOID = 0,
    BRIDGE_TAG_INT = 1,
    BRIDGE_TAG_INT32 = 2,
    BRIDGE_TAG_DOUBLE = 3,
    BRIDGE_TAG_BOOL = 4,
    BRIDGE_TAG_STRING = 5,
    BRIDGE_TAG_BYTES = 6,
    BRIDGE_TAG_STRUCT = 7,
    BRIDGE_TAG_LIST = 8,
    BRIDGE_TAG_HANDLE = 9,
    BRIDGE_TAG_ERROR = 10,
    BRIDGE_TAG_FOREIGN = 11,
} bridge_tag;

/* An owned byte buffer handed across the closure vtable: allocated by the
 * callee with bridge_alloc, freed by the caller with bridge_free. */
typedef struct bridge_buf {
    void *ptr;
    int64_t len;
} bridge_buf;

/* A consumer-implemented closure crossing into Swift on native platforms: a
 * vtable of one. `invoke` receives the arguments as one concatenated blob
 * sequence (arity is static in the bridged signature) and either writes the
 * result blob into `*result_out` or an ERROR blob into `*error_out` (both
 * bridge_alloc'd; the Swift side frees them). The Swift side retains the
 * closure while an escaping capture holds it and releases exactly once.
 * On wasm, closures travel as foreign-registry ids instead — function
 * pointers do not cross the boundary. */
typedef struct bridge_closure {
    void *ctx;
    void (*invoke)(void *ctx, const void *args, int64_t args_len,
                   bridge_buf *result_out, bridge_buf *error_out);
    void (*retain)(void *ctx);
    void (*release)(void *ctx);
} bridge_closure;

/* The shared allocator for native-side blob/buffer exchange (writer
 * allocates, reader frees). Header-only (the library ships no objects, so
 * reactors compiling it for wasm need no cc toolchain support). On wasm,
 * buffers crossing into a reactor live in wasm memory and use the reactor's
 * exported `swift_ffi_alloc` instead. */
static inline void *bridge_alloc(int64_t byte_count) {
    return malloc(byte_count > 0 ? (size_t)byte_count : 1);
}

static inline void bridge_free(void *pointer) {
    free(pointer);
}

/* --- Fixed-name runtime entry points ------------------------------------- */
/* Exported once per linked image by the `SwiftFFI` module (there are no
 * per-module copies): staging buffers, byte boxes, and Lazy handles. String-,
 * byte- and blob-typed returns are +1 box handles: copy the bytes out
 * (string_len/string_copy), then release. */

void *swift_ffi_alloc(int32_t byte_count);
void swift_ffi_dealloc(void *pointer);
int32_t swift_ffi_string_len(void *handle);
void swift_ffi_string_copy(void *handle, void *dest);
void swift_ffi_string_release(void *handle);

/* Lazy handles: `lazy_get` computes (once) and returns a +1 blob box;
 * release the handle exactly once when done. */
void *swift_ffi_lazy_get(void *handle);
void swift_ffi_lazy_release(void *handle);

#if defined(__wasm32__)

/* --- The reactor's host imports (wasm module "swift_ffi") ----------------- */
/* Fixed names, declared here with import attributes so the `SwiftFFI` module
 * calls them through C interop (no compiler-experimental import syntax).
 * Reactors link with --no-gc-sections, so every host must bind all five
 * (stub the ones it does not use).
 *
 *   closure_invoke   runs one consumer closure / foreign-object method call:
 *                    `args` is a borrowed blob sequence (foreign-object calls
 *                    lead with an .int32 method ordinal); returns the result
 *                    blob packed as (len << 32) | ptr, bytes allocated with
 *                    swift_ffi_alloc, ownership transferred to the guest —
 *                    or an ERROR blob through the same channel.
 *   foreign_release  drops one entry from the host's foreign registry.
 *   dependency_get   resolves a guest dependency key: 0 when absent, else a
 *                    packed (len << 32) | ptr blob (+1, swift_ffi_alloc'd) of
 *                    .list([.bool(lazy), .string(registry key), .int32(id)]).
 *   task_enqueue     schedules a Swift concurrency job; the host queues a
 *                    microtask that calls the `swift_ffi_task_run` export.
 *   task_enqueue_after  the same, not before `delay_ms` milliseconds have
 *                    passed: `Task.sleep` and every other timed wait. The
 *                    host runs the job through `swift_ffi_task_run` once the
 *                    delay is up (a timer, or its drain once due).
 *   async_complete   delivers an async export's completion: the borrowed
 *                    blob is the result value — or an ERROR blob. */

#define SWIFT_FFI_WASM_IMPORT(name)                                        \
    __attribute__((import_module("swift_ffi"), import_name(#name)))

SWIFT_FFI_WASM_IMPORT(closure_invoke)
uint64_t swift_ffi_wasm_closure_invoke(int32_t id, const void *args,
                                       int32_t args_len);
SWIFT_FFI_WASM_IMPORT(foreign_release)
void swift_ffi_wasm_foreign_release(int32_t id);
SWIFT_FFI_WASM_IMPORT(dependency_get)
uint64_t swift_ffi_wasm_dependency_get(const void *key, int32_t key_len);
SWIFT_FFI_WASM_IMPORT(task_enqueue)
void swift_ffi_wasm_task_enqueue(void *job);
SWIFT_FFI_WASM_IMPORT(task_enqueue_after)
void swift_ffi_wasm_task_enqueue_after(void *job, int32_t delay_ms);
SWIFT_FFI_WASM_IMPORT(async_complete)
void swift_ffi_wasm_async_complete(int32_t call_id, const void *blob,
                                   int32_t blob_len);

/* Runs one enqueued Swift concurrency job (the export the host's microtask
 * calls back into). Exported by the `SwiftFFI` module. */
void swift_ffi_task_run(void *job);

#endif /* __wasm32__ */

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* SWIFT_FFI_BRIDGE_FFI_H */
