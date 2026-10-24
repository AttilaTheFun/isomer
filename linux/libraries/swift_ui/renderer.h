// Flat C API for the native Linux host + renderer.
//
// The Swift host bridge (`LinuxHost.swift`) calls these functions; the
// implementation (`renderer.c`) is an OpenGL renderer hosted in an SDL2 window
// (SDL2_ttf for text, stb_image for image decode, libcurl for async HTTP). This
// mirrors how the wasm host calls into a JavaScript/WebGPU renderer, the Android
// host calls into a Kotlin/GLES one, and the Windows host calls into a
// Direct2D/Win32 one — here both the window/event loop and the renderer are
// native and exposed as plain C so Swift can drive them directly.
//
// All geometry is in logical points; the renderer applies the display scale.

#ifndef ISOMER_LINUX_RENDERER_H
#define ISOMER_LINUX_RENDERER_H

#ifdef __cplusplus
extern "C" {
#endif

// --- Window + event loop ------------------------------------------------

// Input callbacks the host registers so SDL events reach the runtime.
typedef void (*iso_pointer_callback)(int kind, double x, double y);
typedef void (*iso_wheel_callback)(double x, double y, double dx, double dy);
typedef void (*iso_resize_callback)(double width, double height);

void iso_set_pointer_callback(iso_pointer_callback cb);
void iso_set_wheel_callback(iso_wheel_callback cb);
void iso_set_resize_callback(iso_resize_callback cb);

// Create the top-level window and the OpenGL context. `title` is UTF-8.
// `width`/`height` are the desired client size in logical points. Returns
// nonzero on success, 0 if the window/context/GL could not be created.
int iso_window_create(double width, double height, const char* title);

// Current drawable size in logical points.
void iso_window_size(double* out_width, double* out_height);

// Device-pixel drawable size and DPI scale (device px per logical point) —
// the SwiftGPU surface's inputs (viewport sizing + scissor rects).
void iso_window_size_px(double* out_width, double* out_height);
double iso_window_scale(void);

// Process pending SDL events, blocking up to `timeout_ms` for the first one
// (0 = poll without blocking) so the render loop can idle without spinning.
// Returns 0 once the window is closed, nonzero to keep running.
int iso_pump_events(int timeout_ms);

// Block briefly to pace the render loop without pegging the CPU (vsync also
// throttles, but this caps the loop if vsync is unavailable).
void iso_frame_wait(void);

// --- Frame lifecycle ----------------------------------------------------
// The runtime draws through SwiftGPU (GLGPUDevice clears/draws); the host
// presents. iso_end_frame evicts stale text textures and swaps buffers.

void iso_end_frame(void);

// --- SwiftGPU rasterization ----------------------------------------------
// The services half of the SwiftGPU renderer: rasterize a spec (JSON —
// {kind: "text"|"gradient"|"shadow"|"image", …}; see HostBridge.rasterize)
// into [w u32 LE][h u32 LE][PREMULTIPLIED RGBA8…] at the window's DPI scale.
// Returns a pointer valid until the next call (main thread only), or NULL
// when unavailable (e.g. an image still loading). Text renders via SDL2_ttf
// (wrapping matches iso_measure_text), gradients/shadows on the CPU, images
// from the retained stb decodes — no GL calls.
const unsigned char* iso_rasterize(const char* spec, int spec_len, int* out_len);

// --- Draw primitives (host-view widgets only) -----------------------------
// The runtime no longer calls these; they remain as the drawing vocabulary
// of the native-control cards and popups this host draws itself (see
// iso_control_sync / iso_host_sync_end in renderer.c).

void iso_fill_rect(double x, double y, double w, double h, double corner_radius,
                   double r, double g, double b, double a);
void iso_stroke_rect(double x, double y, double w, double h, double corner_radius,
                     double line_width, double r, double g, double b, double a);
void iso_fill_gradient(double x, double y, double w, double h, double corner_radius,
                       const char* json, int json_len);
void iso_draw_shadow(double x, double y, double w, double h, double corner_radius,
                     double blur, double dx, double dy,
                     double r, double g, double b, double a);
void iso_draw_text(const char* text, int text_len, double x, double y, double w, double h,
                   double font_size, int weight, double r, double g, double b, double a);
void iso_measure_text(const char* text, int text_len, double font_size, int weight,
                      double wrap_width, double* out_width, double* out_height);
void iso_push_clip(double x, double y, double w, double h, double corner_radius);
void iso_pop_clip(void);
void iso_push_transform(double a, double b, double c, double d, double e, double f);
void iso_pop_transform(void);

// Image support. `iso_image_info` returns 0 = loading, 1 = ready, 2 = failed.
int iso_image_info(const char* source, int source_len, int is_remote,
                   double* out_width, double* out_height);
void iso_draw_image(const char* source, int source_len, int is_remote,
                    double dest_x, double dest_y, double dest_w, double dest_h,
                    double clip_x, double clip_y, double clip_w, double clip_h,
                    double corner_radius, double opacity);

// --- Text input ---------------------------------------------------------

// The host enables SDL text input between begin/end and reports edits via the
// callbacks below (mirroring the runtime's textChanged/textSubmitted).
typedef void (*iso_text_changed_callback)(const char* utf8, int len);
typedef void (*iso_text_submit_callback)(void);
void iso_set_text_changed_callback(iso_text_changed_callback cb);
void iso_set_text_submit_callback(iso_text_submit_callback cb);

void iso_begin_text_input(const char* text, int text_len);
void iso_end_text_input(void);

// --- Networking (async HTTP GET) ----------------------------------------

// Invoked on the main thread (from iso_drain_fetches) when a request finishes.
typedef void (*iso_fetch_callback)(int request_id, int ok, const char* body, int len);
void iso_set_fetch_callback(iso_fetch_callback cb);

void iso_fetch(int request_id, const char* url, int url_len);
// Both return the number of items processed (so the loop can request a render
// when async work — a downloaded image — has updated the scene).
int iso_drain_fetches(void);   // deliver completed fetches (main thread)
int iso_drain_images(void);    // decode any downloaded remote images (main thread)

// A picture an app decoded through ImageIO (`Image(cgImage)`): its encoded
// bytes, handed over at its first draw, decoded under its source key; and
// forgotten when the app's last reference goes (main thread, both).
void iso_register_image(const char* source, int source_len, const unsigned char* bytes, int len);
void iso_forget_image(const char* source, int source_len);

// --- Native host views (form controls) ----------------------------------

// Reconciled each frame between begin/end. The Linux renderer draws Picker /
// Menu / DatePicker into the GL frame (composited over the runtime's
// placeholder) and hit-tests them so a tap advances the selection; WebView is
// drawn as a labeled placeholder. Geometry is in logical points.
void iso_host_sync_begin(void);
void iso_host_sync_end(void);

// Nonzero (and clears) when a host widget changed what's drawn (a popup opened /
// closed, a slider dragged) — these don't route through the runtime, so the loop
// schedules a frame in response.
int iso_take_render_request(void);

void iso_webview_sync(const char* id, int id_len, const char* url, int url_len,
                      double x, double y, double w, double h);

typedef void (*iso_control_changed_callback)(const char* id, int id_len,
                                             const char* value, int value_len);
void iso_set_control_changed_callback(iso_control_changed_callback cb);

// `kind` is "picker", "menu", or "datepicker". `value` is the selection index
// (picker/menu) or ISO yyyy-MM-dd (datepicker); `options` is the newline-joined
// option labels (combo kinds; empty otherwise).
void iso_control_sync(const char* id, int id_len, const char* kind, int kind_len,
                      const char* value, int value_len,
                      const char* options, int options_len,
                      double x, double y, double w, double h);

// --- IsomerBridge (logging / clock / openURL) ------------------------

void iso_bridge_log(const char* message, int len);
double iso_bridge_epoch_millis(void);
void iso_bridge_open_url(const char* url, int len);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ISOMER_LINUX_RENDERER_H
