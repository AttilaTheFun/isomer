#include "iso_wamr.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <sys/stat.h>
#endif
#ifdef _WIN32
#include <windows.h>
#else
#include <sys/time.h>
#endif

#include "wasm_export.h"

// The engine-agnostic swift_ffi C host runtime: iso_wamr supplies only the
// WAMR SwiftFFIEngine binding (below) and binds the runtime's FIXED standard
// import set (closure_invoke / dependency_get / foreign_release /
// task_enqueue / task_enqueue_after / async_complete — every v3 reactor imports exactly these).
// The EMBEDDING APP owns everything module-specific: it registers its
// dependency table on `iso_wamr_ffi_host(rt)` (typically with its generated
// `<module>_c_host.h` adapters) and calls its module's exports through the
// same runtime.
#include "swift_ffi_host.h"

// One bound swift_ffi import: the generated handler + whether it returns a value
// (so the raw trampoline knows whether to write result slot 0). WAMR derives the
// arg count from the module's declared import type, so — unlike the WAMR host —
// we don't carry the trailing calling-convention context slots here.
typedef struct {
    SwiftFFIHostImport import;
    int has_result;  // non-zero if the import returns an i32
    int slot;        // index into the per-instance binding table
} IsoFfiBinding;

struct IsoWamr {
    // Set while an event's handler runs (iso_wamr_event): a render the guest
    // asks to have scheduled then is the one that follows at once, so the
    // host is not asked for another.
    int gate_schedule;
    // Whether the reactor exports iso_hot_render_pending: 0 not yet looked
    // up, 1 it does, 2 it does not (iso_wamr_render_pending).
    int render_pending_export;
    wasm_module_t module;
    wasm_module_inst_t inst;
    wasm_exec_env_t exec_env;
    IsoWamrCallbacks cb;
    uint8_t *wasm;    // owned, mutable copy (WAMR rewrites it in place; must
                      // stay referenceable until wasm_runtime_unload) — or a
                      // BORROWED read-only pointer on the in-place/XIP path
    int wasm_borrowed;
    uint32_t wasm_len;
    int counted;      // this instance holds a ref on the global WAMR runtime

    // Profiling: how long the last render_tree host callback (Kotlin decode +
    // Compose setState) took, and the tree size, so iso_wamr_event can attribute
    // its render phase between interpreted-wasm work and the host upcall.
    double last_tree_cb_ms;
    uint32_t last_tree_bytes;

    // The generic swift_ffi transport (NULL when cb.ffi_prefix is NULL): the
    // host runtime, the standard DI imports the trampoline drives, and the
    // dependency-activation latch.
    SwiftFFIHostRuntime *ffi_host;
    SwiftFFIHostImport std_imports[SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT];
    size_t std_import_count;
    int deps_activated;
    IsoFfiBinding ffi_bindings[8];
    int ffi_binding_count;

    // GPU-reactor raster staging: raster_begin stashes the host-rasterized
    // bytes here; raster_copy hands them to the guest and frees the stash.
    uint8_t *raster_buf;
    size_t raster_len;
};

// The swift_ffi job-scheduler hook: the guest queued a job; the host decides
// when iso_wamr_run_jobs runs (its UI loop), or drains inline without a hook.
static void iso_wamr_jobs_scheduled(void *user) {
    IsoWamr *rt = (IsoWamr *)user;
    if (rt && rt->cb.on_schedule_jobs) rt->cb.on_schedule_jobs(rt->cb.ctx);
}

// Optional platform natives (e.g. the Android GLES "env" module); registered
// once inside the first create, right after runtime init. See iso_wamr.h.
static int (*g_extra_natives)(void) = NULL;

void iso_wamr_set_extra_natives(int (*register_natives)(void)) {
    g_extra_natives = register_natives;
}

// The WAMR runtime is process-global (one wasm_runtime_full_init); the `iso_hot`
// and `swift_ffi` native modules are registered against it. Ref-counted so
// multiple reactors can coexist and the last teardown destroys the runtime.
// Single-threaded create/destroy is assumed (the Android host serializes these).
static int g_wamr_refcount = 0;

// The running instance's IsoWamr is stashed as the module-inst custom data so
// the iso_hot natives (which only receive exec_env) can reach the callbacks.
static IsoWamr *rt_of(wasm_exec_env_t e) {
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(e);
    return inst ? (IsoWamr *)wasm_runtime_get_custom_data(inst) : NULL;
}

static double iso_now_ms(void) {
#ifdef _WIN32
    // FILETIME is 100-ns ticks since 1601; we only use deltas, so the epoch is
    // irrelevant. GetSystemTimeAsFileTime is coarse (~1-15ms) but the WAMR host
    // only uses this for phase profiling, not for wall-clock accuracy.
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u;
    u.LowPart = ft.dwLowDateTime;
    u.HighPart = ft.dwHighDateTime;
    return (double)u.QuadPart / 10000.0;  // 100-ns ticks -> ms
#else
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec * 1000.0 + (double)tv.tv_usec / 1000.0;
#endif
}

// ---- iso_hot host imports (wasm -> host). Registered as typed WAMR natives:
// exec_env comes first, then the wasm arg values (i32 as uint32). Logical args
// come first; the trailing Swift calling-convention context i32s are ignored. ----

// iso_hot.render_tree(ptr, len, ctx, ctx)
static void nat_render_tree(wasm_exec_env_t e, uint32_t ptr, uint32_t len,
                            uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->cb.on_tree) return;
    const uint8_t *p = (const uint8_t *)wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) {
        double s = iso_now_ms();
        rt->cb.on_tree(rt->cb.ctx, p, len);
        rt->last_tree_cb_ms = iso_now_ms() - s;
        rt->last_tree_bytes = len;
    }
}

// iso_hot.log(ptr, len, ctx, ctx)
static void nat_log(wasm_exec_env_t e, uint32_t ptr, uint32_t len, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->cb.on_log) return;
    const char *p = (const char *)wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) rt->cb.on_log(rt->cb.ctx, p, len);
}

// iso_hot.epoch_millis(ctx, ctx) -> f64
static double nat_epoch_millis(wasm_exec_env_t e, uint32_t a, uint32_t b) {
    (void)e;
    (void)a;
    (void)b;
    return iso_now_ms();
}

// iso_hot.schedule_render(ctx, ctx)
static void nat_schedule_render(wasm_exec_env_t e, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (rt && !rt->gate_schedule && rt->cb.on_schedule_render) rt->cb.on_schedule_render(rt->cb.ctx);
}

// A guest string (ptr, len) as a host pointer; "" for an empty one (the
// guest may pass a null base for it).
static const char *guest_chars(IsoWamr *rt, uint32_t ptr, uint32_t len) {
    if (len == 0) return "";
    if (!wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return NULL;
    return (const char *)wasm_runtime_addr_app_to_native(rt->inst, ptr);
}

// iso_hot.platform_command(key_ptr, key_len, value_ptr, value_len, ctx, ctx)
static void nat_platform_command(wasm_exec_env_t e, uint32_t kp, uint32_t kl,
                                 uint32_t vp, uint32_t vl, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->cb.on_platform_command) return;
    const char *key = guest_chars(rt, kp, kl), *value = guest_chars(rt, vp, vl);
    if (key && value) rt->cb.on_platform_command(rt->cb.ctx, key, kl, value, vl);
}

// iso_hot.host_value(key_ptr, key_len, out_ptr, capacity, ctx, ctx) -> i32
static int32_t nat_host_value(wasm_exec_env_t e, uint32_t kp, uint32_t kl,
                              uint32_t op, uint32_t cap, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->cb.host_value) return -1;
    const char *key = guest_chars(rt, kp, kl);
    uint8_t *out = cap ? (uint8_t *)guest_chars(rt, op, cap) : NULL;
    if (!key || (cap && !out)) return -1;
    return rt->cb.host_value(rt->cb.ctx, key, kl, out, cap);
}

static NativeSymbol g_iso_hot_natives[] = {
    {"render_tree", (void *)nat_render_tree, "(iiii)", NULL},
    {"log", (void *)nat_log, "(iiii)", NULL},
    {"epoch_millis", (void *)nat_epoch_millis, "(ii)F", NULL},
    {"schedule_render", (void *)nat_schedule_render, "(ii)", NULL},
    {"platform_command", (void *)nat_platform_command, "(iiiiii)", NULL},
    {"host_value", (void *)nat_host_value, "(iiiiii)i", NULL},
};

// ---- iso_gpu host imports: the services half of a self-drawing (SwiftGPU)
// reactor — text measurement + rasterization on the host's text stack. Like
// the iso_hot natives, the trailing Swift calling-convention i32s are ignored.
// (The drawing half — the "env" GL imports — is platform code, registered via
// iso_wamr_set_extra_natives.) ----

// iso_gpu.measure_text(textPtr, textLen, fontSize f64, weight, wrap f64, outPtr, ctx, ctx)
static void nat_measure_text(wasm_exec_env_t e, uint32_t ptr, uint32_t len,
                             double font_size, uint32_t weight, double wrap_width,
                             uint32_t out_ptr, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt) return;
    double wh[2] = {0, 0};
    const char *text = (const char *)wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (text && rt->cb.measure_text) {
        rt->cb.measure_text(rt->cb.ctx, text, len, font_size, (int32_t)weight,
                            wrap_width, wh);
    }
    if (wasm_runtime_validate_app_addr(rt->inst, out_ptr, 2 * sizeof(double))) {
        double *out = (double *)wasm_runtime_addr_app_to_native(rt->inst, out_ptr);
        if (out) {
            out[0] = wh[0];
            out[1] = wh[1];
        }
    }
}

// iso_gpu.raster_begin(specPtr, specLen, ctx, ctx) -> byte length (0 = none)
static uint32_t nat_raster_begin(wasm_exec_env_t e, uint32_t ptr, uint32_t len,
                                 uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->cb.rasterize) return 0;
    free(rt->raster_buf);
    rt->raster_buf = NULL;
    rt->raster_len = 0;
    const char *spec = (const char *)wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (!spec) return 0;
    rt->raster_buf = rt->cb.rasterize(rt->cb.ctx, spec, len, &rt->raster_len);
    if (!rt->raster_buf) rt->raster_len = 0;
    return (uint32_t)rt->raster_len;
}

// iso_gpu.raster_copy(destPtr, ctx, ctx) — hand the stash to the guest.
static void nat_raster_copy(wasm_exec_env_t e, uint32_t dest, uint32_t a, uint32_t b) {
    (void)a;
    (void)b;
    IsoWamr *rt = rt_of(e);
    if (!rt || !rt->raster_buf) return;
    if (wasm_runtime_validate_app_addr(rt->inst, dest, (uint32_t)rt->raster_len)) {
        void *p = wasm_runtime_addr_app_to_native(rt->inst, dest);
        if (p) memcpy(p, rt->raster_buf, rt->raster_len);
    }
    free(rt->raster_buf);
    rt->raster_buf = NULL;
    rt->raster_len = 0;
}

static NativeSymbol g_iso_gpu_natives[] = {
    {"measure_text", (void *)nat_measure_text, "(iiFiFiii)", NULL},
    {"raster_begin", (void *)nat_raster_begin, "(iiii)i", NULL},
    {"raster_copy", (void *)nat_raster_copy, "(iii)", NULL},
};

// ---- swift_ffi dependency DI. The marshaling (install handshake + foreign
// dispatch) lives in the generated swift_ffi C host (e.g. platform_services_c_host.h);
// isomer supplies (1) the WAMR SwiftFFIEngine below, (2) a generic raw
// trampoline that adapts WAMR's raw-native ABI to the generated handlers, and
// (3) the app's native service impls, registered as its dependency table. ----

// SwiftFFIEngine over WAMR: call an export, read/write the reactor's memory.
static int iso_ffi_engine_call(void *ctx, const char *name, const SwiftFFIScalar *args,
                               size_t nargs, SwiftFFIScalar *out, int *has_result) {
    IsoWamr *rt = (IsoWamr *)ctx;
    wasm_function_inst_t fn = wasm_runtime_lookup_function(rt->inst, name);
    if (!fn) return 0;

    // Pack args into WAMR's flat uint32 slot array (also receives results). Our
    // export args are i32 (and would-be f64, two slots each, little-endian).
    uint32_t argv[16];
    uint32_t argc = 0;
    if (nargs > 8) return 0;
    for (size_t i = 0; i < nargs; i++) {
        if (args[i].kind == SWIFT_FFI_F64 || args[i].kind == SWIFT_FFI_F32) {
            double d = args[i].kind == SWIFT_FFI_F64 ? args[i].value.f64 : (double)args[i].value.f32;
            memcpy(&argv[argc], &d, sizeof(double));
            argc += 2;
        } else {
            argv[argc++] = (uint32_t)args[i].value.i32;
        }
    }
    if (!wasm_runtime_call_wasm(rt->exec_env, fn, argc, argv)) return 0;

    if (out) {
        if (wasm_func_get_result_count(fn, rt->inst) >= 1) {
            out->kind = SWIFT_FFI_I32;
            out->value.i32 = (int32_t)argv[0];
            if (has_result) *has_result = 1;
        } else if (has_result) {
            *has_result = 0;
        }
    }
    return 1;
}

static void iso_ffi_engine_read(void *ctx, uint32_t ptr, uint32_t len, uint8_t *dst) {
    IsoWamr *rt = (IsoWamr *)ctx;
    if (!wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    const void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(dst, p, len);
}

static void iso_ffi_engine_write(void *ctx, uint32_t ptr, const uint8_t *src, uint32_t len) {
    IsoWamr *rt = (IsoWamr *)ctx;
    if (!wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(p, src, len);
}

// One generic WAMR raw native for every bound swift_ffi import. Raw natives get
// (exec_env, uint64 *argv) with one slot per wasm param (i32 in the low 32 bits);
// WAMR derives the param count from the module's import type. We read the logical
// args into scalars, run the generated handler, and write its result to slot 0
// (WAMR copies it back for imports that declare a return). The IsoFfiBinding
// arrives as the native symbol's attachment.
static IsoWamr *iso_rt_of(wasm_exec_env_t e) {
    wasm_module_inst_t inst = wasm_runtime_get_module_inst(e);
    return inst ? (IsoWamr *)wasm_runtime_get_custom_data(inst) : NULL;
}

static void iso_ffi_trampoline(wasm_exec_env_t e, uint64_t *argv) {
    // The attachment is a PROCESS-GLOBAL slot (native registration happens
    // once and outlives every instance); the live handler + its user pointer
    // belong to the CALLING instance — resolve them through exec_env, or a
    // reload's second instance would call through the first one's freed host
    // (the crash this replaced: iso_ffi_trampoline -> pc 0).
    IsoFfiBinding *g = (IsoFfiBinding *)wasm_runtime_get_function_attachment(e);
    if (!g) return;
    IsoWamr *rt = iso_rt_of(e);
    IsoFfiBinding *b = (rt && g->slot < rt->ffi_binding_count)
        ? &rt->ffi_bindings[g->slot] : g;
    // The generated handlers read only the leading logical args (id + ptr/len);
    // any trailing Swift context slots are simply not consumed. Pass through a
    // generous fixed window — extra slots are harmless.
    SwiftFFIScalar args[8];
    for (int i = 0; i < 8; i++) {
        args[i].kind = SWIFT_FFI_I32;
        args[i].value.i32 = (int32_t)(uint32_t)argv[i];
    }
    SwiftFFIScalar out;
    out.kind = SWIFT_FFI_I32;
    out.value.i32 = 0;
    int has = 0;
    b->import.handler(b->import.user, args, 8, &out, &has);
    if (b->has_result) {
        if (has && out.kind == SWIFT_FFI_I64) {
            memcpy(argv, &out.value.i64, 8);
        } else if (has) {
            *(uint32_t *)argv = (uint32_t)out.value.i32;
        } else {
            memset(argv, 0, 8);
        }
    }
}

// Which swift_ffi standard imports return a value (so the trampoline writes back
// result slot 0). Matched by name suffix — module-agnostic.
static int iso_ffi_has_result(const char *name) {
    size_t nl = strlen(name);
    static const char *suffixes[] = {
        "dependency_get",
        "closure_invoke",
    };
    for (size_t i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++) {
        size_t fl = strlen(suffixes[i]);
        if (nl >= fl && strcmp(name + nl - fl, suffixes[i]) == 0) return 1;
    }
    return 0;
}

// Populated per-instance in create() (attachment points at rt->ffi_bindings);
// the module name is "swift_ffi" to match the reactor's imports.
static NativeSymbol g_swift_ffi_natives[8];
static int g_swift_ffi_native_count = 0;
// Process-lifetime attachment storage (see iso_ffi_trampoline).
static IsoFfiBinding g_ffi_global_bindings[8];

// ---- lifecycle ----

static void fail(char *err, size_t err_len, const char *msg) {
    if (err && err_len) {
        strncpy(err, msg ? msg : "unknown error", err_len - 1);
        err[err_len - 1] = '\0';
    }
}

static IsoWamr *iso_wamr_create_internal(const uint8_t *wasm, size_t wasm_len,
                                          int in_place, IsoWamrCallbacks callbacks,
                                          char *err, size_t err_len) {
    IsoWamr *rt = (IsoWamr *)calloc(1, sizeof(IsoWamr));
    if (!rt) { fail(err, err_len, "out of memory"); return NULL; }
    rt->cb = callbacks;
    rt->wasm_len = (uint32_t)wasm_len;
    if (in_place) {
        // The caller's buffer is used directly and never freed — the embedded
        // XIP path: an indirect-mode .aot living in the app's signed __TEXT
        // segment, whose code WAMR executes in place (create_sections skips
        // the exec-mmap copy for indirect-mode modules). This is how AOT wasm
        // runs on iOS, where dynamically mapped executable pages are banned.
        rt->wasm = (uint8_t *)wasm;
        rt->wasm_borrowed = 1;
    } else {
        rt->wasm = (uint8_t *)malloc(wasm_len);
        if (!rt->wasm) { fail(err, err_len, "out of memory"); free(rt); return NULL; }
        memcpy(rt->wasm, wasm, wasm_len);
    }

    // Build the generic swift_ffi transport first (when the host opted in —
    // ffi_prefix non-NULL; the value itself is unused since v3's import names
    // are fixed): its standard imports name the natives we register with
    // WAMR, and each import's binding is the raw trampoline's attachment. The
    // app's dependency table is registered by the embedder AFTER create, on
    // iso_wamr_ffi_host(rt).
    if (callbacks.ffi_prefix) {
        SwiftFFIEngine engine;
        engine.ctx = rt;
        engine.call = iso_ffi_engine_call;
        engine.read_bytes = iso_ffi_engine_read;
        engine.write_bytes = iso_ffi_engine_write;
        rt->ffi_host = swift_ffi_host_create(&engine);
        if (rt->ffi_host) {
            rt->std_import_count =
                swift_ffi_host_standard_imports(rt->ffi_host, rt->std_imports);
            // Guest jobs (task_enqueue) drain through iso_wamr_run_jobs; tell
            // the host when the queue becomes non-empty.
            swift_ffi_host_set_job_scheduler(rt->ffi_host, iso_wamr_jobs_scheduled, rt);
        }
    }

    // First reactor: init the process-global WAMR runtime and register the two
    // native modules. The swift_ffi natives all route through one raw trampoline;
    // their per-import binding travels as the attachment. Registration is global,
    // so the attachment must point at storage that outlives every instance —
    // here the first instance's ffi_bindings (all instances share the same
    // AppServices import set and stateless dispatchers; the trampoline recovers
    // the *calling* instance from exec_env, not from the binding).
    if (g_wamr_refcount == 0) {
        RuntimeInitArgs init;
        memset(&init, 0, sizeof(init));
        init.mem_alloc_type = Alloc_With_System_Allocator;
        if (!wasm_runtime_full_init(&init)) {
            fail(err, err_len, "wasm_runtime_full_init failed");
            goto boom;
        }

        g_swift_ffi_native_count = 0;
        if (rt->ffi_host) {
            const SwiftFFIHostImport *imports = rt->std_imports;
            size_t count = rt->std_import_count;
            for (size_t i = 0; i < count && rt->ffi_binding_count < 8; i++) {
                IsoFfiBinding *bnd = &rt->ffi_bindings[rt->ffi_binding_count];
                bnd->import = imports[i];
                bnd->has_result = iso_ffi_has_result(imports[i].name);
                bnd->slot = (int)i;
                // The REGISTERED attachment must outlive every instance
                // (registration is process-global): a static copy carrying
                // the slot index + a fallback import. The trampoline swaps
                // in the calling instance's live binding by slot.
                g_ffi_global_bindings[i] = *bnd;
                NativeSymbol *sym = &g_swift_ffi_natives[g_swift_ffi_native_count++];
                // Registration is process-global but the import name is owned
                // by this instance's runtime — keep a process-lifetime copy.
                {
                    size_t name_len = strlen(imports[i].name);
                    char *name_copy = (char *)malloc(name_len + 1);
                    memcpy(name_copy, imports[i].name, name_len + 1);
                    sym->symbol = name_copy;
                }
                sym->func_ptr = (void *)iso_ffi_trampoline;
                sym->signature = NULL;  // arg count comes from the module import
                sym->attachment = &g_ffi_global_bindings[i];
                rt->ffi_binding_count++;
            }
        }

        if (!wasm_runtime_register_natives("iso_hot", g_iso_hot_natives,
                                           sizeof(g_iso_hot_natives) / sizeof(g_iso_hot_natives[0])) ||
            !wasm_runtime_register_natives("iso_gpu", g_iso_gpu_natives,
                                           sizeof(g_iso_gpu_natives) / sizeof(g_iso_gpu_natives[0])) ||
            (g_swift_ffi_native_count > 0 &&
             !wasm_runtime_register_natives_raw("swift_ffi", g_swift_ffi_natives,
                                                (uint32_t)g_swift_ffi_native_count)) ||
            (g_extra_natives && !g_extra_natives())) {
            fail(err, err_len, "register natives failed");
            wasm_runtime_destroy();
            goto boom;
        }
    } else if (rt->ffi_host) {
        // Reuse the already-registered natives; still record this instance's
        // bindings so the trampoline resolves through THIS instance's runtime.
        const SwiftFFIHostImport *imports = rt->std_imports;
        size_t count = rt->std_import_count;
        for (size_t i = 0; i < count && rt->ffi_binding_count < 8; i++) {
            rt->ffi_bindings[rt->ffi_binding_count].import = imports[i];
            rt->ffi_bindings[rt->ffi_binding_count].has_result =
                iso_ffi_has_result(imports[i].name);
            rt->ffi_bindings[rt->ffi_binding_count].slot = (int)i;
            rt->ffi_binding_count++;
        }
    }
    g_wamr_refcount++;
    rt->counted = 1;

    char werr[192] = {0};
    double t_load0 = iso_now_ms();
    rt->module = wasm_runtime_load(rt->wasm, rt->wasm_len, werr, sizeof(werr));
    if (!rt->module) { fail(err, err_len, werr[0] ? werr : "wasm load failed"); goto boom; }
    double t_load_ms = iso_now_ms() - t_load0;

    // Give the reactor its WASI environment before instantiate: the host's
    // ISO_-prefixed variables are forwarded (the guest's launchEnvironment
    // hooks — e.g. ISO_OPEN_APP for headless verification — read them).
    {
        extern char **environ;
        static const char *wasi_env[20];
        int wasi_env_count = 0;
        for (char **e = environ; e && *e && wasi_env_count < 15; e++) {
            if (strncmp(*e, "ISO_", 4) == 0) wasi_env[wasi_env_count++] = *e;
        }
        // A folder of the host's temporary directory is the guest's /tmp:
        // what a person picks (a file, a photo, a photo taken) is put there
        // by the host's picker and read by the app with Foundation
        // (IsomerTree's IsomerPickedFiles). Without a TMPDIR, none.
        static char guest_tmp[1200];
        static char guest_home[1200];
        static char bundle_env[600];
        const char *map_dirs[2];
        uint32_t map_count = 0;
        const char *tmp = getenv("TMPDIR");
        if (tmp && *tmp) {
            char host[1100];
            size_t len = strlen(tmp);
            snprintf(host, sizeof(host), "%s%sisomer-guest", tmp, tmp[len - 1] == '/' ? "" : "/");
#if defined(_WIN32)
            CreateDirectoryA(host, NULL);
#else
            mkdir(host, 0700);
#endif
            snprintf(guest_tmp, sizeof(guest_tmp), "/tmp::%s", host);
            map_dirs[map_count++] = guest_tmp;
        }
        // The app's home (callbacks.home_dir), an iOS container's layout:
        // the guest's FileManager finds Documents under HOME, Application
        // Support and Caches through XDG_DATA_HOME and XDG_CACHE_HOME.
        const char *home = rt->cb.home_dir;
        if (home && *home) {
            static const char *const made[] = {
                "Documents", "Library", "Library/Application Support", "Library/Caches",
            };
            for (size_t i = 0; i < sizeof(made) / sizeof(made[0]); i++) {
                char path[1200];
                snprintf(path, sizeof(path), "%s/%s", home, made[i]);
#if defined(_WIN32)
                CreateDirectoryA(path, NULL);
#else
                mkdir(path, 0700);
#endif
            }
            snprintf(guest_home, sizeof(guest_home), "/home/app::%s", home);
            map_dirs[map_count++] = guest_home;
            wasi_env[wasi_env_count++] = "HOME=/home/app";
            wasi_env[wasi_env_count++] = "XDG_DATA_HOME=/home/app/Library/Application Support";
            wasi_env[wasi_env_count++] = "XDG_CACHE_HOME=/home/app/Library/Caches";
        }
        if (rt->cb.bundle_identifier && *rt->cb.bundle_identifier) {
            snprintf(bundle_env, sizeof(bundle_env), "ISOMER_BUNDLE_IDENTIFIER=%s", rt->cb.bundle_identifier);
            wasi_env[wasi_env_count++] = bundle_env;
        }
        wasm_runtime_set_wasi_args(rt->module, NULL, 0, map_dirs, map_count,
                                   wasi_env, wasi_env_count, NULL, 0);
    }

    // stack_size is the app's AUXILIARY (linear-memory) stack — the reactor is
    // linked with 16 MiB and WAMR OVERRIDES the linked value with this param, so
    // it must match or the deep Swift view-tree build overflows and traps. WAMR
    // also auto-runs the WASI reactor's `_initialize` here (do NOT call it again).
    double t_init0 = iso_now_ms();
    rt->inst = wasm_runtime_instantiate(rt->module, 16 * 1024 * 1024, 16 * 1024 * 1024,
                                        werr, sizeof(werr));
    if (!rt->inst) { fail(err, err_len, werr[0] ? werr : "instantiate failed"); goto boom; }
    double t_init_ms = iso_now_ms() - t_init0;

    wasm_runtime_set_custom_data(rt->inst, rt);
    // Operand/frame stack for the interpreter. Swift's deep recursion lives in
    // the 16 MiB linear stack above, not here, so 512 KiB is plenty.
    // The interpreter's own stack (its frames and operands), apart from the
    // guest's 16 MiB: 512 KiB overflowed building a VStack framed in an
    // overlay ("wasm operand stack overflow" at iso_hot_start), Swift's
    // generic metadata for such a view nesting deep.
    rt->exec_env = wasm_runtime_create_exec_env(rt->inst, 4 * 1024 * 1024);
    if (!rt->exec_env) { fail(err, err_len, "create exec_env failed"); goto boom; }

    if (rt->cb.on_log) {
        char line[160];
        int nl = snprintf(line, sizeof(line),
                          "[wamr-phases] bytes=%zu load=%.0fms instantiate(+_init)=%.0fms",
                          wasm_len, t_load_ms, t_init_ms);
        if (nl > 0) rt->cb.on_log(rt->cb.ctx, line, (size_t)nl);
    }

    return rt;

boom:
    iso_wamr_destroy(rt);
    return NULL;
}

IsoWamr *iso_wamr_create(const uint8_t *wasm, size_t wasm_len,
                           IsoWamrCallbacks callbacks, char *err, size_t err_len) {
    return iso_wamr_create_internal(wasm, wasm_len, 0, callbacks, err, err_len);
}

IsoWamr *iso_wamr_create_in_place(const uint8_t *wasm, size_t wasm_len,
                                  IsoWamrCallbacks callbacks, char *err, size_t err_len) {
    return iso_wamr_create_internal(wasm, wasm_len, 1, callbacks, err, err_len);
}

// The lifecycle below is written over the low-level seam (iso_wamr_call,
// iso_wamr_write_bytes), the same entry points the Swift `WamrRuntime` drives.

static IsoWamrValue val_i32(int32_t v) { IsoWamrValue x; x.is_f64 = 0; x.v.i32 = v; return x; }
static IsoWamrValue val_f64(double v) { IsoWamrValue x; x.is_f64 = 1; x.v.f64 = v; return x; }

static int has_export(IsoWamr *rt, const char *name) {
    return wasm_runtime_lookup_function(rt->inst, name) != NULL;
}

static void call2f(IsoWamr *rt, const char *name, double a, double b) {
    IsoWamrValue args[2] = {val_f64(a), val_f64(b)};
    iso_wamr_call(rt, name, args, 2, NULL);
}

void iso_wamr_start(IsoWamr *rt, double width, double height) {
    iso_wamr_activate_dependencies(rt);
    if (!rt) return;
    call2f(rt, "iso_hot_start", width, height);
    iso_wamr_render(rt);
}

void iso_wamr_render(IsoWamr *rt) {
    if (!rt) return;
    iso_wamr_call(rt, "iso_hot_render", NULL, 0, NULL);
}

void iso_wamr_dump_profile(IsoWamr *rt) {
#ifdef ISO_WAMR_PROFILE
    if (rt && rt->inst) wasm_runtime_dump_perf_profiling(rt->inst);
#else
    (void)rt;
#endif
}

/* A frame after an event or a run of jobs: only when the guest has one to
 * build (`iso_hot_render_pending`); a reactor without that export renders
 * as before. */
void iso_wamr_render_pending(IsoWamr *rt) {
    if (!rt) return;
    if (!rt->render_pending_export)
        rt->render_pending_export = has_export(rt, "iso_hot_render_pending") ? 1 : 2;
    if (rt->render_pending_export == 1) {
        iso_wamr_call(rt, "iso_hot_render_pending", NULL, 0, NULL);
    } else {
        iso_wamr_render(rt);
    }
}

void iso_wamr_resize(IsoWamr *rt, double width, double height) {
    if (!rt) return;
    call2f(rt, "iso_hot_resize", width, height);
    iso_wamr_render(rt);
}

void iso_wamr_set_color_scheme(IsoWamr *rt, int dark) {
    if (!rt) return;
    if (!has_export(rt, "iso_hot_set_color_scheme")) {
        // Reactor lacks the export (drifted hand-copied bridge, or a bundle
        // predating the export): the appearance stays light. Say so — a
        // silent no-op looks identical to "dark mode is broken". Compiling
        // the framework's HotBridge.swift into the reactor (instead of
        // copying the glue) makes this impossible.
        static const char msg[] =
            "[iso_wamr] reactor exports no iso_hot_set_color_scheme — "
            "appearance stays light (compile the framework HotBridge.swift)";
        if (rt->cb.on_log) rt->cb.on_log(rt->cb.ctx, msg, sizeof(msg) - 1);
        return;
    }
    IsoWamrValue args[1] = {val_i32(dark ? 1 : 0)};
    iso_wamr_call(rt, "iso_hot_set_color_scheme", args, 1, NULL);
    iso_wamr_render(rt);
}

// Stage `len` bytes into guest memory via iso_hot_alloc; returns the guest ptr.
static uint32_t stage(IsoWamr *rt, const char *bytes, uint32_t len) {
    if (len == 0) return 0;
    IsoWamrValue args[1] = {val_i32((int32_t)len)};
    IsoWamrValue out;
    if (!iso_wamr_call(rt, "iso_hot_alloc", args, 1, &out)) return 0;
    uint32_t ptr = (uint32_t)out.v.i32;
    if (ptr) iso_wamr_write_bytes(rt, ptr, (const uint8_t *)bytes, len);
    return ptr;
}

static void unstage(IsoWamr *rt, uint32_t ptr) {
    if (!ptr) return;
    IsoWamrValue args[1] = {val_i32((int32_t)ptr)};
    iso_wamr_call(rt, "iso_hot_free", args, 1, NULL);
}

void iso_wamr_surface_changed(IsoWamr *rt, int32_t width_px, int32_t height_px,
                              double density) {
    if (!rt) return;
    IsoWamrValue args[3] = {val_i32(width_px), val_i32(height_px), val_f64(density)};
    iso_wamr_call(rt, "iso_hot_surface_changed", args, 3, NULL);
}

int iso_wamr_pointer(IsoWamr *rt, int32_t kind, double x, double y) {
    if (!rt) return 0;
    IsoWamrValue args[3] = {val_i32(kind), val_f64(x), val_f64(y)};
    IsoWamrValue out;
    if (!iso_wamr_call(rt, "iso_hot_pointer", args, 3, &out)) return 0;
    return (int)out.v.i32;
}

// Whether each event's phases are logged (`ISO_EVENT_LOG=1` in the host's
// environment): a line a finger movement is a cost of its own on a phone.
static int event_log_enabled(void) {
    static int enabled = -1;
    if (enabled < 0) {
        const char *value = getenv("ISO_EVENT_LOG");
        enabled = value && value[0] == '1';
    }
    return enabled;
}

void iso_wamr_event(IsoWamr *rt, const char *id, size_t id_len,
                     const char *value, size_t value_len) {
    if (!rt) return;
    int logging = rt->cb.on_log && event_log_enabled();
    double t0 = logging ? iso_now_ms() : 0;
    uint32_t id_ptr = stage(rt, id, (uint32_t)id_len);
    uint32_t val_ptr = stage(rt, value, (uint32_t)value_len);
    double t_stage = logging ? iso_now_ms() : 0;
    {
        IsoWamrValue args[4] = {val_i32((int32_t)id_ptr), val_i32((int32_t)id_len),
                                val_i32((int32_t)val_ptr), val_i32((int32_t)value_len)};
        // The handler's state changes ask for a render: the one below is it.
        // (Asked for DURING that render — an animation's next frame — it
        // goes to the host as ever.) Without this every event was rendered
        // twice: here, and again when the host got to the scheduled one.
        rt->gate_schedule = 1;
        iso_wamr_call(rt, "iso_hot_event", args, 4, NULL);
        rt->gate_schedule = 0;
    }
    double t_event = logging ? iso_now_ms() : 0;
    unstage(rt, id_ptr);
    unstage(rt, val_ptr);
    rt->last_tree_cb_ms = 0;
    iso_wamr_render_pending(rt);
    if (!logging) return;
    double t_render = iso_now_ms();

    // Attribute the tap->update cost: `event` = the reactor's event handler
    // (the Swift state mutation); `render` = re-running the SwiftUI body
    // + FlatBuffer encode + the host tree upcall; `treeCb` = the Kotlin decode +
    // Compose setState portion of that render (the rest is wasm).
    char line[224];
    int n = snprintf(line, sizeof(line),
                     "[wamr-event] id=%.*s stage=%.1fms event=%.1fms render=%.1fms "
                     "(treeCb=%.1fms tree=%uB) total=%.1fms",
                     (int)id_len, id, t_stage - t0, t_event - t_stage,
                     t_render - t_event, rt->last_tree_cb_ms, rt->last_tree_bytes, t_render - t0);
    if (n > 0) rt->cb.on_log(rt->cb.ctx, line, (size_t)n);
}

SwiftFFIHostRuntime *iso_wamr_ffi_host(IsoWamr *rt) {
    return rt ? rt->ffi_host : NULL;
}

size_t iso_wamr_run_jobs(IsoWamr *rt) {
    SwiftFFIHostRuntime *host = iso_wamr_ffi_host(rt);
    if (!host) return 0;
    size_t ran = swift_ffi_host_run_jobs(host);
    if (ran > 0) iso_wamr_render_pending(rt);
    return ran;
}

int64_t iso_wamr_next_job_delay_ms(IsoWamr *rt) {
    SwiftFFIHostRuntime *host = iso_wamr_ffi_host(rt);
    if (!host) return -1;
    return swift_ffi_host_next_job_delay_ms(host);
}

void iso_wamr_activate_dependencies(IsoWamr *rt) {
    SwiftFFIHostRuntime *host = iso_wamr_ffi_host(rt);
    if (!host || rt->deps_activated) return;
    rt->deps_activated = 1;
    swift_ffi_host_activate_dependencies(host);
}

// ---- Low-level engine seam (Apple `WasmRuntime` conformance) ----

int iso_wamr_call(IsoWamr *rt, const char *name, const IsoWamrValue *args,
                  size_t nargs, IsoWamrValue *out) {
    if (!rt) return 0;
    wasm_function_inst_t fn = wasm_runtime_lookup_function(rt->inst, name);
    if (!fn || nargs > 8) {
        if (rt->cb.on_log) {
            char line[256];
            int n = snprintf(line, sizeof line, "[wamr] call %s refused: %s", name,
                             fn ? "more than 8 arguments" : "no such export");
            if (n > 0) rt->cb.on_log(rt->cb.ctx, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
        }
        return 0;
    }
    // Pack into WAMR's flat uint32 slot array (f64 = two little-endian slots).
    uint32_t argv[16];
    uint32_t argc = 0;
    for (size_t i = 0; i < nargs; i++) {
        if (args[i].is_f64) {
            memcpy(&argv[argc], &args[i].v.f64, sizeof(double));
            argc += 2;
        } else {
            argv[argc++] = (uint32_t)args[i].v.i32;
        }
    }
    if (!wasm_runtime_call_wasm(rt->exec_env, fn, argc, argv)) {
        // Say why: a trap, or a call refused because an earlier one left the
        // instance with an exception (WAMR answers every later call the
        // same) — otherwise the caller sees only "no result".
        const char *exception = wasm_runtime_get_exception(rt->inst);
        if (rt->cb.on_log) {
            char line[512];
            int n = snprintf(line, sizeof line, "[wamr] call %s failed: %s", name,
                             exception ? exception : "(no exception)");
            if (n > 0) rt->cb.on_log(rt->cb.ctx, line, (size_t)(n < (int)sizeof line ? n : (int)sizeof line - 1));
        }
        return 0;
    }
    if (out && wasm_func_get_result_count(fn, rt->inst) >= 1) {
        out->is_f64 = 0;  // every iso_hot export that returns does so as i32
        out->v.i32 = (int32_t)argv[0];
        return 1;
    }
    return 0;
}

void iso_wamr_read_bytes(IsoWamr *rt, uint32_t ptr, uint32_t len, uint8_t *dst) {
    if (!rt || !wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    const void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(dst, p, len);
}

void iso_wamr_write_bytes(IsoWamr *rt, uint32_t ptr, const uint8_t *src, uint32_t len) {
    if (!rt || !wasm_runtime_validate_app_addr(rt->inst, ptr, len)) return;
    void *p = wasm_runtime_addr_app_to_native(rt->inst, ptr);
    if (p) memcpy(p, src, len);
}

void iso_wamr_destroy(IsoWamr *rt) {
    if (!rt) return;
    free(rt->raster_buf);
    if (rt->ffi_host) swift_ffi_host_destroy(rt->ffi_host);
    if (rt->exec_env) wasm_runtime_destroy_exec_env(rt->exec_env);
    if (rt->inst) wasm_runtime_deinstantiate(rt->inst);
    if (rt->module) wasm_runtime_unload(rt->module);
    if (!rt->wasm_borrowed) free(rt->wasm);
    // Balance the ref this instance took on the global runtime (only instances
    // that got past global init are counted); the last one tears it down.
    if (rt->counted && --g_wamr_refcount == 0) {
        wasm_runtime_unregister_natives("iso_hot", g_iso_hot_natives);
        wasm_runtime_unregister_natives("iso_gpu", g_iso_gpu_natives);
        if (g_swift_ffi_native_count > 0)
            wasm_runtime_unregister_natives("swift_ffi", g_swift_ffi_natives);
        wasm_runtime_destroy();
    }
    free(rt);
}
