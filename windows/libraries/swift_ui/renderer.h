// Flat C API for the native Windows host + renderer.
//
// The Swift host bridge (`WindowsHost.swift`) calls these functions; the
// implementation (`renderer.cpp`) is a Direct2D / DirectWrite / WIC renderer
// hosted in a Win32 window. This mirrors how the wasm host calls into a
// JavaScript/WebGPU renderer and the Android host calls into a Kotlin/GLES one —
// here both the window/event loop and the renderer are native and exposed as
// plain C so Swift can drive them without COM/C++ interop.

#ifndef ISOMER_WINDOWS_RENDERER_H
#define ISOMER_WINDOWS_RENDERER_H

#ifdef __cplusplus
extern "C" {
#endif

// --- Window + event loop ------------------------------------------------

// Input callbacks the host registers so Win32 events reach the runtime.
typedef void (*iso_pointer_callback)(int kind, double x, double y);
typedef void (*iso_wheel_callback)(double x, double y, double dx, double dy);
typedef void (*iso_resize_callback)(double width, double height);

// Invoked when the window needs to repaint synchronously (WM_SIZE / WM_PAINT),
// e.g. during an interactive resize when the render loop is otherwise blocked in
// the modal move/size loop. The host should render one frame.
typedef void (*iso_paint_callback)(void);

void iso_set_pointer_callback(iso_pointer_callback cb);
void iso_set_wheel_callback(iso_wheel_callback cb);
void iso_set_resize_callback(iso_resize_callback cb);
void iso_set_paint_callback(iso_paint_callback cb);

// Create the top-level window and the Direct2D device. `title` is UTF-8.
// `width`/`height` are the desired client size in logical points.
void iso_window_create(double width, double height, const char* title);

// Current client size in logical points (DIPs).
void iso_window_size(double* out_width, double* out_height);

// The Win32 window handle, client size in device pixels, and the DPI scale
// (device pixels per logical point) — the SwiftGPU surface's inputs (the
// D3D11 backend creates its swapchain against the HWND and resizes in px).
void* iso_window_hwnd(void);
void iso_window_size_px(double* out_width, double* out_height);
double iso_window_scale(void);

// Drain all pending Win32 messages. Returns 0 once the window is closed
// (WM_QUIT), nonzero to keep running.
int iso_pump_events(void);

// Block briefly to pace the render loop without pegging the CPU.
void iso_frame_wait(void);

// --- Text + image services -----------------------------------------------
// Drawing happens in Swift (SwiftGPURenderer over swift_gpu's D3D11 backend);
// this host only measures text and reports image status/dimensions. Pixels
// come from iso_rasterize below.

void iso_measure_text(const char* text, int text_len, double font_size, int weight,
                      double wrap_width, double* out_width, double* out_height);

// `iso_image_info` returns 0 = loading, 1 = ready, 2 = failed (and starts a
// remote download on first ask).
int iso_image_info(const char* source, int source_len, int is_remote,
                   double* out_width, double* out_height);

// --- Text input ---------------------------------------------------------

// While a TextField is focused, a native EDIT child window overlays the drawn
// field (the display list draws the box and focus ring but not the value — the
// overlay owns the live text, caret, selection, and IME, mirroring the web
// host's visible DOM input overlay). Edits are reported via the callbacks
// below (the runtime's textChanged/textSubmitted).
typedef void (*iso_text_changed_callback)(const char* utf8, int len);
typedef void (*iso_text_submit_callback)(void);
void iso_set_text_changed_callback(iso_text_changed_callback cb);
void iso_set_text_submit_callback(iso_text_submit_callback cb);

// Show the overlay over the field at (x, y, w, h) (logical points) seeded with
// `text`; hide it again on end. The overlay insets to the drawn field's text
// box (8pt horizontal, one `font_size` line centered vertically).
void iso_begin_text_input(const char* text, int text_len,
                          double x, double y, double w, double h,
                          double font_size);
void iso_end_text_input(void);

// Effective color scheme; styles the native overlays (text input colors).
void iso_set_color_scheme(int dark);

// --- Networking (async HTTP GET) ----------------------------------------

// Invoked on the main thread (from iso_drain_fetches) when a request finishes.
// `ok` is nonzero on success; `body` is the response text (UTF-8, `len` bytes).
typedef void (*iso_fetch_callback)(int request_id, int ok, const char* body, int len);
void iso_set_fetch_callback(iso_fetch_callback cb);

// Start an asynchronous HTTP(S) GET. The result is delivered later via the
// fetch callback when iso_drain_fetches() is called from the render loop.
void iso_fetch(int request_id, const char* url, int url_len);

// Deliver any completed fetches by invoking the fetch callback (main thread).
void iso_drain_fetches(void);

// Decode any downloaded remote images into GPU bitmaps (main thread).
void iso_drain_images(void);

// --- SwiftGPU rasterization ------------------------------------------------

// The services half of the SwiftGPU renderer: rasterize a spec (JSON —
// {kind: "text"|"gradient"|"shadow"|"image", …}; see HostBridge.rasterize)
// into [width u32 LE][height u32 LE][PREMULTIPLIED RGBA8…] at the window's
// DPI scale. Returns a pointer valid until the next call (main thread only)
// or NULL when unavailable (e.g. an image still loading). Text renders via
// DirectWrite, gradients via an offscreen D2D WIC target, shadows via a CPU
// Gaussian (triple box blur), images via WIC decode — no GPU calls here.
const unsigned char* iso_rasterize(const char* spec, int spec_len, int* out_len);

// --- Native host views (WebView + form controls) ------------------------

// Native child-window host views, driven from the host-view sync each frame:
// begin, one sync per native view present (iso_webview_sync for "webview";
// iso_control_sync for "picker"/"menu"/"datepicker"), then end (which tears
// down any child window not synced this round). Geometry is in logical points.
void iso_host_sync_begin(void);
void iso_host_sync_end(void);

void iso_webview_sync(const char* id, int id_len, const char* url, int url_len,
                      double x, double y, double w, double h);

// Invoked when the user edits a native control; `value` is the new selection
// index ("picker"/"menu") or ISO date ("datepicker"), routed to the runtime's
// host-view event channel.
typedef void (*iso_control_changed_callback)(const char* id, int id_len,
                                             const char* value, int value_len);
void iso_set_control_changed_callback(iso_control_changed_callback cb);

// Reconcile a native form control. `kind` is "picker", "menu", or "datepicker".
// `value` is the selection index (picker/menu) or ISO yyyy-MM-dd (datepicker);
// `options` is the newline-joined option labels (combo kinds; empty otherwise).
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

#endif  // ISOMER_WINDOWS_RENDERER_H
