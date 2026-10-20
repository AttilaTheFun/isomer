// iso_wamr — a tiny C host that runs one Isomer `iso_hot` wasm reactor
// under the WAMR (wasm-micro-runtime) classic interpreter. It is the engine
// behind Android's "wasm" delivery cell: because WAMR is C (not Swift), the wasm
// feature ships with NO compiled Swift in the app — the Swift stdlib lives once,
// inside the bundle. (WAMR replaced wasm3, whose module LOAD was pathologically
// slow on Android — see MODULE.bazel's @wamr.)
//
// This layer is platform-neutral (a host smoke test drives it on macOS; a thin
// JNI shim drives it on Android). It binds the reactor's `iso_hot` render ABI
// and satisfies WASI, delivering the emitted render tree through callbacks.
//
// The swift_ffi transport here is fully GENERIC: iso_wamr supplies the WAMR
// SwiftFFIEngine, a raw import trampoline, and the runtime's FIXED standard
// import set (closure_invoke / dependency_get / foreign_release /
// task_enqueue / task_enqueue_after / async_complete), enabled when `ffi_prefix` is non-NULL
// (the value itself is unused since swift_ffi v3 — import names are fixed).
// Everything module-specific — the
// dependency table, its typed dispatch adapters, export calls like a fetch
// completion — belongs to the EMBEDDING APP, which reaches the runtime via
// iso_wamr_ffi_host() (typically with its generated `<module>_c_host.h`).
#ifndef ISO_WAMR_H
#define ISO_WAMR_H

#include <stddef.h>
#include <stdint.h>

#include "swift_ffi_host.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IsoWamr IsoWamr;

// Host callbacks the reactor drives. `ctx` is passed back to each. All fire
// synchronously on the thread that calls the iso_wamr_* entry points.
typedef struct {
    void *ctx;
    // The reactor pushed a fresh serialized render tree (tree.fbs).
    void (*on_tree)(void *ctx, const uint8_t *bytes, size_t len);
    // Guest log(...) output (may be NULL).
    void (*on_log)(void *ctx, const char *msg, size_t len);
    // "Schedule a frame soon" — the guest asked for a render (may be NULL). The
    // host arranges for iso_wamr_render() to run again on its UI loop.
    void (*on_schedule_render)(void *ctx);
    // The reactor's swift_ffi C-symbol prefix (e.g. "swift_ffi_appservices_"),
    // enabling the generic swift_ffi transport: the standard DI imports are
    // bound under this prefix and iso_wamr_ffi_host() returns the runtime.
    // NULL disables the transport (e.g. the slim hot_demo reactor). The string
    // must outlive the instance (a literal, typically). NOTE: swift_ffi native
    // registration is process-global — every instance in a process must use
    // the same prefix (the first one wins).
    const char *ffi_prefix;
    // The guest enqueued Swift concurrency jobs (a `Task {}`, or a continuation
    // resumed by an async service answer): arrange for iso_wamr_run_jobs() to
    // run soon on the thread that drives this instance (may be NULL — then the
    // host must call iso_wamr_run_jobs itself, e.g. from its render loop).
    void (*on_schedule_jobs)(void *ctx);

    // ---- GPU-reactor services (the `iso_gpu` import module; a self-drawing
    // reactor running SwiftGPURenderer in-module measures/rasterizes text on
    // the host's text stack). Both may be NULL for tree-emitting reactors. ----

    // Measure `text` (`len` bytes, UTF-8) at `font_size` points / CSS `weight`,
    // wrapped at `wrap_width` points (< 0 = unwrapped); write {width, height}
    // in points to out_wh[0..1].
    void (*measure_text)(void *ctx, const char *text, size_t len,
                         double font_size, int32_t weight, double wrap_width,
                         double out_wh[2]);
    // Rasterize a SwiftGPURenderer spec (JSON, `len` bytes) to
    // [w u32 LE][h u32 LE][premultiplied RGBA8...]. Returns a malloc'd buffer
    // (the caller frees) and its size in *out_len; NULL/0 when unavailable.
    uint8_t *(*rasterize)(void *ctx, const char *spec, size_t len, size_t *out_len);

    // ---- The platform channel (`iso_hot.platform_command` / `host_value`).
    // Both may be NULL: a command is then dropped, a value is "none". ----

    // A platform command: "copy" (text to the clipboard), "openURL", ...;
    // key and value UTF-8, not NUL-terminated.
    void (*on_platform_command)(void *ctx, const char *key, size_t key_len,
                                const char *value, size_t value_len);
    // A value the host holds ("pasteboard": the clipboard's text): write up to
    // `cap` bytes of it to `out` and return its full length (the guest asks
    // again with room for it when it is longer), or -1 for none.
    int32_t (*host_value)(void *ctx, const char *key, size_t key_len,
                          uint8_t *out, size_t cap);

    // ---- The app's home. Both may be NULL: the guest then has no home, and
    // Foundation's app directories cannot be written. Read at create. ----

    // A host directory the guest sees as its home, /home/app, laid out as an
    // iOS container: Documents, Library/Application Support and
    // Library/Caches are made in it, and HOME, XDG_DATA_HOME and
    // XDG_CACHE_HOME name them in the guest's environment (swift-foundation
    // finds the app's directories from those on WASI). On Apple platforms
    // the app's own container (NSHomeDirectory()): the guest's files are the
    // app's, as when the same app runs compiled.
    const char *home_dir;
    // The guest's Bundle.main.bundleIdentifier (ISOMER_BUNDLE_IDENTIFIER),
    // which names UserDefaults' standard suite's file.
    const char *bundle_identifier;
} IsoWamrCallbacks;

// Register extra native import modules (e.g. the Android GLES "env" natives in
// //android/libraries/wasm_view/jni/iso_wamr_gles.c) with the process-global
// WAMR runtime. The hook runs once, inside the first iso_wamr_create, right
// after the runtime initializes — set it BEFORE creating any instance (the
// Android shim does so in JNI_OnLoad). Hosts without platform natives skip it.
void iso_wamr_set_extra_natives(int (*register_natives)(void));

// Instantiate a reactor from `wasm` bytes: parse, link WASI + iso_hot + the
// (placeholder) swift_ffi imports, and run `_initialize`. On failure returns
// NULL and writes a message into `err` (if err != NULL). The bytes are copied.
IsoWamr *iso_wamr_create(const uint8_t *wasm, size_t wasm_len,
                           IsoWamrCallbacks callbacks, char *err, size_t err_len);

// Like iso_wamr_create, but uses the caller's buffer IN PLACE (not copied,
// not freed; must outlive the instance). For indirect-mode (`wamrc --xip`)
// .aot images embedded in the app's signed __TEXT segment: WAMR executes the
// code straight from the buffer, which is how AOT wasm ships on iOS — the OS
// forbids dynamically mapped executable pages, but code inside the signed
// binary is already executable. (The interp/.wasm path stays the dynamic-
// delivery tier: data, not code.)
IsoWamr *iso_wamr_create_in_place(const uint8_t *wasm, size_t wasm_len,
                                  IsoWamrCallbacks callbacks, char *err, size_t err_len);

// Start the feature at the given size (calls iso_hot_start, then one render).
void iso_wamr_start(IsoWamr *rt, double width, double height);
// Render one frame now (calls iso_hot_render) — drives on_tree.
void iso_wamr_render(IsoWamr *rt);
// Prints the interpreter's per-function profile to stdout (a build with
// `--define wamr_profile=1`; otherwise nothing).
void iso_wamr_dump_profile(IsoWamr *rt);
// A frame only if the guest has one to build (its iso_hot_render_pending;
// a reactor without that export renders as iso_wamr_render does).
void iso_wamr_render_pending(IsoWamr *rt);

// Run the guest's queued Swift concurrency jobs (see on_schedule_jobs), then
// render when any ran and left the guest a frame to build
// (iso_wamr_render_pending). Returns how many jobs ran. Safe to call any time on
// the driving thread; a no-op without the swift_ffi transport.
size_t iso_wamr_run_jobs(IsoWamr *rt);
// Milliseconds until the guest's next timed job (`Task.sleep`) is due — 0
// when one is due now, -1 when none waits: drain again after that long.
int64_t iso_wamr_next_job_delay_ms(IsoWamr *rt);
// Note a new size and re-render (calls iso_hot_resize).
void iso_wamr_resize(IsoWamr *rt, double width, double height);
// The host's system appearance (0 = light / 1 = dark) and re-render (calls
// iso_hot_set_color_scheme; a no-op on reactors without the export).
void iso_wamr_set_color_scheme(IsoWamr *rt, int dark);
// Deliver a host/tap event back into the feature by node id (iso_hot_event).
void iso_wamr_event(IsoWamr *rt, const char *id, size_t id_len,
                     const char *value, size_t value_len);

// ---- GPU (self-drawing) reactor entry points. Every call below MUST run on
// the host's GL thread with the EGL context current — the reactor draws
// through the registered native GL imports during iso_wamr_render. ----

// The GL surface's device-pixel size + density changed (also signals a fresh
// EGL context: the in-module GLES device rebuilds its programs). No-op on
// tree-emitting reactors (they don't export iso_hot_surface_changed).
void iso_wamr_surface_changed(IsoWamr *rt, int32_t width_px, int32_t height_px,
                              double density);
// Pointer input in logical points; kind: 0 down / 1 up / 2 move. Returns
// non-zero when the reactor wants a redraw (the host then requests a frame).
int iso_wamr_pointer(IsoWamr *rt, int32_t kind, double x, double y);
// The instance's swift_ffi host runtime (NULL when `ffi_prefix` was NULL or
// the transport failed to build). The embedding app registers its dependency
// table here (swift_ffi_host_set_dependencies, typically with the adapters
// from its generated `<module>_c_host.h`) and drives its module's exports
// (swift_ffi_host_call / stage / take_string) — e.g. an async fetch
// completion, followed by iso_wamr_render().
SwiftFFIHostRuntime *iso_wamr_ffi_host(IsoWamr *rt);
// Points the guest's `dependencies` dictionary at the registered table by
// running the reactor's `<prefix>install_dependencies` export. Idempotent;
// iso_wamr_start calls it, so only hosts that bypass iso_wamr_start (the
// engine-level seam below) call it themselves — AFTER registering the table.
void iso_wamr_activate_dependencies(IsoWamr *rt);

// ---- Low-level engine seam (Apple `WasmRuntime` conformance) ----
// The high-level iso_hot lifecycle above (start/render/resize/event) is what the
// Android JNI shim drives. Apple instead drives the reactor through the shared
// Swift `WasmRuntime` protocol (generic `call` + linear-memory access), so it
// needs these thin, engine-level entry points. The iso_hot render/DI wiring
// still happens in iso_wamr_create; these just expose the running instance.

// A single wasm value crossing the call seam — i32 or f64 (the only arg/return
// kinds the iso_hot exports use).
typedef struct {
    int is_f64;
    union {
        int32_t i32;
        double f64;
    } v;
} IsoWamrValue;

// Invoke export `name` with `nargs` args. If it returns a value, writes it into
// *out and returns 1; returns 0 for a void export (results are read as i32 —
// the only return kind on this ABI). Returns 0 on lookup/trap failure.
int iso_wamr_call(IsoWamr *rt, const char *name, const IsoWamrValue *args,
                  size_t nargs, IsoWamrValue *out);
// Copy `len` bytes out of guest linear memory at guest offset `ptr` into `dst`.
void iso_wamr_read_bytes(IsoWamr *rt, uint32_t ptr, uint32_t len, uint8_t *dst);
// Copy `len` bytes from `src` into guest linear memory at guest offset `ptr`.
void iso_wamr_write_bytes(IsoWamr *rt, uint32_t ptr, const uint8_t *src, uint32_t len);

// Tear down the instance and free everything.
void iso_wamr_destroy(IsoWamr *rt);

#ifdef __cplusplus
}
#endif

#endif  // ISO_WAMR_H
