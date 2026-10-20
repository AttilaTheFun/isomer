// JNI shim: exposes the WAMR C host (//shared/wamr_host) to Kotlin, so
// Android's `WasmView` runs a wasm feature reactor with NO compiled Swift in the
// app (the WAMR interpreter is C; the Swift stdlib lives once, inside the
// bundle). The Kotlin peer is dev.isomer.runtime.WamrBridge.
//
// A `WamrHost` Kotlin object is held via a JNI global ref; the reactor's
// callbacks (render tree, schedule-render, generic dependency dispatch) cross
// back up to it. The layer is app-agnostic: the app's dependency table crosses
// as (key, ordinal, lazy) triples whose method calls are forwarded to Kotlin
// as opaque blobs (`dispatchDependency`), and app exports are reached through
// the generic `nativeFfiCall`.
#include <jni.h>
#include <android/log.h>
#include <stdlib.h>
#include <string.h>

#include "iso_wamr.h"

// Per-instance callback context: the JVM + a global ref to the Kotlin host and
// its cached method ids.
typedef struct {
    JavaVM *vm;
    jobject host;  // global ref to a dev.isomer.runtime.WamrHost
    jmethodID render_tree;   // (byte[]) -> void
    jmethodID schedule;      // () -> void
    jmethodID log;           // (String) -> void
    jmethodID measure_text;  // (String, double, int, double) -> double[]
    jmethodID rasterize;     // (String) -> byte[]
    jmethodID dispatch_dep;  // (int, byte[]) -> byte[]
    jmethodID schedule_jobs; // () -> void
} HostCtx;

// The GPU reactor's native GL binding (iso_wamr_gles.c), installed once per
// process before the first iso_wamr_create.
extern int iso_wamr_register_gles_natives(void);

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)vm;
    (void)reserved;
    iso_wamr_set_extra_natives(iso_wamr_register_gles_natives);
    return JNI_VERSION_1_6;
}

// Attach the current thread to the JVM (reactor callbacks fire on whatever
// thread drives iso_wamr_*; on Android that's the main thread, already
// attached, but be safe). Returns whether we attached (and must detach).
static JNIEnv *attach(HostCtx *c, int *did_attach) {
    JNIEnv *env = NULL;
    *did_attach = 0;
    if ((*c->vm)->GetEnv(c->vm, (void **)&env, JNI_VERSION_1_6) == JNI_EDETACHED) {
        (*c->vm)->AttachCurrentThread(c->vm, &env, NULL);
        *did_attach = 1;
    }
    return env;
}

static void cb_tree(void *ctx, const uint8_t *bytes, size_t len) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    jbyteArray arr = (*env)->NewByteArray(env, (jsize)len);
    if (arr) {
        (*env)->SetByteArrayRegion(env, arr, 0, (jsize)len, (const jbyte *)bytes);
        (*env)->CallVoidMethod(env, c->host, c->render_tree, arr);
        (*env)->DeleteLocalRef(env, arr);
    }
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

static void cb_schedule(void *ctx) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    (*env)->CallVoidMethod(env, c->host, c->schedule);
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

// The guest queued Swift concurrency jobs: Kotlin posts nativeRunJobs on the
// main thread (the thread that drives the runtime).
static void cb_schedule_jobs(void *ctx) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    if (c->schedule_jobs) (*env)->CallVoidMethod(env, c->host, c->schedule_jobs);
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

static void cb_log(void *ctx, const char *msg, size_t len) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    char *z = (char *)malloc(len + 1);
    if (z) {
        memcpy(z, msg, len);
        z[len] = '\0';
        jstring s = (*env)->NewStringUTF(env, z);
        (*env)->CallVoidMethod(env, c->host, c->log, s);
        (*env)->DeleteLocalRef(env, s);
        free(z);
    }
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

static jstring utf(JNIEnv *env, const char *b, size_t n) {
    char *z = (char *)malloc(n + 1);
    if (!z) return NULL;
    memcpy(z, b, n);
    z[n] = '\0';
    jstring s = (*env)->NewStringUTF(env, z);
    free(z);
    return s;
}

// iso_gpu.measure_text: Kotlin measures on its text stack (Paint), returning
// double[2] {width, height} in points.
static void cb_measure_text(void *ctx, const char *text, size_t len,
                            double font_size, int32_t weight, double wrap_width,
                            double out_wh[2]) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    jstring s = utf(env, text, len);
    if (s) {
        jdoubleArray arr = (jdoubleArray)(*env)->CallObjectMethod(
            env, c->host, c->measure_text, s, (jdouble)font_size, (jint)weight,
            (jdouble)wrap_width);
        if (arr && (*env)->GetArrayLength(env, arr) >= 2) {
            (*env)->GetDoubleArrayRegion(env, arr, 0, 2, out_wh);
        }
        if (arr) (*env)->DeleteLocalRef(env, arr);
        (*env)->DeleteLocalRef(env, s);
    }
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

// iso_gpu.raster_begin: Kotlin rasterizes the spec (text/gradient/shadow) to
// [w u32][h u32][RGBA8...]; returns a malloc'd copy the C host frees.
static uint8_t *cb_rasterize(void *ctx, const char *spec, size_t len, size_t *out_len) {
    HostCtx *c = (HostCtx *)ctx;
    int det;
    *out_len = 0;
    JNIEnv *env = attach(c, &det);
    if (!env) return NULL;
    uint8_t *result = NULL;
    jstring s = utf(env, spec, len);
    if (s) {
        jbyteArray arr = (jbyteArray)(*env)->CallObjectMethod(env, c->host, c->rasterize, s);
        if (arr) {
            jsize n = (*env)->GetArrayLength(env, arr);
            if (n > 0) {
                result = (uint8_t *)malloc((size_t)n);
                if (result) {
                    (*env)->GetByteArrayRegion(env, arr, 0, n, (jbyte *)result);
                    *out_len = (size_t)n;
                }
            }
            (*env)->DeleteLocalRef(env, arr);
        }
        (*env)->DeleteLocalRef(env, s);
    }
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
    return result;
}

// One registered dependency's dispatch context: the instance + its index in
// the Kotlin-side table (dispatch crosses by index; keys live in C for
// dependency_get, in Kotlin for routing). An app's own and WasmView's
// (Foundation's networking, WasmNetworkHosts.kt) share the table; entries
// past the limit are dropped.
#define ISO_JNI_MAX_DEPS 16

// A live instance = the C runtime + its host callback context. We hand Kotlin
// the pointer to this pair.
typedef struct Instance Instance;
typedef struct {
    Instance *inst;
    int index;
} DepCtx;

struct Instance {
    IsoWamr *rt;
    HostCtx ctx;
    char *ffi_prefix;                 // owned copy handed to cb.ffi_prefix
    DepCtx dep_ctx[ISO_JNI_MAX_DEPS];
    char *dep_keys[ISO_JNI_MAX_DEPS];             // owned copies
    char *dep_registry_keys[ISO_JNI_MAX_DEPS];    // owned copies
    char *dep_register_symbols[ISO_JNI_MAX_DEPS]; // owned copies
    size_t dep_count;
};

// Copies one element of a Java String[] into a fresh C string (never NULL).
static char *iso_jni_string_at(JNIEnv *env, jobjectArray array, jsize i) {
    if (!array) return strdup("");
    jstring s = (jstring)(*env)->GetObjectArrayElement(env, array, i);
    const char *c = s ? (*env)->GetStringUTFChars(env, s, NULL) : NULL;
    char *copy = strdup(c ? c : "");
    if (c) (*env)->ReleaseStringUTFChars(env, s, c);
    if (s) (*env)->DeleteLocalRef(env, s);
    return copy;
}

// Generic dependency dispatch: forward the ordinal-led argument blob to
// Kotlin (`dispatchDependency(index, args)`) and write the returned result
// blob to the writer.
static void jni_dep_dispatch(void *ctx, const uint8_t *args, size_t args_len,
                             SwiftFFIBlobWriter *out) {
    DepCtx *d = (DepCtx *)ctx;
    HostCtx *c = &d->inst->ctx;
    int det;
    JNIEnv *env = attach(c, &det);
    if (!env) return;
    jbyteArray in = (*env)->NewByteArray(env, (jsize)args_len);
    if (in) {
        (*env)->SetByteArrayRegion(env, in, 0, (jsize)args_len, (const jbyte *)args);
        jbyteArray result = (jbyteArray)(*env)->CallObjectMethod(
            env, c->host, c->dispatch_dep, (jint)d->index, in);
        if (result) {
            jsize n = (*env)->GetArrayLength(env, result);
            if (n > 0) {
                jbyte *bytes = (*env)->GetByteArrayElements(env, result, NULL);
                if (bytes) {
                    swift_ffi_blob_w_raw(out, bytes, (size_t)n);
                    (*env)->ReleaseByteArrayElements(env, result, bytes, JNI_ABORT);
                }
            }
            (*env)->DeleteLocalRef(env, result);
        }
        (*env)->DeleteLocalRef(env, in);
    }
    if (det) (*c->vm)->DetachCurrentThread(c->vm);
}

JNIEXPORT jlong JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeCreate(
    JNIEnv *env, jobject thiz, jbyteArray wasm, jobject host, jstring ffi_prefix,
    jobjectArray dep_keys, jobjectArray dep_registry_keys,
    jobjectArray dep_register_symbols, jbooleanArray dep_lazy) {
    (void)thiz;
    Instance *inst = (Instance *)calloc(1, sizeof(Instance));
    if (!inst) return 0;
    (*env)->GetJavaVM(env, &inst->ctx.vm);
    inst->ctx.host = (*env)->NewGlobalRef(env, host);

    jclass hc = (*env)->GetObjectClass(env, host);
    inst->ctx.render_tree = (*env)->GetMethodID(env, hc, "renderTree", "([B)V");
    inst->ctx.schedule = (*env)->GetMethodID(env, hc, "scheduleRender", "()V");
    inst->ctx.log = (*env)->GetMethodID(env, hc, "log", "(Ljava/lang/String;)V");
    inst->ctx.measure_text =
        (*env)->GetMethodID(env, hc, "measureText", "(Ljava/lang/String;DID)[D");
    inst->ctx.rasterize = (*env)->GetMethodID(env, hc, "rasterize", "(Ljava/lang/String;)[B");
    inst->ctx.dispatch_dep = (*env)->GetMethodID(env, hc, "dispatchDependency", "(I[B)[B");
    inst->ctx.schedule_jobs = (*env)->GetMethodID(env, hc, "scheduleJobs", "()V");

    if (ffi_prefix) {
        const char *p = (*env)->GetStringUTFChars(env, ffi_prefix, NULL);
        if (p) {
            inst->ffi_prefix = strdup(p);
            (*env)->ReleaseStringUTFChars(env, ffi_prefix, p);
        }
    }

    IsoWamrCallbacks cb = {0};
    cb.ctx = &inst->ctx;
    cb.on_tree = cb_tree;
    cb.on_schedule_render = cb_schedule;
    cb.on_schedule_jobs = cb_schedule_jobs;
    cb.on_log = cb_log;
    cb.measure_text = cb_measure_text;
    cb.rasterize = cb_rasterize;
    cb.ffi_prefix = inst->ffi_prefix;

    jsize n = (*env)->GetArrayLength(env, wasm);
    jbyte *bytes = (*env)->GetByteArrayElements(env, wasm, NULL);
    char err[256] = {0};
    inst->rt = iso_wamr_create((const uint8_t *)bytes, (size_t)n, cb, err, sizeof(err));
    (*env)->ReleaseByteArrayElements(env, wasm, bytes, JNI_ABORT);

    if (!inst->rt) {
        (*env)->DeleteGlobalRef(env, inst->ctx.host);
        free(inst->ffi_prefix);
        free(inst);
        // Surface the error to Kotlin via the log callback path is gone; throw.
        jclass ex = (*env)->FindClass(env, "java/lang/RuntimeException");
        if (ex) (*env)->ThrowNew(env, ex, err[0] ? err : "WAMR create failed");
        return 0;
    }

    // Register the app's dependency table with the generic C host (dispatch
    // forwards to Kotlin by index; iso_wamr_start activates the dictionary).
    if (dep_keys && iso_wamr_ffi_host(inst->rt)) {
        jsize count = (*env)->GetArrayLength(env, dep_keys);
        if (count > ISO_JNI_MAX_DEPS) count = ISO_JNI_MAX_DEPS;
        jboolean *lazies = (*env)->GetBooleanArrayElements(env, dep_lazy, NULL);
        SwiftFFIHostDependency deps[ISO_JNI_MAX_DEPS];
        for (jsize i = 0; i < count; i++) {
            inst->dep_keys[i] = iso_jni_string_at(env, dep_keys, i);
            inst->dep_registry_keys[i] = iso_jni_string_at(env, dep_registry_keys, i);
            inst->dep_register_symbols[i] = iso_jni_string_at(env, dep_register_symbols, i);
            inst->dep_ctx[i].inst = inst;
            inst->dep_ctx[i].index = (int)i;
            deps[i].key = inst->dep_keys[i];
            deps[i].registry_key = inst->dep_registry_keys[i];
            deps[i].register_symbol = inst->dep_register_symbols[i];
            deps[i].lazy = (lazies && lazies[i]) ? 1 : 0;
            deps[i].ctx = &inst->dep_ctx[i];
            deps[i].dispatch = jni_dep_dispatch;
        }
        inst->dep_count = (size_t)count;
        swift_ffi_host_set_dependencies(iso_wamr_ffi_host(inst->rt), deps, (size_t)count);
        if (lazies) (*env)->ReleaseBooleanArrayElements(env, dep_lazy, lazies, JNI_ABORT);
    }
    return (jlong)(intptr_t)inst;
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeStart(
    JNIEnv *env, jobject thiz, jlong handle, jdouble w, jdouble h) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_start(inst->rt, w, h);
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeRender(
    JNIEnv *env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_render(inst->rt);
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeSetColorScheme(
    JNIEnv *env, jobject thiz, jlong handle, jboolean dark) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_set_color_scheme(inst->rt, dark ? 1 : 0);
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeResize(
    JNIEnv *env, jobject thiz, jlong handle, jdouble w, jdouble h) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_resize(inst->rt, w, h);
}

// Generic app-export call: `<prefix><suffix>(scalars..., [stagedPtr, stagedLen])`
// with an optional byte payload staged through the reactor's allocator, then a
// re-render (the shape of any async completion delivery). App-agnostic: which
// export and what the scalars mean belong to the app's Kotlin.
JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeFfiCall(
    JNIEnv *env, jobject thiz, jlong handle, jstring suffix, jintArray scalars,
    jbyteArray payload) {
    (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (!inst) return;
    SwiftFFIHostRuntime *frt = iso_wamr_ffi_host(inst->rt);
    if (!frt) return;
    SwiftFFIScalar args[8];
    size_t nargs = 0;
    if (scalars) {
        jsize count = (*env)->GetArrayLength(env, scalars);
        jint *values = (*env)->GetIntArrayElements(env, scalars, NULL);
        for (jsize i = 0; i < count && nargs < 6; i++) {
            args[nargs++] = swift_ffi_i32((int32_t)values[i]);
        }
        (*env)->ReleaseIntArrayElements(env, scalars, values, JNI_ABORT);
    }
    uint32_t staged_ptr = 0;
    if (payload) {
        jsize len = (*env)->GetArrayLength(env, payload);
        jbyte *bytes = (*env)->GetByteArrayElements(env, payload, NULL);
        uint32_t staged_len = 0;
        staged_ptr = swift_ffi_host_stage_bytes(frt, (const uint8_t *)bytes,
                                                (size_t)len, &staged_len);
        (*env)->ReleaseByteArrayElements(env, payload, bytes, JNI_ABORT);
        args[nargs++] = swift_ffi_i32((int32_t)staged_ptr);
        args[nargs++] = swift_ffi_i32((int32_t)staged_len);
    }
    const char *suffix_c = (*env)->GetStringUTFChars(env, suffix, NULL);
    if (suffix_c) {
        swift_ffi_host_call(frt, suffix_c, args, nargs, NULL);
        (*env)->ReleaseStringUTFChars(env, suffix, suffix_c);
    }
    if (staged_ptr) swift_ffi_host_dealloc(frt, staged_ptr);
    iso_wamr_render(inst->rt);
}

// Drain the guest's queued Swift concurrency jobs (see cb_schedule_jobs) and
// render when any ran.
JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeRunJobs(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_run_jobs(inst->rt);
}

JNIEXPORT jlong JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeNextJobDelayMs(JNIEnv *env, jobject thiz, jlong handle) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    return inst ? (jlong)iso_wamr_next_job_delay_ms(inst->rt) : -1;
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeSurfaceChanged(
    JNIEnv *env, jobject thiz, jlong handle, jint width_px, jint height_px, jdouble density) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (inst) iso_wamr_surface_changed(inst->rt, width_px, height_px, density);
}

JNIEXPORT jint JNICALL
Java_dev_isomer_runtime_WamrBridge_nativePointer(
    JNIEnv *env, jobject thiz, jlong handle, jint kind, jdouble x, jdouble y) {
    (void)env; (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    return inst ? iso_wamr_pointer(inst->rt, kind, x, y) : 0;
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeEvent(
    JNIEnv *env, jobject thiz, jlong handle, jstring id, jstring value) {
    (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (!inst) return;
    const char *id_c = (*env)->GetStringUTFChars(env, id, NULL);
    const char *val_c = (*env)->GetStringUTFChars(env, value, NULL);
    iso_wamr_event(inst->rt, id_c, strlen(id_c), val_c, strlen(val_c));
    (*env)->ReleaseStringUTFChars(env, id, id_c);
    (*env)->ReleaseStringUTFChars(env, value, val_c);
}

JNIEXPORT void JNICALL
Java_dev_isomer_runtime_WamrBridge_nativeDestroy(
    JNIEnv *env, jobject thiz, jlong handle) {
    (void)thiz;
    Instance *inst = (Instance *)(intptr_t)handle;
    if (!inst) return;
    iso_wamr_destroy(inst->rt);
    if (inst->ctx.host) (*env)->DeleteGlobalRef(env, inst->ctx.host);
    for (size_t i = 0; i < inst->dep_count; i++) {
        free(inst->dep_keys[i]);
        free(inst->dep_registry_keys[i]);
        free(inst->dep_register_symbols[i]);
    }
    free(inst->ffi_prefix);
    free(inst);
}
