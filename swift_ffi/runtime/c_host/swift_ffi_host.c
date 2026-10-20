// The C host runtime — see swift_ffi_host.h. A faithful, synchronous-subset port
// of SwiftFFIHostRuntime (swift_ffi/runtime/swift_wasm_host): string/byte
// staging over the reactor's allocator and a foreign-object registry, driven by
// an injected engine vtable.

#include "swift_ffi_host.h"

#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <time.h>
#endif

/* Milliseconds on a clock that only moves forward. */
static int64_t swift_ffi_host_now_ms(void) {
#ifdef _WIN32
    return (int64_t)GetTickCount64();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
}

// One parked dispatcher (closures, foreign objects, injected dependencies
// all cross the one `closure_invoke` channel).
typedef struct {
    void *ctx;
    SwiftFFIHostDispatch dispatch;
} SwiftFFIHostForeignEntry;

struct SwiftFFIHostRuntime {
    /* Queued Swift concurrency jobs (task_enqueue) + the host's drain hook. */
    uint32_t *jobs;
    size_t job_count, job_cap;
    SwiftFFIHostJobScheduler job_scheduler;
    void *job_user;
    /* Timed jobs (task_enqueue_after): each with the time it is due. */
    struct { uint32_t job; int64_t due_ms; } *timed;
    size_t timed_count, timed_cap;

    SwiftFFIEngine engine;

    // Foreign registry: id -> dispatcher. Slot i holds foreign id (i+1); a
    // NULL dispatch is a released entry. Ids are never reused (monotonic),
    // matching the Swift peer's `nextForeignID`.
    SwiftFFIHostForeignEntry *foreign;
    int32_t foreign_count;  // number of slots (== highest id issued)

    // The installed dependency table (owned copies; keys strdup'd).
    SwiftFFIHostDependency *deps;
    size_t dep_count;
};

SwiftFFIHostRuntime *swift_ffi_host_create(const SwiftFFIEngine *engine) {
    if (!engine) return NULL;
    SwiftFFIHostRuntime *rt = (SwiftFFIHostRuntime *)calloc(1, sizeof(*rt));
    if (!rt) return NULL;
    rt->engine = *engine;
    return rt;
}

void swift_ffi_host_destroy(SwiftFFIHostRuntime *rt) {
    if (!rt) return;
    free(rt->jobs);
    free(rt->timed);
    for (size_t i = 0; i < rt->dep_count; i++) {
        free((char *)rt->deps[i].key);
        free((char *)rt->deps[i].registry_key);
        free((char *)rt->deps[i].register_symbol);
    }
    free(rt->deps);
    free(rt->foreign);
    free(rt);
}

int swift_ffi_host_call(SwiftFFIHostRuntime *rt, const char *name,
                        const SwiftFFIScalar *args, size_t nargs,
                        SwiftFFIScalar *out) {
    SwiftFFIScalar result;
    int has_result = 0;
    int ok = rt->engine.call(rt->engine.ctx, name, args, nargs, &result, &has_result);
    if (ok && has_result && out) *out = result;
    return ok && has_result;
}

uint32_t swift_ffi_host_alloc(SwiftFFIHostRuntime *rt, size_t count) {
    if (count == 0) return 0;
    SwiftFFIScalar arg = swift_ffi_i32((int32_t)count), out;
    if (!swift_ffi_host_call(rt, "swift_ffi_alloc", &arg, 1, &out)) return 0;
    return swift_ffi_scalar_u32(out);
}

void swift_ffi_host_dealloc(SwiftFFIHostRuntime *rt, uint32_t ptr) {
    if (ptr == 0) return;
    SwiftFFIScalar arg = swift_ffi_i32((int32_t)ptr);
    swift_ffi_host_call(rt, "swift_ffi_dealloc", &arg, 1, NULL);
}

uint32_t swift_ffi_host_stage_bytes(SwiftFFIHostRuntime *rt, const uint8_t *bytes,
                                    size_t len, uint32_t *out_len) {
    if (out_len) *out_len = (uint32_t)len;
    if (len == 0) return 0;
    uint32_t ptr = swift_ffi_host_alloc(rt, len);
    if (ptr == 0) {
        if (out_len) *out_len = 0;
        return 0;
    }
    rt->engine.write_bytes(rt->engine.ctx, ptr, bytes, (uint32_t)len);
    return ptr;
}

char *swift_ffi_host_foreign_string(SwiftFFIHostRuntime *rt, uint32_t ptr,
                                    uint32_t len, size_t *out_len) {
    if (out_len) *out_len = len;
    char *s = (char *)malloc((size_t)len + 1);
    if (!s) return NULL;
    if (len > 0) rt->engine.read_bytes(rt->engine.ctx, ptr, len, (uint8_t *)s);
    s[len] = '\0';
    return s;
}

char *swift_ffi_host_take_string(SwiftFFIHostRuntime *rt, uint32_t handle) {
    SwiftFFIScalar harg = swift_ffi_i32((int32_t)handle);
    if (handle == 0) {
        char *empty = (char *)malloc(1);
        if (empty) empty[0] = '\0';
        return empty;
    }
    // string_len(handle) -> byte length.
    SwiftFFIScalar lenout;
    uint32_t len = 0;
    if (swift_ffi_host_call(rt, "swift_ffi_string_len", &harg, 1, &lenout))
        len = swift_ffi_scalar_u32(lenout);

    char *s = (char *)malloc((size_t)len + 1);
    if (!s) {
        swift_ffi_host_call(rt, "swift_ffi_string_release", &harg, 1, NULL);
        return NULL;
    }
    if (len > 0) {
        // string_copy(handle, dst) writes the bytes into guest memory at dst.
        uint32_t ptr = swift_ffi_host_alloc(rt, len);
        if (ptr) {
            SwiftFFIScalar cargs[2] = {harg, swift_ffi_i32((int32_t)ptr)};
            swift_ffi_host_call(rt, "swift_ffi_string_copy", cargs, 2, NULL);
            rt->engine.read_bytes(rt->engine.ctx, ptr, len, (uint8_t *)s);
            swift_ffi_host_dealloc(rt, ptr);
        }
    }
    s[len] = '\0';
    swift_ffi_host_call(rt, "swift_ffi_string_release", &harg, 1, NULL);
    return s;
}

int32_t swift_ffi_host_register_foreign(SwiftFFIHostRuntime *rt, void *ctx,
                                        SwiftFFIHostDispatch dispatch) {
    int32_t id = rt->foreign_count + 1;  // 1-based, matches the Swift peer
    SwiftFFIHostForeignEntry *grown = (SwiftFFIHostForeignEntry *)realloc(
        rt->foreign, (size_t)id * sizeof(SwiftFFIHostForeignEntry));
    if (!grown) return 0;
    rt->foreign = grown;
    rt->foreign[id - 1].ctx = ctx;
    rt->foreign[id - 1].dispatch = dispatch;
    rt->foreign_count = id;
    return id;
}

void swift_ffi_host_release_foreign(SwiftFFIHostRuntime *rt, int32_t id) {
    if (id <= 0 || id > rt->foreign_count) return;
    rt->foreign[id - 1].ctx = NULL;
    rt->foreign[id - 1].dispatch = NULL;
}

/* --- Blob codec (dependency-injection dispatch) -------------------------- */

int32_t swift_ffi_blob_header(SwiftFFIBlobReader *r, int32_t *aux_out) {
    if (r->off + 8 > r->len) { if (aux_out) *aux_out = 0; return -1; }
    int32_t tag, aux;
    memcpy(&tag, r->data + r->off, 4);
    memcpy(&aux, r->data + r->off + 4, 4);
    r->off += 8;
    if (aux_out) *aux_out = aux;
    return tag;
}

int64_t swift_ffi_blob_i64(SwiftFFIBlobReader *r) {
    if (r->off + 8 > r->len) return 0;
    int64_t v;
    memcpy(&v, r->data + r->off, 8);
    r->off += 8;
    return v;
}

char *swift_ffi_blob_bytes(SwiftFFIBlobReader *r, size_t *len_out) {
    int64_t len = swift_ffi_blob_i64(r);
    if (len < 0 || r->off + (size_t)len > r->len) len = 0;
    char *copy = (char *)malloc((size_t)len + 1);
    if (!copy) return NULL;
    if (len > 0) memcpy(copy, r->data + r->off, (size_t)len);
    copy[len] = '\0';
    r->off += (size_t)len;
    if (len_out) *len_out = (size_t)len;
    return copy;
}

static void swift_ffi_blob_grow(SwiftFFIBlobWriter *w, size_t extra) {
    if (w->len + extra <= w->cap) return;
    size_t cap = w->cap ? w->cap * 2 : 64;
    while (cap < w->len + extra) cap *= 2;
    w->data = (uint8_t *)realloc(w->data, cap);
    w->cap = cap;
}

void swift_ffi_blob_w_raw(SwiftFFIBlobWriter *w, const void *bytes, size_t len) {
    swift_ffi_blob_grow(w, len);
    memcpy(w->data + w->len, bytes, len);
    w->len += len;
}

void swift_ffi_blob_w_i32(SwiftFFIBlobWriter *w, int32_t v) { swift_ffi_blob_w_raw(w, &v, 4); }
void swift_ffi_blob_w_i64(SwiftFFIBlobWriter *w, int64_t v) { swift_ffi_blob_w_raw(w, &v, 8); }

void swift_ffi_blob_w_header(SwiftFFIBlobWriter *w, int32_t tag, int32_t aux) {
    swift_ffi_blob_w_i32(w, tag);
    swift_ffi_blob_w_i32(w, aux);
}

void swift_ffi_blob_w_void(SwiftFFIBlobWriter *w) { swift_ffi_blob_w_header(w, 0, 0); }

void swift_ffi_blob_w_int(SwiftFFIBlobWriter *w, int64_t v) {
    swift_ffi_blob_w_header(w, 1, 0);
    swift_ffi_blob_w_i64(w, v);
}

void swift_ffi_blob_w_int32v(SwiftFFIBlobWriter *w, int32_t v) {
    swift_ffi_blob_w_header(w, 2, 0);
    swift_ffi_blob_w_i64(w, (int64_t)v);
}

void swift_ffi_blob_w_bool(SwiftFFIBlobWriter *w, int v) {
    swift_ffi_blob_w_header(w, 4, 0);
    swift_ffi_blob_w_i64(w, v ? 1 : 0);
}

void swift_ffi_blob_w_double(SwiftFFIBlobWriter *w, double v) {
    int64_t bits;
    memcpy(&bits, &v, 8);
    swift_ffi_blob_w_header(w, 3, 0);
    swift_ffi_blob_w_i64(w, bits);
}

void swift_ffi_blob_w_string(SwiftFFIBlobWriter *w, const char *utf8) {
    size_t len = utf8 ? strlen(utf8) : 0;
    swift_ffi_blob_w_header(w, 5, 0);
    swift_ffi_blob_w_i64(w, (int64_t)len);
    if (len) swift_ffi_blob_w_raw(w, utf8, len);
}

/* --- Dependency injection (generic host half; see the header) ------------ */

static char *swift_ffi_host_strdup(const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    char *copy = (char *)malloc(len + 1);
    if (copy) memcpy(copy, s, len + 1);
    return copy;
}

void swift_ffi_host_set_dependencies(SwiftFFIHostRuntime *rt,
                                     const SwiftFFIHostDependency *deps,
                                     size_t count) {
    if (!rt) return;
    for (size_t i = 0; i < rt->dep_count; i++) {
        free((char *)rt->deps[i].key);
        free((char *)rt->deps[i].registry_key);
        free((char *)rt->deps[i].register_symbol);
    }
    free(rt->deps);
    rt->deps = NULL;
    rt->dep_count = 0;
    if (!deps || count == 0) return;
    rt->deps = (SwiftFFIHostDependency *)calloc(count, sizeof(*deps));
    if (!rt->deps) return;
    for (size_t i = 0; i < count; i++) {
        rt->deps[i] = deps[i];
        rt->deps[i].key = swift_ffi_host_strdup(deps[i].key);
        rt->deps[i].registry_key = swift_ffi_host_strdup(deps[i].registry_key);
        rt->deps[i].register_symbol = swift_ffi_host_strdup(deps[i].register_symbol);
    }
    rt->dep_count = count;
}

void swift_ffi_host_activate_dependencies(SwiftFFIHostRuntime *rt) {
    if (!rt) return;
    for (size_t i = 0; i < rt->dep_count; i++) {
        const char *symbol = rt->deps[i].register_symbol;
        if (!symbol) continue;
        int seen = 0;
        for (size_t j = 0; j < i && !seen; j++) {
            if (rt->deps[j].register_symbol &&
                strcmp(rt->deps[j].register_symbol, symbol) == 0) {
                seen = 1;
            }
        }
        if (!seen) swift_ffi_host_call(rt, symbol, NULL, 0, NULL);
    }
}

/* closure_invoke: run a registered dispatcher with the guest's argument blob;
 * the result blob is staged into wasm memory and returned packed as
 * (len << 32) | ptr. */
static void swift_ffi_disp_closure_invoke(void *user, const SwiftFFIScalar *args,
                                          size_t nargs, SwiftFFIScalar *out,
                                          int *has_result) {
    (void)nargs;
    SwiftFFIHostRuntime *rt = (SwiftFFIHostRuntime *)user;
    out->kind = SWIFT_FFI_I64;
    out->value.i64 = 0;
    *has_result = 1;
    int32_t id = args[0].value.i32;
    if (id <= 0 || id > rt->foreign_count || !rt->foreign[id - 1].dispatch) return;
    SwiftFFIHostForeignEntry entry = rt->foreign[id - 1];
    size_t args_len = (size_t)swift_ffi_scalar_u32(args[2]);
    char *raw = swift_ffi_host_foreign_string(rt, swift_ffi_scalar_u32(args[1]),
                                              swift_ffi_scalar_u32(args[2]), NULL);
    if (!raw) return;
    SwiftFFIBlobWriter w;
    memset(&w, 0, sizeof w);
    entry.dispatch(entry.ctx, (const uint8_t *)raw, args_len, &w);
    free(raw);
    uint32_t ptr = swift_ffi_host_stage_bytes(rt, w.data, w.len, NULL);
    out->value.i64 = (int64_t)(((uint64_t)w.len << 32) | (uint64_t)ptr);
    free(w.data);
}

/* dependency_get: resolve a key the guest looked up in its `dependencies`
 * dictionary. Returns 0 when absent, else a packed (len << 32) | ptr blob of
 * .list([.bool(lazy), .string(registry key), .int32(dispatcher id)]),
 * allocated in guest memory (the guest frees it). */
static void swift_ffi_disp_dependency_get(void *user, const SwiftFFIScalar *args,
                                          size_t nargs, SwiftFFIScalar *out,
                                          int *has_result) {
    (void)nargs;
    SwiftFFIHostRuntime *rt = (SwiftFFIHostRuntime *)user;
    out->kind = SWIFT_FFI_I64;
    out->value.i64 = 0;
    *has_result = 1;
    char *key = swift_ffi_host_foreign_string(rt, swift_ffi_scalar_u32(args[0]),
                                              swift_ffi_scalar_u32(args[1]), NULL);
    if (!key) return;
    for (size_t i = 0; i < rt->dep_count; i++) {
        if (strcmp(rt->deps[i].key, key) != 0) continue;
        int32_t id = swift_ffi_host_register_foreign(rt, rt->deps[i].ctx,
                                                     rt->deps[i].dispatch);
        SwiftFFIBlobWriter w;
        memset(&w, 0, sizeof w);
        swift_ffi_blob_w_header(&w, 8, 0); /* LIST */
        swift_ffi_blob_w_i64(&w, 3);
        swift_ffi_blob_w_bool(&w, rt->deps[i].lazy);
        swift_ffi_blob_w_string(&w, rt->deps[i].registry_key);
        swift_ffi_blob_w_int32v(&w, id);
        uint32_t ptr = swift_ffi_host_stage_bytes(rt, w.data, w.len, NULL);
        out->value.i64 = (int64_t)(((uint64_t)w.len << 32) | (uint64_t)ptr);
        free(w.data);
        break;
    }
    free(key);
}

static void swift_ffi_disp_foreign_release(void *user, const SwiftFFIScalar *args,
                                           size_t nargs, SwiftFFIScalar *out,
                                           int *has_result) {
    (void)nargs;
    (void)out;
    swift_ffi_host_release_foreign((SwiftFFIHostRuntime *)user, args[0].value.i32);
    *has_result = 0;
}

/* task_enqueue: park the job; the host drains on its thread
 * (swift_ffi_host_run_jobs), told via the scheduler hook when the queue
 * becomes non-empty. async_complete stays a stub (no host-side facade awaits
 * here). */
static void swift_ffi_disp_task_enqueue(void *user, const SwiftFFIScalar *args,
                                        size_t nargs, SwiftFFIScalar *out,
                                        int *has_result) {
    (void)nargs; (void)out;
    SwiftFFIHostRuntime *rt = (SwiftFFIHostRuntime *)user;
    *has_result = 0;
    if (rt->job_count == rt->job_cap) {
        size_t cap = rt->job_cap ? rt->job_cap * 2 : 16;
        uint32_t *grown = (uint32_t *)realloc(rt->jobs, cap * sizeof(uint32_t));
        if (!grown) return;
        rt->jobs = grown;
        rt->job_cap = cap;
    }
    int was_empty = rt->job_count == 0;
    rt->jobs[rt->job_count++] = swift_ffi_scalar_u32(args[0]);
    if (was_empty && rt->job_scheduler) rt->job_scheduler(rt->job_user);
}

/* task_enqueue_after: park the job with the time it is due; the drain runs
 * it once that has passed. The scheduler is told, so the host can ask
 * swift_ffi_host_next_job_delay_ms when to drain. */
static void swift_ffi_disp_task_enqueue_after(void *user, const SwiftFFIScalar *args,
                                              size_t nargs, SwiftFFIScalar *out,
                                              int *has_result) {
    (void)nargs; (void)out;
    SwiftFFIHostRuntime *rt = (SwiftFFIHostRuntime *)user;
    *has_result = 0;
    if (rt->timed_count == rt->timed_cap) {
        size_t cap = rt->timed_cap ? rt->timed_cap * 2 : 16;
        void *grown = realloc(rt->timed, cap * sizeof(*rt->timed));
        if (!grown) return;
        rt->timed = grown;
        rt->timed_cap = cap;
    }
    int32_t delay = args[1].value.i32;
    rt->timed[rt->timed_count].job = swift_ffi_scalar_u32(args[0]);
    rt->timed[rt->timed_count].due_ms = swift_ffi_host_now_ms() + (delay > 0 ? delay : 0);
    rt->timed_count++;
    if (rt->job_scheduler) rt->job_scheduler(rt->job_user);
}

int64_t swift_ffi_host_next_job_delay_ms(SwiftFFIHostRuntime *rt) {
    if (!rt || rt->timed_count == 0) return -1;
    int64_t soonest = rt->timed[0].due_ms;
    for (size_t i = 1; i < rt->timed_count; i++)
        if (rt->timed[i].due_ms < soonest) soonest = rt->timed[i].due_ms;
    int64_t wait = soonest - swift_ffi_host_now_ms();
    return wait > 0 ? wait : 0;
}

void swift_ffi_host_set_job_scheduler(SwiftFFIHostRuntime *rt,
                                      SwiftFFIHostJobScheduler scheduler, void *user) {
    if (!rt) return;
    rt->job_scheduler = scheduler;
    rt->job_user = user;
}

size_t swift_ffi_host_run_jobs(SwiftFFIHostRuntime *rt) {
    if (!rt) return 0;
    size_t ran = 0;
    /* Timed jobs whose delay is up join the queue, soonest first. */
    int64_t now = swift_ffi_host_now_ms();
    for (;;) {
        size_t pick = rt->timed_count;
        for (size_t i = 0; i < rt->timed_count; i++)
            if (rt->timed[i].due_ms <= now && (pick == rt->timed_count || rt->timed[i].due_ms < rt->timed[pick].due_ms)) pick = i;
        if (pick == rt->timed_count) break;
        uint32_t job = rt->timed[pick].job;
        rt->timed[pick] = rt->timed[--rt->timed_count];
        SwiftFFIScalar arg = swift_ffi_i32((int32_t)job);
        swift_ffi_host_call(rt, "swift_ffi_task_run", &arg, 1, NULL);
        ran++;
    }
    while (rt->job_count > 0 && ran < 10000) {
        uint32_t job = rt->jobs[0];
        memmove(rt->jobs, rt->jobs + 1, (rt->job_count - 1) * sizeof(uint32_t));
        rt->job_count--;
        SwiftFFIScalar arg = swift_ffi_i32((int32_t)job);
        swift_ffi_host_call(rt, "swift_ffi_task_run", &arg, 1, NULL);
        ran++;
    }
    return ran;
}

void swift_ffi_host_async_resume(SwiftFFIHostRuntime *rt, int32_t call_id,
                                 const uint8_t *blob, size_t len) {
    if (!rt) return;
    uint32_t ptr = 0;
    if (blob && len > 0) ptr = swift_ffi_host_stage_bytes(rt, blob, len, NULL);
    SwiftFFIScalar args[3];
    args[0] = swift_ffi_i32(call_id);
    args[1] = swift_ffi_i32((int32_t)ptr);
    args[2] = swift_ffi_i32((int32_t)len);
    swift_ffi_host_call(rt, "swift_ffi_async_resume", args, 3, NULL);
    if (ptr) swift_ffi_host_dealloc(rt, ptr);
    swift_ffi_host_run_jobs(rt);
}

void swift_ffi_blob_w_error(SwiftFFIBlobWriter *w, const char *message) {
    size_t n = message ? strlen(message) : 0;
    swift_ffi_blob_w_header(w, 10, 0);
    swift_ffi_blob_w_i64(w, (int64_t)n);
    if (n) swift_ffi_blob_w_raw(w, message, n);
}

void swift_ffi_blob_w_string_list(SwiftFFIBlobWriter *w, const char *const *items, size_t count) {
    swift_ffi_blob_w_header(w, 8, 0);
    swift_ffi_blob_w_i64(w, (int64_t)count);
    for (size_t i = 0; i < count; i++) swift_ffi_blob_w_string(w, items[i] ? items[i] : "");
}

static void swift_ffi_disp_async_complete(void *user, const SwiftFFIScalar *args,
                                          size_t nargs, SwiftFFIScalar *out,
                                          int *has_result) {
    (void)user; (void)args; (void)nargs; (void)out;
    *has_result = 0;
}

size_t swift_ffi_host_standard_imports(SwiftFFIHostRuntime *rt,
                                       SwiftFFIHostImport out[SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT]) {
    if (!rt || !out) return 0;
    out[0].name = "closure_invoke";
    out[0].handler = swift_ffi_disp_closure_invoke;
    out[1].name = "dependency_get";
    out[1].handler = swift_ffi_disp_dependency_get;
    out[2].name = "foreign_release";
    out[2].handler = swift_ffi_disp_foreign_release;
    out[3].name = "task_enqueue";
    out[3].handler = swift_ffi_disp_task_enqueue;
    out[4].name = "async_complete";
    out[4].handler = swift_ffi_disp_async_complete;
    out[5].name = "task_enqueue_after";
    out[5].handler = swift_ffi_disp_task_enqueue_after;
    for (int i = 0; i < SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT; i++) out[i].user = rt;
    return SWIFT_FFI_HOST_STANDARD_IMPORT_COUNT;
}
