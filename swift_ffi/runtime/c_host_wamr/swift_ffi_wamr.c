#include "swift_ffi_wamr.h"

#include <stdlib.h>
#include <string.h>

#include "wasm_export.h"

// One bound foreign import: the generated handler + whether it (last) returned a
// value, so the raw trampoline knows whether to write a result slot. WAMR
// derives the wasm arg count from the module's declared import type, so we don't
// carry it here.
typedef struct {
    SwiftFFIHostImport import;
} SwiftFFIWamrBinding;

struct SwiftFFIWamr {
    wasm_module_t module;
    wasm_module_inst_t inst;
    wasm_exec_env_t exec_env;
    SwiftFFIEngine engine;
    uint8_t *wasm;  // owned, mutable copy (WAMR rewrites it in place; must stay
                    // referenceable until wasm_runtime_unload)
    uint32_t wasm_len;
    int counted;             // holds a ref on the global WAMR runtime
    int registered_natives;  // this rt owns the global "swift_ffi" registration
    SwiftFFIWamrBinding bindings[32];
    int binding_count;
};

// The WAMR runtime is process-global (one wasm_runtime_full_init); the raw
// "swift_ffi" foreign natives are registered against it. Ref-counted so the last
// teardown destroys it. Single reactor per process is the supported model (the
// global native table's attachments point at one rt's bindings); that matches
// every swift_ffi example and consumer that runs one reactor at a time.
static int g_refcount = 0;
static NativeSymbol g_natives[32];
static uint32_t g_native_count = 0;

// ---- SwiftFFIEngine over WAMR: call an export, read/write linear memory. ----

static int engine_call(void *ctx, const char *name, const SwiftFFIScalar *args,
                       size_t nargs, SwiftFFIScalar *out, int *has_result) {
    SwiftFFIWamr *rt = (SwiftFFIWamr *)ctx;
    if (!rt->inst) return 0;
    wasm_function_inst_t fn = wasm_runtime_lookup_function(rt->inst, name);
    if (!fn) return 0;

    // Pack args into WAMR's flat uint32 slot array (also receives results):
    // i32 = one slot, f64/f32 = two little-endian slots.
    uint32_t argv[32];
    uint32_t argc = 0;
    for (size_t i = 0; i < nargs && argc + 2 <= 32; i++) {
        if (args[i].kind == SWIFT_FFI_F64 || args[i].kind == SWIFT_FFI_F32) {
            double d = args[i].kind == SWIFT_FFI_F64 ? args[i].value.f64
                                                     : (double)args[i].value.f32;
            memcpy(&argv[argc], &d, sizeof(double));
            argc += 2;
        } else {
            argv[argc++] = (uint32_t)args[i].value.i32;
        }
    }
    if (!wasm_runtime_call_wasm(rt->exec_env, fn, argc, argv)) return 0;

    if (out && wasm_func_get_result_count(fn, rt->inst) >= 1) {
        wasm_valkind_t kinds[1] = {WASM_I32};
        wasm_func_get_result_types(fn, rt->inst, kinds);
        if (kinds[0] == WASM_F64) {
            double d;
            memcpy(&d, &argv[0], sizeof(double));
            out->kind = SWIFT_FFI_F64;
            out->value.f64 = d;
        } else {
            out->kind = SWIFT_FFI_I32;
            out->value.i32 = (int32_t)argv[0];
        }
        if (has_result) *has_result = 1;
    } else if (has_result) {
        *has_result = 0;
    }
    return 1;
}

static void engine_read(void *ctx, uint32_t ptr, uint32_t len, uint8_t *dst) {
    SwiftFFIWamr *rt = (SwiftFFIWamr *)ctx;
    if (!rt->inst || !wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    const void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(dst, p, len);
}

static void engine_write(void *ctx, uint32_t ptr, const uint8_t *src, uint32_t len) {
    SwiftFFIWamr *rt = (SwiftFFIWamr *)ctx;
    if (!rt->inst || !wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(p, src, len);
}

// ---- One generic WAMR raw native for every bound foreign import. Raw natives
// get (exec_env, uint64 *argv) with one slot per wasm param (i32 in the low 32
// bits); WAMR derives the param count from the module's import type. We adapt
// the slots to scalars, run the generated handler, and write its result back to
// slot 0 (WAMR consumes it only for imports that declare a return). The
// SwiftFFIWamrBinding arrives as the native symbol's attachment. ----
static void trampoline(wasm_exec_env_t e, uint64_t *argv) {
    SwiftFFIWamrBinding *b = (SwiftFFIWamrBinding *)wasm_runtime_get_function_attachment(e);
    if (!b) return;
    // The generated handlers read only the leading logical args; a generous
    // fixed window is harmless (extra slots are ignored).
    SwiftFFIScalar args[16];
    for (int i = 0; i < 16; i++) {
        args[i].kind = SWIFT_FFI_I32;
        args[i].value.i32 = (int32_t)(uint32_t)argv[i];
    }
    SwiftFFIScalar out;
    out.kind = SWIFT_FFI_I32;
    out.value.i32 = 0;
    int has = 0;
    b->import.handler(b->import.user, args, 16, &out, &has);
    if (has) {
        if (out.kind == SWIFT_FFI_F64 || out.kind == SWIFT_FFI_F32) {
            double d = out.kind == SWIFT_FFI_F64 ? out.value.f64 : (double)out.value.f32;
            memcpy(argv, &d, sizeof(double));
        } else {
            *(uint32_t *)argv = (uint32_t)out.value.i32;
        }
    }
}

// ---- lifecycle ----

static void fail(char *err, size_t err_len, const char *msg) {
    if (err && err_len) {
        strncpy(err, msg ? msg : "unknown error", err_len - 1);
        err[err_len - 1] = '\0';
    }
}

SwiftFFIWamr *swift_ffi_wamr_new(const uint8_t *wasm, size_t wasm_len) {
    SwiftFFIWamr *rt = (SwiftFFIWamr *)calloc(1, sizeof(SwiftFFIWamr));
    if (!rt) return NULL;
    rt->wasm_len = (uint32_t)wasm_len;
    rt->wasm = (uint8_t *)malloc(wasm_len ? wasm_len : 1);
    if (!rt->wasm) { free(rt); return NULL; }
    memcpy(rt->wasm, wasm, wasm_len);
    rt->engine.ctx = rt;
    rt->engine.call = engine_call;
    rt->engine.read_bytes = engine_read;
    rt->engine.write_bytes = engine_write;
    return rt;
}

const SwiftFFIEngine *swift_ffi_wamr_engine(SwiftFFIWamr *rt) {
    return rt ? &rt->engine : NULL;
}

int swift_ffi_wamr_bind_imports(SwiftFFIWamr *rt,
                                const SwiftFFIHostImport *imports, size_t count) {
    if (!rt) return 0;
    for (size_t i = 0; i < count && rt->binding_count < 32; i++) {
        rt->bindings[rt->binding_count++].import = imports[i];
    }
    return 1;
}

int swift_ffi_wamr_instantiate(SwiftFFIWamr *rt, char *err, size_t err_len) {
    if (!rt) { fail(err, err_len, "null runtime"); return 0; }

    if (g_refcount == 0) {
        RuntimeInitArgs init;
        memset(&init, 0, sizeof(init));
        init.mem_alloc_type = Alloc_With_System_Allocator;
        if (!wasm_runtime_full_init(&init)) {
            fail(err, err_len, "wasm_runtime_full_init failed");
            return 0;
        }
        // First reactor: publish this rt's bindings as the global "swift_ffi"
        // native table (each import routes through the one raw trampoline; its
        // binding travels as the attachment).
        g_native_count = 0;
        for (int i = 0; i < rt->binding_count && g_native_count < 32; i++) {
            NativeSymbol *sym = &g_natives[g_native_count++];
            sym->symbol = rt->bindings[i].import.name;
            sym->func_ptr = (void *)trampoline;
            sym->signature = NULL;  // arg count comes from the module import
            sym->attachment = &rt->bindings[i];
        }
        if (g_native_count > 0 &&
            !wasm_runtime_register_natives_raw("swift_ffi", g_natives, g_native_count)) {
            fail(err, err_len, "register natives failed");
            wasm_runtime_destroy();
            return 0;
        }
        rt->registered_natives = 1;
    }
    g_refcount++;
    rt->counted = 1;

    char werr[192] = {0};
    rt->module = wasm_runtime_load(rt->wasm, rt->wasm_len, werr, sizeof(werr));
    if (!rt->module) { fail(err, err_len, werr[0] ? werr : "wasm load failed"); return 0; }

    wasm_runtime_set_wasi_args(rt->module, NULL, 0, NULL, 0, NULL, 0, NULL, 0);

    // 16 MiB linear/auxiliary stack: Swift's recursive metadata instantiation
    // and view-tree builds overflow wasm-ld's ~1 MiB default. WAMR overrides the
    // linked value with this param, so it must be generous.
    rt->inst = wasm_runtime_instantiate(rt->module, 16 * 1024 * 1024, 16 * 1024 * 1024,
                                        werr, sizeof(werr));
    if (!rt->inst) { fail(err, err_len, werr[0] ? werr : "instantiate failed"); return 0; }

    wasm_runtime_set_custom_data(rt->inst, rt);
    rt->exec_env = wasm_runtime_create_exec_env(rt->inst, 512 * 1024);
    if (!rt->exec_env) { fail(err, err_len, "create exec_env failed"); return 0; }
    return 1;
}

void swift_ffi_wamr_destroy(SwiftFFIWamr *rt) {
    if (!rt) return;
    if (rt->exec_env) wasm_runtime_destroy_exec_env(rt->exec_env);
    if (rt->inst) wasm_runtime_deinstantiate(rt->inst);
    if (rt->module) wasm_runtime_unload(rt->module);
    free(rt->wasm);
    if (rt->counted && --g_refcount == 0) {
        if (rt->registered_natives && g_native_count > 0)
            wasm_runtime_unregister_natives("swift_ffi", g_natives);
        wasm_runtime_destroy();
    }
    free(rt);
}
