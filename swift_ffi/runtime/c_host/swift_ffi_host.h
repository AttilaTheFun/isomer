// swift_ffi_host — the C half of the native host transport, the fourth peer of
// swift_ffi/runtime/{ts,swift,swift_wasm_host,kotlin}. It lets a plain C host
// (e.g. an app driving a WebAssembly engine like WAMR with NO compiled Swift)
// satisfy a swift_ffi reactor's `swift_ffi` foreign-interface imports with native C
// implementations — the C analogue of SwiftFFIWasmHost.swift.
//
// Like the Swift peer, it is engine-agnostic: the concrete WebAssembly engine
// is injected as a `SwiftFFIEngine` vtable (call an export, read/write the
// reactor's linear memory), so this runtime has no wasm dependency. The
// generated `c-host-wasm` bindings build the per-interface dispatch on top.
//
// Scope note: unlike the Swift runtime this C peer covers the *synchronous*
// foreign-dispatch subset (register a native impl, read its string/scalar
// arguments out of guest memory, return a scalar). Async pump and packed
// @ExportedStruct buffers are out of scope for this kind: the generator rejects
// them for `c-host-wasm`.

#ifndef SWIFT_FFI_HOST_H
#define SWIFT_FFI_HOST_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A single WebAssembly scalar slot crossing the engine boundary (the C peer of
// SwiftFFIScalar). Buffers/strings are marshalled as (i32 ptr, i32 len) pairs.
typedef enum {
    SWIFT_FFI_I32,
    SWIFT_FFI_I64,
    SWIFT_FFI_F32,
    SWIFT_FFI_F64,
} SwiftFFIScalarKind;

typedef struct {
    SwiftFFIScalarKind kind;
    union {
        int32_t i32;
        int64_t i64;
        float f32;
        double f64;
    } value;
} SwiftFFIScalar;

static inline SwiftFFIScalar swift_ffi_i32(int32_t v) {
    SwiftFFIScalar s;
    s.kind = SWIFT_FFI_I32;
    s.value.i32 = v;
    return s;
}
static inline uint32_t swift_ffi_scalar_u32(SwiftFFIScalar s) {
    switch (s.kind) {
        case SWIFT_FFI_I32: return (uint32_t)s.value.i32;
        case SWIFT_FFI_I64: return (uint32_t)s.value.i64;
        case SWIFT_FFI_F32: return (uint32_t)(int32_t)s.value.f32;
        case SWIFT_FFI_F64: return (uint32_t)(int32_t)s.value.f64;
    }
    return 0;
}

// The concrete WebAssembly engine, injected by the host. `call` invokes an
// export by full name (out receives its single result slot; has_result is 0 for
// Void). read/write copy the reactor's linear memory. Instantiation and binding
// of the import handlers is owned by the host (the generated import table below
// is what it binds), so — unlike the Swift peer — this vtable has no
// `instantiate`.
typedef struct {
    void *ctx;
    int (*call)(void *ctx, const char *name, const SwiftFFIScalar *args,
                size_t nargs, SwiftFFIScalar *out, int *has_result);
    void (*read_bytes)(void *ctx, uint32_t ptr, uint32_t len, uint8_t *dst);
    void (*write_bytes)(void *ctx, uint32_t ptr, const uint8_t *src, uint32_t len);
} SwiftFFIEngine;

typedef struct SwiftFFIHostRuntime SwiftFFIHostRuntime;

/* --- The erased wire encoding ("blob"; see swift_abi.h) ------------------ */
/* Closure / foreign-object / dependency dispatch carries blob-encoded
 * arguments and returns blob-encoded results. */

typedef struct {
    const uint8_t *data;
    size_t len;
    size_t off;
} SwiftFFIBlobReader;

typedef struct {
    uint8_t *data;
    size_t len;
    size_t cap;
} SwiftFFIBlobWriter;

// One `swift_ffi`-module import the host binds before instantiation: the full
// symbol name and the C handler the guest's foreign proxy calls out to. The
// handler reads the engine's declared argument slots positionally from the
// front (trailing Swift calling-convention context slots are ignored) and, for
// a non-Void method, writes the result slot to *out. `user` is the generated
// dispatcher's context (the runtime pointer).
typedef struct {
    const char *name;
    void (*handler)(void *user, const SwiftFFIScalar *args, size_t nargs,
                    SwiftFFIScalar *out, int *has_result);
    void *user;
} SwiftFFIHostImport;

// Create/destroy a runtime for one loaded reactor. Export names are full
// symbols (`swift_ffi_[<ns>_]<name>`; the runtime entry points are the fixed
// `swift_ffi_*` set — see swift_abi.h). Drive one runtime from a single
// thread (the registry and call path are unsynchronized).
SwiftFFIHostRuntime *swift_ffi_host_create(const SwiftFFIEngine *engine);
void swift_ffi_host_destroy(SwiftFFIHostRuntime *rt);

// Raw export call by FULL name. Returns 1 if a result slot was produced
// (written to *out), 0 for Void.
int swift_ffi_host_call(SwiftFFIHostRuntime *rt, const char *name,
                        const SwiftFFIScalar *args, size_t nargs,
                        SwiftFFIScalar *out);

// String/byte staging into the guest's linear memory via swift_ffi_alloc.
// Returns the guest pointer; *out_len receives the byte length. Free with
// dealloc.
uint32_t swift_ffi_host_alloc(SwiftFFIHostRuntime *rt, size_t count);
void swift_ffi_host_dealloc(SwiftFFIHostRuntime *rt, uint32_t ptr);
uint32_t swift_ffi_host_stage_bytes(SwiftFFIHostRuntime *rt, const uint8_t *bytes,
                                    size_t len, uint32_t *out_len);

// Reads a (ptr,len) UTF-8 buffer arriving from a foreign call into a fresh
// NUL-terminated C string (malloc'd; caller frees). *out_len (nullable) gets the
// byte length (excluding the NUL).
char *swift_ffi_host_foreign_string(SwiftFFIHostRuntime *rt, uint32_t ptr,
                                    uint32_t len, size_t *out_len);

// Copies out and releases a +1 string box handle returned by a String-returning
// export, via the fixed `swift_ffi_string_len` / `_copy` / `_release`
// exports. Returns a fresh NUL-terminated C string (malloc'd; caller frees);
// a 0 handle yields "". The C peer of the Swift host's `takeString`.
char *swift_ffi_host_take_string(SwiftFFIHostRuntime *rt, uint32_t handle);

// Foreign registry: closures, foreign objects, and injected dependencies all
// cross the ONE `closure_invoke` channel as ordinal-led blob DISPATCHERS.
// Park (ctx, dispatch) and get an id; the guest's proxy calls back through
// `closure_invoke` keyed by it and releases it via `foreign_release` when the
// guest-side proxy is dropped.
typedef void (*SwiftFFIHostDispatch)(void *ctx, const uint8_t *args,
                                     size_t args_len, SwiftFFIBlobWriter *out);
int32_t swift_ffi_host_register_foreign(SwiftFFIHostRuntime *rt, void *ctx,
                                        SwiftFFIHostDispatch dispatch);
void swift_ffi_host_release_foreign(SwiftFFIHostRuntime *rt, int32_t id);

/* Blob typedefs live above the registry declaration (dispatchers write
 * through a SwiftFFIBlobWriter). */

/* Reads the (tag, aux) header; returns the tag. */
int32_t swift_ffi_blob_header(SwiftFFIBlobReader *r, int32_t *aux_out);
int64_t swift_ffi_blob_i64(SwiftFFIBlobReader *r);
/* Reads a length-prefixed byte payload (STRING/BYTES, after the header);
 * returns a malloc'd NUL-terminated copy (caller frees), len via out. */
char *swift_ffi_blob_bytes(SwiftFFIBlobReader *r, size_t *len_out);

void swift_ffi_blob_w_i32(SwiftFFIBlobWriter *w, int32_t v);
void swift_ffi_blob_w_i64(SwiftFFIBlobWriter *w, int64_t v);
void swift_ffi_blob_w_header(SwiftFFIBlobWriter *w, int32_t tag, int32_t aux);
void swift_ffi_blob_w_raw(SwiftFFIBlobWriter *w, const void *bytes, size_t len);
/* Convenience encoders (full values, header included). */
void swift_ffi_blob_w_void(SwiftFFIBlobWriter *w);
void swift_ffi_blob_w_int(SwiftFFIBlobWriter *w, int64_t v);      /* Swift Int  */
void swift_ffi_blob_w_int32v(SwiftFFIBlobWriter *w, int32_t v);   /* Int32      */
void swift_ffi_blob_w_bool(SwiftFFIBlobWriter *w, int v);
void swift_ffi_blob_w_double(SwiftFFIBlobWriter *w, double v);
void swift_ffi_blob_w_string(SwiftFFIBlobWriter *w, const char *utf8);
/* An ERROR blob (a dispatcher's failure answer; the guest proxy throws). */
void swift_ffi_blob_w_error(SwiftFFIBlobWriter *w, const char *message);
/* A LIST blob of `count` UTF-8 strings. */
void swift_ffi_blob_w_string_list(SwiftFFIBlobWriter *w, const char *const *items, size_t count);

/* Answers an in-flight async interface call (the guest's fixed
 * `swift_ffi_async_resume` export): `blob` is the result value or an ERROR
 * blob. Call on the engine's thread. Runs any Swift jobs the resumed task
 * enqueues (swift_ffi_host_run_jobs). */
void swift_ffi_host_async_resume(SwiftFFIHostRuntime *rt, int32_t call_id,
                                 const uint8_t *blob, size_t len);

/* Swift concurrency jobs the guest enqueues (`task_enqueue`) queue here; a
 * host drains them with swift_ffi_host_run_jobs on the engine's thread. The
 * optional scheduler is told whenever the queue goes from empty to
 * non-empty so the host can post a drain to its loop. */
typedef void (*SwiftFFIHostJobScheduler)(void *user);
void swift_ffi_host_set_job_scheduler(SwiftFFIHostRuntime *rt,
                                      SwiftFFIHostJobScheduler scheduler, void *user);
/* Runs every queued job, and every timed job (`task_enqueue_after`) whose
 * delay is up; returns how many ran. The scheduler is also told when a
 * timed job is added. */
size_t swift_ffi_host_run_jobs(SwiftFFIHostRuntime *rt);
/* Milliseconds until the next timed job is due (0 when one is due now), or
 * -1 when none waits: how long a host may sleep before it drains again. */
int64_t swift_ffi_host_next_job_delay_ms(SwiftFFIHostRuntime *rt);

/* --- Dependency injection (docs/wasm_di.md) ------------------------------ */
/* The generic host half of the guest's `dependencies` dictionary. The host
 * installs a table of entries; the guest resolves them through the standard
 * `<prefix>dependency_get` import and dispatches method calls through
 * `<prefix>closure_invoke` as ordinal-led blobs. Everything here is
 * module-agnostic — the generated per-module header supplies typed vtable
 * adapters on top, but a host may also hand-write a dispatcher. */

/* One injected dependency: `dispatch` runs one method call — `args` is the
 * blob the guest's proxy sent (method ordinal first), and the blob-encoded
 * result (nothing for Void) is appended to `out`. `registry_key` is the
 * interface's identity (`swift_ffi_[<ns>_]<Interface>` — what the guest's
 * macro-registered proxy factory is filed under). */
typedef struct {
    const char *key;             /* the dictionary key (copied) */
    const char *registry_key;    /* the interface's registry key (copied) */
    const char *register_symbol; /* the guest's register export
                                    (swift_ffi_[<ns>_]register_<Proto>; copied) */
    int lazy;                    /* guest wraps the proxy in Lazy when nonzero */
    void *ctx;                   /* passed through to dispatch */
    SwiftFFIHostDispatch dispatch;
} SwiftFFIHostDependency;

/* Installs the dependency table (entries and keys are copied; `ctx` must
 * outlive the runtime). Replaces any previous table. */
void swift_ffi_host_set_dependencies(SwiftFFIHostRuntime *rt,
                                     const SwiftFFIHostDependency *deps,
                                     size_t count);

/* The number of fixed `swift_ffi` imports EVERY reactor declares. */
#define SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT 6

/* Fills `out` with the fixed `swift_ffi` imports EVERY reactor declares
 * (the SwiftFFI runtime references them unconditionally and reactors link
 * with --no-gc-sections) — `closure_invoke`, `dependency_get`,
 * `foreign_release`, `task_enqueue`, `task_enqueue_after`, `async_complete`
 * (the last is a no-op stub: this C host covers the synchronous subset) —
 * returning the count (SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT). Bind the whole
 * set before instantiation. */
size_t swift_ffi_host_standard_imports(SwiftFFIHostRuntime *rt,
                                       SwiftFFIHostImport out[SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT]);

/* Registers the installed dependencies' guest-side proxy factories by calling
 * each entry's register export (deduplicated). Call once AFTER instantiation,
 * before the guest's first lookup; a no-op with no table installed. */
void swift_ffi_host_activate_dependencies(SwiftFFIHostRuntime *rt);

#ifdef __cplusplus
}
#endif

#endif  // SWIFT_FFI_HOST_H
