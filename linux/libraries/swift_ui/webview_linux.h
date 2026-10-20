// Embedded WebView for the Linux host, backed by a real WebKitGTK browser.
//
// A `WebKitWebView` is hosted in an undecorated GTK window whose X11 window is
// reparented as a child of the SDL window (XEmbed-style), then positioned per
// frame to match the WebView's UI rect — the same "native child window" model
// the Windows host uses for its embedded browser. The X server composites the
// browser on top of the GL surface; clicks/scrolls over it go straight to
// WebKit. This is **X11 only**; on Wayland (or if WebKitGTK is unavailable)
// `iso_wv_init` returns 0 and the renderer falls back to a system-browser card.
//
// The API is plain C (no GTK types) so `renderer.c` can call it without pulling
// in the GTK/WebKit headers; only `webview_linux.c` is built against them.

#ifndef ISOMER_WEBVIEW_LINUX_H
#define ISOMER_WEBVIEW_LINUX_H

#ifdef __cplusplus
extern "C" {
#endif

// Initialize GTK/WebKit and remember the SDL window's X11 id to reparent into.
// Returns 1 if the embedded browser is available, 0 otherwise (Wayland, no
// WebKitGTK, not an X11 display) — in which case the caller should fall back.
int iso_wv_init(unsigned long sdl_x11_window);
int iso_wv_available(void);

// Per-frame reconcile: `begin` marks all browsers stale, one `sync` per WebView
// present (creating/moving/loading as needed; geometry in device pixels), then
// `end` destroys any not synced this frame and returns the number still alive.
void iso_wv_begin_frame(void);
void iso_wv_sync(const char *id, const char *url, int x, int y, int w, int h);
int iso_wv_end_frame(void);

// Iterate the GTK main loop (non-blocking) so the browser loads/animates/reacts.
void iso_wv_pump(void);

#ifdef __cplusplus
}
#endif

#endif  // ISOMER_WEBVIEW_LINUX_H
