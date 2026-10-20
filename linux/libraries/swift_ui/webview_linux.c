// Embedded WebView for the Linux host (WebKitGTK in an X11 child window).
// See webview_linux.h for the model and caveats.

#define _GNU_SOURCE
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <gdk/gdkx.h>
#include <X11/Xlib.h>

#include <stdlib.h>
#include <string.h>

#include "webview_linux.h"

#define MAX_WV 8

typedef struct {
  char *id;
  char *url;
  GtkWidget *win;        // undecorated GtkWindow hosting the WebView
  WebKitWebView *web;
  Window xid;            // the GtkWindow's X11 window (reparented under SDL's)
  int x, y, w, h;        // last applied geometry (device px)
  int shown;             // synced this frame?
  int mapped;            // currently visible (mapped)?
} WebView;

static WebView g_wv[MAX_WV];
static int g_count;
static int g_ready;
static Window g_parent;     // SDL window's X11 id
static Display *g_dpy;      // GDK's X11 display connection

int iso_wv_init(unsigned long sdl_x11_window) {
  if (g_ready) return 1;
  // X11 only — XEmbed-style reparenting has no Wayland equivalent.
  if (getenv("WAYLAND_DISPLAY")) return 0;
  if (!gtk_init_check(NULL, NULL)) return 0;
  GdkDisplay *gd = gdk_display_get_default();
  if (!gd || !GDK_IS_X11_DISPLAY(gd)) return 0;
  g_dpy = gdk_x11_display_get_xdisplay(gd);
  g_parent = (Window)sdl_x11_window;
  g_ready = 1;
  return 1;
}

int iso_wv_available(void) { return g_ready; }

static WebView *find(const char *id) {
  for (int i = 0; i < g_count; i++)
    if (strcmp(g_wv[i].id, id) == 0) return &g_wv[i];
  return NULL;
}

static WebView *create(const char *id, const char *url) {
  if (g_count >= MAX_WV) return NULL;
  WebView *v = &g_wv[g_count++];
  memset(v, 0, sizeof(*v));
  v->id = strdup(id);
  v->url = strdup(url);
  v->win = gtk_window_new(GTK_WINDOW_POPUP);  // undecorated, no WM frame
  gtk_window_set_resizable(GTK_WINDOW(v->win), TRUE);
  v->web = WEBKIT_WEB_VIEW(webkit_web_view_new());
  gtk_container_add(GTK_CONTAINER(v->win), GTK_WIDGET(v->web));
  gtk_widget_realize(v->win);
  GdkWindow *gw = gtk_widget_get_window(v->win);
  v->xid = gdk_x11_window_get_xid(gw);
  // Reparent the browser window as a child of the SDL window (XIDs are
  // server-global, so the GDK connection can reparent into SDL's window).
  XReparentWindow(g_dpy, v->xid, g_parent, 0, 0);
  gtk_widget_show_all(v->win);
  v->mapped = 1;
  webkit_web_view_load_uri(v->web, url);
  return v;
}

void iso_wv_begin_frame(void) {
  for (int i = 0; i < g_count; i++) g_wv[i].shown = 0;
}

void iso_wv_sync(const char *id, const char *url, int x, int y, int w, int h) {
  if (!g_ready) return;
  WebView *v = find(id);
  if (!v) v = create(id, url);
  if (!v) return;
  v->shown = 1;
  if (v->url && url && strcmp(v->url, url) != 0) {
    free(v->url);
    v->url = strdup(url);
    webkit_web_view_load_uri(v->web, url);
  }
  if (!v->mapped) {
    XMapWindow(g_dpy, v->xid);
    gtk_widget_show(v->win);
    v->mapped = 1;
  }
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  if (v->x != x || v->y != y || v->w != w || v->h != h) {
    v->x = x; v->y = y; v->w = w; v->h = h;
    XMoveResizeWindow(g_dpy, v->xid, x, y, w, h);
    gtk_window_resize(GTK_WINDOW(v->win), w, h);
  }
  XFlush(g_dpy);
}

// Hide (unmap) any browser not synced this frame rather than destroying it, so
// it's reused (and reloads aren't needed) when it reappears; reparented X11
// windows don't tear down cleanly via gtk_widget_destroy anyway. Returns the
// number currently visible (so the loop keeps pumping GTK while any are shown).
int iso_wv_end_frame(void) {
  int active = 0;
  for (int i = 0; i < g_count; i++) {
    WebView *v = &g_wv[i];
    if (!v->shown && v->mapped) {
      gtk_widget_hide(v->win);
      XUnmapWindow(g_dpy, v->xid);
      v->mapped = 0;
    }
    if (v->mapped) active++;
  }
  if (g_count) XFlush(g_dpy);
  return active;
}

void iso_wv_pump(void) {
  if (!g_ready) return;
  int n = 0;
  while (gtk_events_pending() && n++ < 256) gtk_main_iteration_do(FALSE);
}
