// Native Linux host + renderer (SDL2 window/event loop, OpenGL 3.3 core
// rendering, SDL2_ttf text, stb_image decode, libcurl async HTTP).
//
// Implements the flat C API in `renderer.h`, which `LinuxHost.swift` drives.
// Every UI primitive is drawn on the GPU: rounded rects, borders, gradients and
// drop shadows are evaluated with a signed-distance-field fragment shader (the
// same idea the WebGPU/GLES hosts use); text and images are textured quads. One
// small draw call per primitive — a UI frame is a few hundred quads, so this is
// comfortably faster than vsync and keeps the renderer simple and exact.

#define _GNU_SOURCE
#define GL_GLEXT_PROTOTYPES
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <SDL2/SDL_ttf.h>
#include <GL/gl.h>
#include <GL/glext.h>
#include <curl/curl.h>

#include <dirent.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "stb/stb_image.h"  // decode functions only (impl is in stb_impl.c)
#include "renderer.h"
#include "webview_linux.h"  // embedded WebKitGTK browser (X11), with fallback

// Internal helpers used before their definitions.
int iso_host_pointer(int kind, double px, double py);
void iso_fetch_image(const char *key);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

#define ISO_MAX_CLIP 64
#define ISO_MAX_XFORM 64
#define ISO_MAX_STOPS 8

// Draw modes understood by the fragment shader.
enum { MODE_FILL = 0, MODE_STROKE = 1, MODE_SHADOW = 2, MODE_TEXTURE = 3, MODE_GRADIENT = 4 };

typedef struct { float x, y, w, h, radius; } ClipRect;
typedef struct { float a, b, c, d, e, f; } Affine;  // [a c e; b d f; 0 0 1]

// Cached rasterized text run (rendered white, tinted at draw time).
typedef struct {
  char *text;
  int px;        // rasterization pixel size
  int bold;
  int wrap;      // wrap width in device px (0 = no wrap)
  GLuint tex;
  int tw, th;    // texture size in device px
  long lastUsed; // frame stamp for eviction
} TextEntry;

// Cached image (bundled asset or decoded remote download). The straight-
// alpha RGBA bytes are retained for iso_rasterize (the SwiftGPU renderer
// uploads its own textures from them).
typedef struct {
  char *key;
  GLuint tex;
  unsigned char *rgba;
  int w, h;
  int status;    // 0 loading, 1 ready, 2 failed
} ImageEntry;

typedef struct {
  char *key;     // image cache key
  unsigned char *bytes;
  int len;
  int ok;
} DownloadedImage;

typedef struct {
  int id;
  char *body;
  int len;
  int ok;
} CompletedFetch;

// A native control reconciled this frame (drawn + hit-tested by us).
typedef struct {
  char *id;
  char kind[24];
  char *value;
  char *options;  // newline-joined
  float x, y, w, h;
} Control;

typedef struct {
  char *id;
  char *url;
  float x, y, w, h;
} WebViewEntry;

typedef struct {
  SDL_Window *window;
  SDL_GLContext gl;
  double logicalW, logicalH;  // client size in logical points
  float scale;                // device px per logical point

  iso_pointer_callback pointerCb;
  iso_wheel_callback wheelCb;
  iso_resize_callback resizeCb;
  iso_text_changed_callback textChangedCb;
  iso_text_submit_callback textSubmitCb;
  iso_fetch_callback fetchCb;
  iso_control_changed_callback controlChangedCb;

  // GL program + uniforms + unit-quad geometry.
  GLuint prog, vao, vbo;
  GLint uViewport, uRect, uXform, uMode, uColor, uShapeCenter, uShapeHalf, uShapeRadius;
  GLint uStroke, uBlur, uAA, uTex, uClipOn, uClipCenter, uClipHalf, uClipRadius;
  GLint uGradKind, uG0, uG1, uGc, uGsr, uGer, uGa0, uGa1, uStopCount, uStopColor, uStopLoc;

  ClipRect clip[ISO_MAX_CLIP];
  int clipCount;
  Affine xform[ISO_MAX_XFORM];
  int xformCount;

  TextEntry *texts;
  int textCount, textCap;
  ImageEntry *images;
  int imageCount, imageCap;
  long frame;

  TTF_Font *fontReg[64];   // indexed by px size
  TTF_Font *fontBold[64];

  // Text input buffer (we own the edited string; runtime renders the field).
  char textBuf[1024];
  int textActive;

  // Native controls drawn this frame, kept for hit-testing.
  Control controls[64];
  int controlCount;
  WebViewEntry webviews[16];
  int webviewCount;
  double mouseX, mouseY;

  // An open popup (Picker/Menu dropdown or DatePicker calendar). Persists across
  // frames until dismissed; NULL `popupId` means none. The control id is a full
  // structural-identity path (can be long), so these are heap strings.
  char *popupId;
  char popupKind[24];
  char popupValue[64];
  char *popupOptions;        // copy of the control's newline-joined options
  float popupX, popupY, popupW, popupH;  // the anchor control's frame
  float popupScroll;         // dropdown scroll offset (long option lists)
  int calYear, calMonth;     // DatePicker calendar: the month being shown
  // Active linux:trackbar drag; NULL means none.
  char *dragSliderId;
  // Set when a host widget changes what's drawn (open/close/select/drag) so the
  // render loop schedules a frame (these don't go through the runtime).
  int renderRequest;

  // Background worker results.
  pthread_mutex_t netMutex;
  CompletedFetch fetches[64];
  int fetchCount;
  DownloadedImage downloads[64];
  int downloadCount;
} Renderer;

static Renderer g;

static char *dupstr(const char *s, int len) {
  if (!s) return NULL;
  if (len < 0) len = (int)strlen(s);
  char *out = (char *)malloc(len + 1);
  memcpy(out, s, len);
  out[len] = 0;
  return out;
}

// ---------------------------------------------------------------------------
// Fonts (DejaVu Sans, the standard Linux UI font)
// ---------------------------------------------------------------------------

static TTF_Font *fontFor(int px, int bold) {
  if (px < 1) px = 1;
  if (px > 63) px = 63;
  TTF_Font **slot = bold ? &g.fontBold[px] : &g.fontReg[px];
  if (*slot) return *slot;
  // Distro font layouts differ: Arch/SteamOS use fonts/TTF, Debian/Ubuntu
  // (e.g. WSL) use fonts/truetype/dejavu. Take the first that opens.
  const char *candidates[] = {
      bold ? "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf"
           : "/usr/share/fonts/TTF/DejaVuSans.ttf",
      bold ? "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
           : "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  };
  for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]) && !*slot; i++) {
    *slot = TTF_OpenFont(candidates[i], px);
  }
  if (*slot) {
    TTF_SetFontHinting(*slot, TTF_HINTING_LIGHT);
#if SDL_TTF_VERSION_ATLEAST(2, 24, 0)
    // Match the runtime's line-height assumption (fontSize * 1.3) so wrapped
    // lines align with the frame the runtime caps `.lineLimit(N)` text to —
    // otherwise DejaVu's shorter natural line-skip lets an extra line peek in
    // before the clip, cutting it mid-line. (Setter added in SDL2_ttf 2.24;
    // older distros — Ubuntu 24.04 ships 2.22 — keep the default skip, which
    // only loosens wrapped-line spacing slightly.)
    TTF_SetFontLineSkip(*slot, (int)lround(px * 1.3));
#endif
  }
  return *slot;
}

// ---------------------------------------------------------------------------
// Shader program
// ---------------------------------------------------------------------------

static const char *VERT_SRC =
    "#version 330 core\n"
    "layout(location=0) in vec2 aPos;\n"
    "uniform vec2 uViewport; uniform vec4 uRect; uniform mat3 uXform;\n"
    "out vec2 vPoint; out vec2 vScreen; out vec2 vUV; out vec2 vLocal;\n"
    "void main(){\n"
    "  vLocal = aPos * uRect.zw;\n"
    "  vPoint = uRect.xy + vLocal;\n"        // pre-transform point space (shape SDF)
    "  vec3 s = uXform * vec3(vPoint, 1.0);\n"
    "  vScreen = s.xy;\n"                     // post-transform screen points (clip test)
    "  vUV = aPos;\n"
    "  gl_Position = vec4(2.0*s.x/uViewport.x - 1.0, 1.0 - 2.0*s.y/uViewport.y, 0.0, 1.0);\n"
    "}\n";

static const char *FRAG_SRC =
    "#version 330 core\n"
    "in vec2 vPoint; in vec2 vScreen; in vec2 vUV; in vec2 vLocal;\n"
    "out vec4 fragColor;\n"
    "uniform int uMode; uniform vec4 uColor;\n"
    "uniform vec2 uShapeCenter; uniform vec2 uShapeHalf; uniform float uShapeRadius;\n"
    "uniform float uStroke; uniform float uBlur; uniform float uAA;\n"
    "uniform sampler2D uTex;\n"
    "uniform int uClipOn; uniform vec2 uClipCenter; uniform vec2 uClipHalf; uniform float uClipRadius;\n"
    "uniform int uGradKind; uniform vec2 uG0; uniform vec2 uG1; uniform vec2 uGc;\n"
    "uniform float uGsr; uniform float uGer; uniform float uGa0; uniform float uGa1;\n"
    "uniform int uStopCount; uniform vec4 uStopColor[8]; uniform float uStopLoc[8];\n"
    "float sdf(vec2 p, vec2 b, float r){ vec2 q = abs(p)-b+vec2(r); return min(max(q.x,q.y),0.0)+length(max(q,0.0))-r; }\n"
    "vec4 gradColor(){\n"
    "  float t;\n"
    "  if(uGradKind==0){ vec2 a=uG0*uShapeHalf*2.0; vec2 b=uG1*uShapeHalf*2.0; vec2 ab=b-a; float L=max(dot(ab,ab),1e-4); t=dot(vLocal-a,ab)/L; }\n"
    "  else if(uGradKind==1){ vec2 c=uGc*uShapeHalf*2.0; float d=length(vLocal-c); t=(d-uGsr)/max(uGer-uGsr,1e-4); }\n"
    "  else { vec2 c=uGc*uShapeHalf*2.0; float ang=atan(vLocal.y-c.y, vLocal.x-c.x); float two=6.28318530718; ang=mod(ang-uGa0, two); float span=uGa1-uGa0; if(abs(span)<1e-4) span=two; t=ang/span; }\n"
    "  t=clamp(t,0.0,1.0);\n"
    "  vec4 col=uStopColor[0];\n"
    "  for(int i=0;i<uStopCount-1;i++){ if(t>=uStopLoc[i] && t<=uStopLoc[i+1]){ float f=(t-uStopLoc[i])/max(uStopLoc[i+1]-uStopLoc[i],1e-4); col=mix(uStopColor[i],uStopColor[i+1],f);} }\n"
    "  if(uStopCount>0 && t>=uStopLoc[uStopCount-1]) col=uStopColor[uStopCount-1];\n"
    "  return col;\n"
    "}\n"
    "void main(){\n"
    "  float d = sdf(vPoint - uShapeCenter, uShapeHalf, uShapeRadius);\n"
    "  float a;\n"
    "  vec4 color = uColor;\n"
    "  if(uMode==0){ a = (1.0 - smoothstep(-uAA, uAA, d)) * uColor.a; }\n"
    "  else if(uMode==1){ float dd = abs(d) - uStroke*0.5; a = (1.0 - smoothstep(-uAA, uAA, dd)) * uColor.a; }\n"
    "  else if(uMode==2){ float dd = max(d, 0.0); a = uColor.a * exp(-(dd*dd)/(2.0*uBlur*uBlur + 1e-3)); color = vec4(uColor.rgb, 1.0); }\n"
    "  else if(uMode==3){ vec4 t = texture(uTex, vUV); color = vec4(t.rgb, t.a) * uColor; a = color.a; }\n"
    "  else { color = gradColor(); a = (1.0 - smoothstep(-uAA, uAA, d)) * color.a; }\n"
    "  if(uClipOn==1){ float dc = sdf(vScreen - uClipCenter, uClipHalf, uClipRadius); a *= 1.0 - smoothstep(-uAA, uAA, dc); }\n"
    "  if(a <= 0.0) discard;\n"
    "  fragColor = vec4(color.rgb, a);\n"
    "}\n";

static GLuint compile(GLenum type, const char *src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  GLint ok = 0;
  glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[2048];
    glGetShaderInfoLog(s, sizeof(log), NULL, log);
    fprintf(stderr, "[iso] shader compile error: %s\n", log);
  }
  return s;
}

static void buildProgram(void) {
  GLuint vs = compile(GL_VERTEX_SHADER, VERT_SRC);
  GLuint fs = compile(GL_FRAGMENT_SHADER, FRAG_SRC);
  g.prog = glCreateProgram();
  glAttachShader(g.prog, vs);
  glAttachShader(g.prog, fs);
  glLinkProgram(g.prog);
  GLint ok = 0;
  glGetProgramiv(g.prog, GL_LINK_STATUS, &ok);
  if (!ok) {
    char log[2048];
    glGetProgramInfoLog(g.prog, sizeof(log), NULL, log);
    fprintf(stderr, "[iso] program link error: %s\n", log);
  }
  glDeleteShader(vs);
  glDeleteShader(fs);

  // Unit quad (two triangles).
  float quad[12] = {0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1};
  glGenVertexArrays(1, &g.vao);
  glBindVertexArray(g.vao);
  glGenBuffers(1, &g.vbo);
  glBindBuffer(GL_ARRAY_BUFFER, g.vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 2 * sizeof(float), (void *)0);

#define U(name) g.u##name = glGetUniformLocation(g.prog, "u" #name)
  U(Viewport); U(Rect); U(Xform); U(Mode); U(Color);
  U(ShapeCenter); U(ShapeHalf); U(ShapeRadius); U(Stroke); U(Blur); U(AA); U(Tex);
  U(ClipOn); U(ClipCenter); U(ClipHalf); U(ClipRadius);
  U(GradKind); U(G0); U(G1); U(Gc); U(Gsr); U(Ger); U(Ga0); U(Ga1);
  U(StopCount); U(StopColor); U(StopLoc);
#undef U
}

// ---------------------------------------------------------------------------
// Transform + clip stacks
// ---------------------------------------------------------------------------

static Affine currentXform(void) {
  return g.xformCount > 0 ? g.xform[g.xformCount - 1]
                          : (Affine){1, 0, 0, 1, 0, 0};
}

static void applyXform(void) {
  Affine m = currentXform();
  // column-major mat3 for GL: columns (a,b,0)(c,d,0)(e,f,1)
  float mat[9] = {m.a, m.b, 0, m.c, m.d, 0, m.e, m.f, 1};
  glUniformMatrix3fv(g.uXform, 1, GL_FALSE, mat);
}

static void applyClip(void) {
  if (g.clipCount == 0) {
    glUniform1i(g.uClipOn, 0);
    return;
  }
  ClipRect c = g.clip[g.clipCount - 1];
  glUniform1i(g.uClipOn, 1);
  glUniform2f(g.uClipCenter, c.x + c.w / 2, c.y + c.h / 2);
  glUniform2f(g.uClipHalf, c.w / 2, c.h / 2);
  glUniform1f(g.uClipRadius, c.radius);
}

// ---------------------------------------------------------------------------
// Core quad draw
// ---------------------------------------------------------------------------

// Draws one quad. `gx,gy,gw,gh` is the geometry rect (the quad), `cx,cy` the
// SDF shape center, `hw,hh` its half-size, `radius` its corner radius.
static void drawQuad(int mode, float gx, float gy, float gw, float gh,
                     float cx, float cy, float hw, float hh, float radius,
                     float r, float gcol, float b, float a) {
  glUniform1i(g.uMode, mode);
  glUniform4f(g.uRect, gx, gy, gw, gh);
  glUniform2f(g.uShapeCenter, cx, cy);
  glUniform2f(g.uShapeHalf, hw, hh);
  glUniform1f(g.uShapeRadius, radius);
  glUniform4f(g.uColor, r, gcol, b, a);
  applyXform();
  applyClip();
  glDrawArrays(GL_TRIANGLES, 0, 6);
}

// ---------------------------------------------------------------------------
// Window + event loop
// ---------------------------------------------------------------------------

void iso_set_pointer_callback(iso_pointer_callback cb) { g.pointerCb = cb; }
void iso_set_wheel_callback(iso_wheel_callback cb) { g.wheelCb = cb; }
void iso_set_resize_callback(iso_resize_callback cb) { g.resizeCb = cb; }
void iso_set_text_changed_callback(iso_text_changed_callback cb) { g.textChangedCb = cb; }
void iso_set_text_submit_callback(iso_text_submit_callback cb) { g.textSubmitCb = cb; }
void iso_set_fetch_callback(iso_fetch_callback cb) { g.fetchCb = cb; }
void iso_set_control_changed_callback(iso_control_changed_callback cb) { g.controlChangedCb = cb; }

static void refreshSize(void) {
  int ww, wh, dw, dh;
  SDL_GetWindowSize(g.window, &ww, &wh);
  SDL_GL_GetDrawableSize(g.window, &dw, &dh);
  g.scale = (ww > 0) ? (float)dw / (float)ww : 1.0f;
  if (g.scale < 0.5f) g.scale = 1.0f;
  g.logicalW = ww;
  g.logicalH = wh;
}

int iso_window_create(double width, double height, const char *title) {
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) {
    fprintf(stderr, "[iso] SDL_Init failed: %s\n", SDL_GetError());
    return 0;
  }
  if (TTF_Init() != 0) {
    fprintf(stderr, "[iso] TTF_Init failed: %s\n", TTF_GetError());
    return 0;
  }
  curl_global_init(CURL_GLOBAL_DEFAULT);
  pthread_mutex_init(&g.netMutex, NULL);

  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);

  g.window = SDL_CreateWindow(
      title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, (int)width, (int)height,
      SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!g.window) {
    fprintf(stderr, "[iso] SDL_CreateWindow failed: %s\n", SDL_GetError());
    return 0;
  }
  g.gl = SDL_GL_CreateContext(g.window);
  if (!g.gl) {
    fprintf(stderr, "[iso] SDL_GL_CreateContext failed: %s\n", SDL_GetError());
    return 0;
  }
  SDL_GL_SetSwapInterval(1);  // vsync
  refreshSize();

  buildProgram();
  glEnable(GL_BLEND);
  glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  fprintf(stderr, "[iso] GL %s | %s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER));

  // Initialize the embedded WebKitGTK browser, reparenting into our X11 window.
  // Returns 0 on Wayland / when WebKitGTK is unavailable — then WebViews fall
  // back to a system-browser card.
  SDL_SysWMinfo wm;
  SDL_VERSION(&wm.version);
  if (SDL_GetWindowWMInfo(g.window, &wm) && wm.subsystem == SDL_SYSWM_X11) {
    if (iso_wv_init((unsigned long)wm.info.x11.window))
      fprintf(stderr, "[iso] embedded WebView: WebKitGTK (X11)\n");
  }
  return 1;
}

void iso_window_size(double *out_width, double *out_height) {
  *out_width = g.logicalW;
  *out_height = g.logicalH;
}

// Device-pixel drawable size + scale, the SwiftGPU surface's inputs.
void iso_window_size_px(double *out_width, double *out_height) {
  int dw = 0, dh = 0;
  if (g.window) SDL_GL_GetDrawableSize(g.window, &dw, &dh);
  *out_width = dw;
  *out_height = dh;
}

double iso_window_scale(void) { return g.scale > 0 ? g.scale : 1.0; }

static int g_quit = 0;

static void handleEvent(SDL_Event e) {
    switch (e.type) {
      case SDL_QUIT:
        g_quit = 1;
        break;
      case SDL_WINDOWEVENT:
        if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED ||
            e.window.event == SDL_WINDOWEVENT_RESIZED) {
          refreshSize();
          if (g.resizeCb) g.resizeCb(g.logicalW, g.logicalH);
        } else if (e.window.event == SDL_WINDOWEVENT_EXPOSED ||
                   e.window.event == SDL_WINDOWEVENT_FOCUS_GAINED ||
                   e.window.event == SDL_WINDOWEVENT_SHOWN ||
                   e.window.event == SDL_WINDOWEVENT_RESTORED) {
          // The window was re-shown/refocused; the post-swap back buffer is
          // stale, so redraw (the render loop is otherwise idle on demand).
          g.renderRequest = 1;
        }
        break;
      case SDL_MOUSEBUTTONDOWN:
        if (getenv("ISO_DEBUG_INPUT")) fprintf(stderr, "[iso] down %d,%d\n", e.button.x, e.button.y);
        // Host widgets (popups / controls / webviews / slider) get first refusal.
        if (e.button.button == SDL_BUTTON_LEFT &&
            !iso_host_pointer(0, e.button.x, e.button.y) && g.pointerCb)
          g.pointerCb(0, e.button.x, e.button.y);
        break;
      case SDL_MOUSEMOTION:
        g.mouseX = e.motion.x;
        g.mouseY = e.motion.y;
        // A slider drag or an open popup keeps capturing motion even with no
        // button held; otherwise forward held-button motion (kind 2 == move).
        if ((g.dragSliderId || g.popupId) && iso_host_pointer(2, e.motion.x, e.motion.y)) {
          // consumed by a host widget
        } else if (g.pointerCb && (e.motion.state & SDL_BUTTON_LMASK)) {
          g.pointerCb(2, e.motion.x, e.motion.y);
        }
        break;
      case SDL_MOUSEBUTTONUP:
        if (getenv("ISO_DEBUG_INPUT")) fprintf(stderr, "[iso] up %d,%d\n", e.button.x, e.button.y);
        // kind 1 == pointer up (fires the tap / focuses a text field).
        if (e.button.button == SDL_BUTTON_LEFT) {
          if (!iso_host_pointer(1, e.button.x, e.button.y) && g.pointerCb)
            g.pointerCb(1, e.button.x, e.button.y);
        }
        break;
      case SDL_MOUSEWHEEL: {
        float dy = (e.wheel.preciseY != 0 ? e.wheel.preciseY : (float)e.wheel.y);
        float dx = (e.wheel.preciseX != 0 ? e.wheel.preciseX : (float)e.wheel.x);
        // An open Picker/Menu dropdown captures the wheel to scroll its list.
        if (g.popupId && strcmp(g.popupKind, "datepicker") != 0) {
          g.popupScroll -= dy * 40.0f;  // clamped in dropdownGeom each frame
          g.renderRequest = 1;
        } else if (g.wheelCb) {
          g.wheelCb(g.mouseX, g.mouseY, dx * 40.0, -dy * 40.0);
        }
        break;
      }
      case SDL_TEXTINPUT:
        if (g.textActive) {
          strncat(g.textBuf, e.text.text, sizeof(g.textBuf) - strlen(g.textBuf) - 1);
          if (g.textChangedCb) g.textChangedCb(g.textBuf, (int)strlen(g.textBuf));
        }
        break;
      case SDL_KEYDOWN:
        if (g.textActive) {
          if (e.key.keysym.sym == SDLK_BACKSPACE) {
            int n = (int)strlen(g.textBuf);
            while (n > 0 && ((unsigned char)g.textBuf[n - 1] & 0xC0) == 0x80) n--;  // utf8
            if (n > 0) n--;
            g.textBuf[n] = 0;
            if (g.textChangedCb) g.textChangedCb(g.textBuf, (int)strlen(g.textBuf));
          } else if (e.key.keysym.sym == SDLK_RETURN || e.key.keysym.sym == SDLK_KP_ENTER) {
            if (g.textSubmitCb) g.textSubmitCb();
          }
        }
        break;
    }
}

// Process input/window events. Blocks up to `timeout_ms` for the first event
// (0 = don't block) so the render loop can idle without spinning when nothing
// is animating, then drains the rest of the queue. Returns 0 once the window
// is closed, nonzero to keep running.
int iso_pump_events(int timeout_ms) {
  SDL_Event e;
  if (timeout_ms > 0) {
    if (SDL_WaitEventTimeout(&e, timeout_ms)) handleEvent(e);
  }
  while (SDL_PollEvent(&e)) handleEvent(e);
  iso_wv_pump();  // service the embedded browser's GTK main loop
  return g_quit ? 0 : 1;
}

void iso_frame_wait(void) {
  // Cap the loop to ~60 fps. SDL_GL_SetSwapInterval(1) requests vsync, but many
  // Linux compositors (e.g. KWin) redirect the window and ignore the swap
  // interval, so without this floor the render loop would spin at ~100% CPU.
  static Uint64 last = 0;
  const Uint64 target = 16;  // ms per frame (~60 fps)
  Uint64 now = SDL_GetTicks64();
  if (last != 0 && now - last < target) SDL_Delay((Uint32)(target - (now - last)));
  last = SDL_GetTicks64();
}

// ---------------------------------------------------------------------------
// Frame lifecycle
// ---------------------------------------------------------------------------

// The runtime's frame lifecycle now runs through SwiftGPU (GLGPUDevice
// begins/clears; iso_end_frame below evicts + swaps). The per-frame state
// for this file's own host-view drawing moved into iso_host_sync_begin.

void iso_end_frame(void) {
  // Debug capture (off unless ISO_SHOT names a path): dump the just-rendered
  // back buffer as a binary PPM, overwriting each frame so the file always
  // holds the latest frame. Used to verify the GL SwiftGPU renderer where the
  // compositor offers no screenshot path (e.g. WSLg). Read before the swap.
  static int shotEnabled = -1;
  if (shotEnabled == -1) shotEnabled = getenv("ISO_SHOT") ? 1 : 0;
  if (shotEnabled) {
    int dw = 0, dh = 0;
    SDL_GL_GetDrawableSize(g.window, &dw, &dh);
    if (dw > 0 && dh > 0) {
      unsigned char* px = (unsigned char*)malloc((size_t)dw * dh * 4);
      if (px) {
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(0, 0, dw, dh, GL_RGBA, GL_UNSIGNED_BYTE, px);
        FILE* f = fopen(getenv("ISO_SHOT"), "wb");
        if (f) {
          fprintf(f, "P6\n%d %d\n255\n", dw, dh);
          // GL's origin is bottom-left; emit rows top-to-bottom, dropping alpha.
          for (int y = dh - 1; y >= 0; y--) {
            unsigned char* row = px + (size_t)y * dw * 4;
            for (int x = 0; x < dw; x++) fwrite(row + x * 4, 1, 3, f);
          }
          fclose(f);
        }
        free(px);
      }
    }
  }

  // Evict text textures unused for a while.
  for (int i = 0; i < g.textCount;) {
    if (g.frame - g.texts[i].lastUsed > 240) {
      glDeleteTextures(1, &g.texts[i].tex);
      free(g.texts[i].text);
      g.texts[i] = g.texts[--g.textCount];
    } else {
      i++;
    }
  }
  SDL_GL_SwapWindow(g.window);
}

// ---------------------------------------------------------------------------
// Draw primitives
// ---------------------------------------------------------------------------

void iso_fill_rect(double x, double y, double w, double h, double cr,
                   double r, double gg, double b, double a) {
  drawQuad(MODE_FILL, x, y, w, h, x + w / 2, y + h / 2, w / 2, h / 2,
           fmin(cr, fmin(w, h) / 2), r, gg, b, a);
}

void iso_stroke_rect(double x, double y, double w, double h, double cr,
                     double lw, double r, double gg, double b, double a) {
  glUniform1f(g.uStroke, (float)lw);
  drawQuad(MODE_STROKE, x - lw, y - lw, w + 2 * lw, h + 2 * lw, x + w / 2, y + h / 2,
           w / 2, h / 2, fmin(cr, fmin(w, h) / 2), r, gg, b, a);
}

void iso_draw_shadow(double x, double y, double w, double h, double cr,
                     double blur, double dx, double dy,
                     double r, double gg, double b, double a) {
  float margin = (float)blur * 3.0f + 2.0f;
  glUniform1f(g.uBlur, (float)fmax(blur, 0.5));
  drawQuad(MODE_SHADOW, x + dx - margin, y + dy - margin, w + 2 * margin, h + 2 * margin,
           x + dx + w / 2, y + dy + h / 2, w / 2, h / 2, fmin(cr, fmin(w, h) / 2), r, gg, b, a);
}

void iso_push_clip(double x, double y, double w, double h, double cr) {
  if (g.clipCount >= ISO_MAX_CLIP) return;
  ClipRect c = {(float)x, (float)y, (float)w, (float)h, (float)fmin(cr, fmin(w, h) / 2)};
  // Intersect with the parent clip's rect so nested clips compose.
  if (g.clipCount > 0) {
    ClipRect p = g.clip[g.clipCount - 1];
    float x0 = fmaxf(c.x, p.x), y0 = fmaxf(c.y, p.y);
    float x1 = fminf(c.x + c.w, p.x + p.w), y1 = fminf(c.y + c.h, p.y + p.h);
    c.x = x0;
    c.y = y0;
    c.w = fmaxf(0, x1 - x0);
    c.h = fmaxf(0, y1 - y0);
    if (c.radius == 0) c.radius = p.radius;
  }
  g.clip[g.clipCount++] = c;
}

void iso_pop_clip(void) {
  if (g.clipCount > 0) g.clipCount--;
}

void iso_push_transform(double a, double b, double c, double d, double e, double f) {
  if (g.xformCount >= ISO_MAX_XFORM) return;
  Affine n = {(float)a, (float)b, (float)c, (float)d, (float)e, (float)f};
  Affine cur = currentXform();
  // compose cur * n (apply n first, then cur)
  Affine r;
  r.a = cur.a * n.a + cur.c * n.b;
  r.b = cur.b * n.a + cur.d * n.b;
  r.c = cur.a * n.c + cur.c * n.d;
  r.d = cur.b * n.c + cur.d * n.d;
  r.e = cur.a * n.e + cur.c * n.f + cur.e;
  r.f = cur.b * n.e + cur.d * n.f + cur.f;
  g.xform[g.xformCount++] = r;
}

void iso_pop_transform(void) {
  if (g.xformCount > 0) g.xformCount--;
}

// ---------------------------------------------------------------------------
// Gradients
// ---------------------------------------------------------------------------

// Minimal JSON value extraction for the gradient payload (well-formed, emitted
// by Paint.json()). Returns pointer past the matched key's ':' or NULL.
static const char *jfind(const char *json, const char *key) {
  return strstr(json, key);
}

void iso_fill_gradient(double x, double y, double w, double h, double cr,
                       const char *json, int json_len) {
  (void)json_len;
  int kind = 0;  // 0 linear, 1 radial, 2 angular
  if (jfind(json, "\"radial\"")) kind = 1;
  else if (jfind(json, "\"angular\"")) kind = 2;

  float p0[2] = {0, 0}, p1[2] = {0, 1}, c[2] = {0.5f, 0.5f};
  float sr = 0, er = (float)fmax(w, h) / 2, a0 = 0, a1 = 6.2831853f;
  const char *s;
  if ((s = jfind(json, "\"p0\":["))) sscanf(s + 6, "%f,%f", &p0[0], &p0[1]);
  if ((s = jfind(json, "\"p1\":["))) sscanf(s + 6, "%f,%f", &p1[0], &p1[1]);
  if ((s = jfind(json, "\"c\":["))) sscanf(s + 5, "%f,%f", &c[0], &c[1]);
  if ((s = jfind(json, "\"sr\":"))) sscanf(s + 5, "%f", &sr);
  if ((s = jfind(json, "\"er\":"))) sscanf(s + 5, "%f", &er);
  if ((s = jfind(json, "\"a0\":"))) sscanf(s + 5, "%f", &a0);
  if ((s = jfind(json, "\"a1\":"))) sscanf(s + 5, "%f", &a1);

  // Parse up to 8 stops: {"c":[r,g,b,a],"l":loc}
  float stopCol[ISO_MAX_STOPS][4];
  float stopLoc[ISO_MAX_STOPS];
  int n = 0;
  const char *p = jfind(json, "\"stops\":[");
  if (p) {
    p += 9;
    while (n < ISO_MAX_STOPS) {
      const char *cc = strstr(p, "\"c\":[");
      if (!cc) break;
      float r, gg, b, a, l = 0;
      if (sscanf(cc + 5, "%f,%f,%f,%f", &r, &gg, &b, &a) != 4) break;
      const char *ll = strstr(cc, "\"l\":");
      if (ll) sscanf(ll + 4, "%f", &l);
      stopCol[n][0] = r;
      stopCol[n][1] = gg;
      stopCol[n][2] = b;
      stopCol[n][3] = a;
      stopLoc[n] = l;
      n++;
      const char *next = ll ? ll + 4 : cc + 5;
      const char *brk = strchr(next, '}');
      if (!brk) break;
      p = brk + 1;
      if (*p != ',') break;
    }
  }
  if (n == 0) {
    stopCol[0][0] = stopCol[0][1] = stopCol[0][2] = stopCol[0][3] = 1;
    stopLoc[0] = 0;
    n = 1;
  }

  glUniform1i(g.uGradKind, kind);
  glUniform2f(g.uG0, p0[0], p0[1]);
  glUniform2f(g.uG1, p1[0], p1[1]);
  glUniform2f(g.uGc, c[0], c[1]);
  glUniform1f(g.uGsr, sr);
  glUniform1f(g.uGer, er);
  glUniform1f(g.uGa0, a0);
  glUniform1f(g.uGa1, a1);
  glUniform1i(g.uStopCount, n);
  glUniform4fv(g.uStopColor, n, &stopCol[0][0]);
  glUniform1fv(g.uStopLoc, n, stopLoc);

  drawQuad(MODE_GRADIENT, x, y, w, h, x + w / 2, y + h / 2, w / 2, h / 2,
           fmin(cr, fmin(w, h) / 2), 1, 1, 1, 1);
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

// Rasterizes (or reuses) a white text texture for the given run, wrapped to
// `wrapPx` device pixels (0 = no wrap). Returns the cache entry or NULL.
static TextEntry *textTexture(const char *text, int len, int px, int bold, int wrapPx) {
  for (int i = 0; i < g.textCount; i++) {
    TextEntry *e = &g.texts[i];
    if (e->px == px && e->bold == bold && e->wrap == wrapPx &&
        (int)strlen(e->text) == len && memcmp(e->text, text, len) == 0) {
      e->lastUsed = g.frame;
      return e;
    }
  }
  TTF_Font *font = fontFor(px, bold);
  if (!font) return NULL;
  SDL_Color white = {255, 255, 255, 255};
  char *z = dupstr(text, len);
  SDL_Surface *surf = TTF_RenderUTF8_Blended_Wrapped(font, z, white, wrapPx > 0 ? (Uint32)wrapPx : 0);
  if (!surf) {
    free(z);
    return NULL;
  }
  SDL_Surface *rgba = SDL_ConvertSurfaceFormat(surf, SDL_PIXELFORMAT_ABGR8888, 0);
  SDL_FreeSurface(surf);
  if (!rgba) {
    free(z);
    return NULL;
  }
  GLuint tex;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, rgba->w, rgba->h, 0, GL_RGBA, GL_UNSIGNED_BYTE, rgba->pixels);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  if (g.textCount >= g.textCap) {
    g.textCap = g.textCap ? g.textCap * 2 : 256;
    g.texts = (TextEntry *)realloc(g.texts, g.textCap * sizeof(TextEntry));
  }
  TextEntry *e = &g.texts[g.textCount++];
  e->text = z;
  e->px = px;
  e->bold = bold;
  e->wrap = wrapPx;
  e->tex = tex;
  e->tw = rgba->w;
  e->th = rgba->h;
  e->lastUsed = g.frame;
  SDL_FreeSurface(rgba);
  return e;
}

void iso_draw_text(const char *text, int text_len, double x, double y, double w, double h,
                   double font_size, int weight, double r, double gg, double b, double a) {
  (void)h;
  if (text_len <= 0) return;
  int px = (int)lround(font_size * g.scale);
  int bold = weight >= 600;
  int wrapPx = (int)lround(w * g.scale) + 2;
  TextEntry *e = textTexture(text, text_len, px, bold, wrapPx);
  if (!e) return;
  // The texture is in device px; place it at logical points (tw/scale wide).
  float lw = e->tw / g.scale;
  float lh = e->th / g.scale;
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, e->tex);
  drawQuad(MODE_TEXTURE, x, y, lw, lh, x + lw / 2, y + lh / 2, lw / 2, lh / 2, 0,
           r, gg, b, a);
}

void iso_measure_text(const char *text, int text_len, double font_size, int weight,
                      double wrap_width, double *out_width, double *out_height) {
  *out_width = 0;
  *out_height = 0;
  if (text_len <= 0) {
    *out_height = font_size * 1.3;
    return;
  }
  int px = (int)lround(font_size * g.scale);
  int bold = weight >= 600;
  TTF_Font *font = fontFor(px, bold);
  if (!font) {
    *out_width = text_len * font_size * 0.5;
    *out_height = font_size * 1.3;
    return;
  }
  char *z = dupstr(text, text_len);
  int lineSkip = TTF_FontLineSkip(font);
  if (wrap_width < 0) {
    int tw = 0, th = 0;
    TTF_SizeUTF8(font, z, &tw, &th);
    *out_width = tw / g.scale;
    *out_height = (th > 0 ? th : lineSkip) / g.scale;
    free(z);
    return;
  }
  // Wrapped: render-measure via SDL2_ttf so wrapping matches draw exactly.
  SDL_Color white = {255, 255, 255, 255};
  Uint32 wrapPx = (Uint32)lround(wrap_width * g.scale);
  if (wrapPx < 1) wrapPx = 1;
  SDL_Surface *surf = TTF_RenderUTF8_Blended_Wrapped(font, z, white, wrapPx);
  if (surf) {
    *out_width = surf->w / g.scale;
    *out_height = surf->h / g.scale;
    SDL_FreeSurface(surf);
  } else {
    *out_height = lineSkip / g.scale;
  }
  free(z);
}

// ---------------------------------------------------------------------------
// Images
// ---------------------------------------------------------------------------

static ImageEntry *findImage(const char *key) {
  for (int i = 0; i < g.imageCount; i++)
    if (strcmp(g.images[i].key, key) == 0) return &g.images[i];
  return NULL;
}

static ImageEntry *putImage(const char *key, GLuint tex, int w, int h, int status) {
  ImageEntry *e = findImage(key);
  if (!e) {
    if (g.imageCount >= g.imageCap) {
      g.imageCap = g.imageCap ? g.imageCap * 2 : 64;
      g.images = (ImageEntry *)realloc(g.images, g.imageCap * sizeof(ImageEntry));
    }
    e = &g.images[g.imageCount++];
    e->key = dupstr(key, -1);
    e->rgba = NULL;
  }
  e->tex = tex;
  e->w = w;
  e->h = h;
  e->status = status;
  return e;
}

static GLuint texFromRGBA(unsigned char *pixels, int w, int h) {
  GLuint tex;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels);
  glGenerateMipmap(GL_TEXTURE_2D);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  return tex;
}

// Resolve a bundled asset name to a file path via the Bazel runfiles tree.
// Assets are `.../<name>.imageset/<name>[@Nx].png`; we pick the highest scale.
static char g_runfiles[4096];
static int g_runfilesResolved = 0;

static void resolveRunfiles(void) {
  if (g_runfilesResolved) return;
  g_runfilesResolved = 1;
  const char *rd = getenv("RUNFILES_DIR");
  if (rd && rd[0]) {
    snprintf(g_runfiles, sizeof(g_runfiles), "%s", rd);
    return;
  }
  // Fall back to "<argv0>.runfiles" via /proc/self/exe.
  char exe[4096];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n > 0) {
    exe[n] = 0;
    snprintf(g_runfiles, sizeof(g_runfiles), "%s.runfiles", exe);
  }
}

// Recursively search `dir` for "<name>.imageset/<name>*.png", best scale.
static int findAsset(const char *dir, const char *name, char *out, int outLen, int *bestScale) {
  DIR *d = opendir(dir);
  if (!d) return 0;
  struct dirent *ent;
  int found = 0;
  char path[4096];
  while ((ent = readdir(d))) {
    if (ent->d_name[0] == '.') continue;
    snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
    struct stat st;
    if (stat(path, &st) != 0) continue;
    if (S_ISDIR(st.st_mode)) {
      if (findAsset(path, name, out, outLen, bestScale)) found = 1;
    } else {
      // Match "<name>.png" possibly with @2x/@3x inside a "<name>.imageset" dir.
      const char *base = ent->d_name;
      size_t nl = strlen(name);
      if (strncmp(base, name, nl) == 0 &&
          (strstr(base, ".png") || strstr(base, ".PNG"))) {
        int scale = 1;
        if (strstr(base, "@2x")) scale = 2;
        else if (strstr(base, "@3x")) scale = 3;
        if (scale > *bestScale) {
          *bestScale = scale;
          snprintf(out, outLen, "%s", path);
          found = 1;
        }
      }
    }
  }
  closedir(d);
  return found;
}

static unsigned char *loadAssetRGBA(const char *name, int *w, int *h) {
  resolveRunfiles();
  if (!g_runfiles[0]) return NULL;
  char path[4096] = {0};
  int best = 0;
  // Look only under the example app's assets to keep the walk small.
  findAsset(g_runfiles, name, path, sizeof(path), &best);
  if (!path[0]) return NULL;
  int n;
  unsigned char *px = stbi_load(path, w, h, &n, 4);
  return px;
}

int iso_image_info(const char *source, int source_len, int is_remote,
                   double *out_width, double *out_height) {
  char *key = dupstr(source, source_len);
  ImageEntry *e = findImage(key);
  if (e) {
    *out_width = e->w;
    *out_height = e->h;
    int s = e->status;
    free(key);
    return s;
  }
  if (is_remote) {
    putImage(key, 0, 0, 0, 0);  // loading; a download is kicked off by fetch path
    iso_fetch_image(key);
    free(key);
    return 0;
  }
  int w = 0, h = 0;
  unsigned char *px = loadAssetRGBA(key, &w, &h);
  if (!px) {
    putImage(key, 0, 0, 0, 2);
    free(key);
    return 2;
  }
  GLuint tex = texFromRGBA(px, w, h);
  ImageEntry *entry = putImage(key, tex, w, h, 1);
  entry->rgba = px;  // retained for iso_rasterize (stb buffer, straight alpha)
  *out_width = w;
  *out_height = h;
  free(key);
  return 1;
}

void iso_draw_image(const char *source, int source_len, int is_remote,
                    double dest_x, double dest_y, double dest_w, double dest_h,
                    double clip_x, double clip_y, double clip_w, double clip_h,
                    double corner_radius, double opacity) {
  (void)is_remote;
  char *key = dupstr(source, source_len);
  ImageEntry *e = findImage(key);
  free(key);
  if (!e || e->status != 1 || !e->tex) return;

  // Clip to the rounded destination clip rect (in screen points) for this draw.
  iso_push_clip(clip_x, clip_y, clip_w, clip_h, corner_radius);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, e->tex);
  drawQuad(MODE_TEXTURE, dest_x, dest_y, dest_w, dest_h,
           dest_x + dest_w / 2, dest_y + dest_h / 2, dest_w / 2, dest_h / 2, 0,
           1, 1, 1, opacity);
  iso_pop_clip();
}

// ---------------------------------------------------------------------------
// Text input
// ---------------------------------------------------------------------------

void iso_begin_text_input(const char *text, int text_len) {
  int n = text_len < (int)sizeof(g.textBuf) - 1 ? text_len : (int)sizeof(g.textBuf) - 1;
  if (n < 0) n = 0;
  memcpy(g.textBuf, text, n);
  g.textBuf[n] = 0;
  g.textActive = 1;
  SDL_StartTextInput();
}

void iso_end_text_input(void) {
  g.textActive = 0;
  g.textBuf[0] = 0;
  SDL_StopTextInput();
}

// ---------------------------------------------------------------------------
// Native controls (Picker / Menu / DatePicker) — drawn + tap-to-advance
// ---------------------------------------------------------------------------

static int pointIn(float px, float py, float x, float y, float w, float h) {
  return px >= x && px <= x + w && py >= y && py <= y + h;
}

// The label shown on a picker/menu face: its currently-selected option.
static void optionAt(const char *options, int index, char *out, int outLen) {
  const char *p = options;
  for (int i = 0; i < index && p && *p; i++) {
    const char *nl = strchr(p, '\n');
    p = nl ? nl + 1 : NULL;
  }
  if (p && *p) {
    const char *nl = strchr(p, '\n');
    int n = nl ? (int)(nl - p) : (int)strlen(p);
    snprintf(out, outLen, "%.*s", n, p);
  } else {
    out[0] = 0;
  }
}

static int optionCount(const char *options) {
  if (!options || !*options) return 0;
  int n = 1;
  for (const char *p = options; *p; p++)
    if (*p == '\n') n++;
  return n;
}

// MARK: - Date helpers (no Foundation in the renderer)

static int isLeap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }
static int daysInMonth(int y, int m) {
  static const int d[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  return (m == 2 && isLeap(y)) ? 29 : d[(m - 1 + 12) % 12];
}
// Day of week for y-m-d (Sakamoto), 0 = Sunday.
static int dayOfWeek(int y, int m, int d) {
  static const int t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
  if (m < 3) y -= 1;
  return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7;
}

// MARK: - Host view sync

void iso_host_sync_begin(void) {
  // Start of the host-view pass: the control/webview cards + popups below
  // draw with this file's mini GL pipeline over the SwiftGPU frame, so
  // (re)bind its program/VAO and per-frame uniforms (the setup that lived in
  // the deleted iso_begin_frame) — SwiftGPU rebinds its own state per draw.
  g.frame++;
  g.clipCount = 0;
  g.xformCount = 0;
  glUseProgram(g.prog);
  glBindVertexArray(g.vao);
  glEnable(GL_BLEND);
  glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
  glDisable(GL_SCISSOR_TEST);
  glUniform2f(g.uViewport, (float)g.logicalW, (float)g.logicalH);
  glUniform1f(g.uAA, 0.75f);
  glUniform1i(g.uTex, 0);

  for (int i = 0; i < g.controlCount; i++) {
    free(g.controls[i].id);
    free(g.controls[i].value);
    free(g.controls[i].options);
  }
  g.controlCount = 0;
  for (int i = 0; i < g.webviewCount; i++) {
    free(g.webviews[i].id);
    free(g.webviews[i].url);
  }
  g.webviewCount = 0;
  iso_wv_begin_frame();
}

void iso_webview_sync(const char *id, int id_len, const char *url, int url_len,
                      double x, double y, double w, double h) {
  char *idz = dupstr(id, id_len);
  char *urlz = dupstr(url, url_len);

  // If the embedded WebKitGTK browser is available, position a real browser
  // child window (in device pixels) over this rect and skip the fallback card.
  if (iso_wv_available()) {
    iso_wv_sync(idz, urlz, (int)(x * g.scale), (int)(y * g.scale),
                (int)(w * g.scale), (int)(h * g.scale));
    free(idz);
    free(urlz);
    return;
  }
  free(idz);
  free(urlz);

  if (g.webviewCount < 16) {
    WebViewEntry *v = &g.webviews[g.webviewCount++];
    v->id = dupstr(id, id_len);
    v->url = dupstr(url, url_len);
    v->x = x; v->y = y; v->w = w; v->h = h;
  }
  // No embedded browser (Wayland / WebKitGTK missing): draw a card that opens
  // the page in the system browser on tap.
  drawQuad(MODE_FILL, x, y, w, h, x + w / 2, y + h / 2, w / 2, h / 2, 10,
           0.96f, 0.96f, 0.98f, 1.0f);
  iso_stroke_rect(x, y, w, h, 10, 1, 0.0, 0.0, 0.0, 0.10);
  float cy = y + h / 2;
  iso_draw_text("Web page", 8, x + 20, cy - 34, w - 40, 26, 19, 700, 0.15, 0.16, 0.2, 1.0);
  char host[600];
  snprintf(host, sizeof(host), "%.*s", url_len, url);
  iso_draw_text(host, (int)strlen(host), x + 20, cy - 6, w - 40, 22, 14, 400, 0.3, 0.45, 0.9, 1.0);
  iso_draw_text("Tap to open in your browser", 27, x + 20, cy + 22, w - 40, 22, 13, 500,
                0.45, 0.45, 0.5, 1.0);
}

void iso_control_sync(const char *id, int id_len, const char *kind, int kind_len,
                      const char *value, int value_len,
                      const char *options, int options_len,
                      double x, double y, double w, double h) {
  Control *c = NULL;
  if (g.controlCount < 64) {
    c = &g.controls[g.controlCount++];
    c->id = dupstr(id, id_len);
    snprintf(c->kind, sizeof(c->kind), "%.*s", kind_len, kind);
    c->value = dupstr(value, value_len);
    c->options = dupstr(options, options_len);
    c->x = x; c->y = y; c->w = w; c->h = h;
  }
  int isSlider = kind_len >= 5 && strncmp(kind, "linux", 5) == 0 && strstr(kind, "trackbar");

  if (isSlider) {
    // A native-style horizontal slider (0...100) bound via LinuxViewRepresentable.
    float v = (float)atof(value) / 100.0f;
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    float midY = y + h / 2;
    float pad = 11, knob = 9;
    float trackX = x + pad, trackW = w - 2 * pad;
    drawQuad(MODE_FILL, trackX, midY - 2, trackW, 4, trackX + trackW / 2, midY, trackW / 2, 2, 2,
             0.0, 0.0, 0.0, 0.14);  // track
    float fillW = trackW * v;
    drawQuad(MODE_FILL, trackX, midY - 2, fillW, 4, trackX + fillW / 2, midY, fillW / 2, 2, 2,
             0.2, 0.45, 0.95, 1.0);  // filled portion
    float kx = trackX + trackW * v;
    drawQuad(MODE_FILL, kx - knob, midY - knob, knob * 2, knob * 2, kx, midY, knob, knob, knob,
             1.0, 1.0, 1.0, 1.0);
    iso_stroke_rect(kx - knob, midY - knob, knob * 2, knob * 2, knob, 1, 0.0, 0.0, 0.0, 0.18);
    return;
  }

  // Picker / Menu / DatePicker face: rounded background, value, chevron.
  char display[256] = {0};
  if (strncmp(kind, "picker", kind_len) == 0 || strncmp(kind, "menu", kind_len) == 0) {
    optionAt(options, atoi(value), display, sizeof(display));
  } else {
    snprintf(display, sizeof(display), "%.*s", value_len, value);
  }
  int open = c && g.popupId && strcmp(g.popupId, c->id) == 0;
  drawQuad(MODE_FILL, x, y, w, h, x + w / 2, y + h / 2, w / 2, h / 2, 6,
           0.45f, 0.55f, 0.95f, open ? 0.28f : 0.16f);
  if (display[0])
    iso_draw_text(display, (int)strlen(display), x + 10, y + (h - 17) / 2, w - 30, 20,
                  14, 500, 0.2, 0.35, 0.85, 1.0);
  iso_draw_text("▾", 3, x + w - 18, y + (h - 17) / 2, 16, 20, 12, 600,
                0.2, 0.35, 0.85, 1.0);  // ▾
}

#define ISO_ROW_H 30.0f
#define ISO_POP_PADV 6.0f

// Geometry of a Picker/Menu dropdown, shared by drawing and hit-testing so they
// always agree. Caps the height to the window and clamps the scroll offset.
static void dropdownGeom(float *opx, float *opy, float *opw, float *oph,
                         float *ocontentH, int *on) {
  int n = optionCount(g.popupOptions);
  if (n < 1) n = 1;
  float contentH = n * ISO_ROW_H + 2 * ISO_POP_PADV;
  float maxH = g.logicalH - 16;
  float popH = contentH < maxH ? contentH : maxH;
  float popW = g.popupW < 160 ? 160 : g.popupW;
  float popX = g.popupX;
  float popY = g.popupY + g.popupH + 4;
  if (popY + popH > g.logicalH - 8) popY = g.logicalH - 8 - popH;  // keep on screen
  if (popY < 8) popY = 8;
  if (popX + popW > g.logicalW - 8) popX = g.logicalW - 8 - popW;
  float maxScroll = contentH > popH ? contentH - popH : 0;
  if (g.popupScroll < 0) g.popupScroll = 0;
  if (g.popupScroll > maxScroll) g.popupScroll = maxScroll;
  *opx = popX; *opy = popY; *opw = popW; *oph = popH;
  *ocontentH = contentH; *on = n;
}

// Draw the open popup (if any), on top of everything, at the end of the frame.
void iso_host_sync_end(void) {
  // Tear down any embedded browser not synced this frame; while one is alive,
  // keep requesting frames so its GTK main loop is pumped (iso_wv_pump).
  if (iso_wv_end_frame() > 0) g.renderRequest = 1;
  if (!g.popupId) return;
  int isCal = strcmp(g.popupKind, "datepicker") == 0;
  float ax = g.popupX, ay = g.popupY, aw = g.popupW, ah = g.popupH;
  (void)aw;

  if (!isCal) {
    float popX, popY, popW, popH, contentH;
    int n;
    dropdownGeom(&popX, &popY, &popW, &popH, &contentH, &n);
    iso_draw_shadow(popX, popY, popW, popH, 8, 14, 0, 5, 0, 0, 0, 0.30);
    drawQuad(MODE_FILL, popX, popY, popW, popH, popX + popW / 2, popY + popH / 2, popW / 2,
             popH / 2, 8, 1.0, 1.0, 1.0, 1.0);
    iso_stroke_rect(popX, popY, popW, popH, 8, 1, 0.0, 0.0, 0.0, 0.12);
    int sel = atoi(g.popupValue);
    iso_push_clip(popX, popY, popW, popH, 8);
    for (int i = 0; i < n; i++) {
      float ry = popY + ISO_POP_PADV + i * ISO_ROW_H - g.popupScroll;
      if (ry + ISO_ROW_H < popY || ry > popY + popH) continue;  // cull off-screen rows
      char label[256];
      optionAt(g.popupOptions, i, label, sizeof(label));
      if (i == sel)
        drawQuad(MODE_FILL, popX + 4, ry, popW - 8, ISO_ROW_H, popX + popW / 2, ry + ISO_ROW_H / 2,
                 (popW - 8) / 2, ISO_ROW_H / 2, 5, 0.2, 0.45, 0.95, 0.14);
      iso_draw_text(label, (int)strlen(label), popX + 12, ry + (ISO_ROW_H - 17) / 2, popW - 24, 20,
                    14, i == sel ? 600 : 400, 0.15, 0.15, 0.2, 1.0);
    }
    iso_pop_clip();
  } else {
    // Month calendar.
    float popW = 252, popH = 268;
    float popX = ax;
    float popY = ay + ah + 4;
    if (popX + popW > g.logicalW) popX = g.logicalW - popW - 8;
    if (popY + popH > g.logicalH) popY = ay - popH - 4;
    iso_draw_shadow(popX, popY, popW, popH, 8, 14, 0, 5, 0, 0, 0, 0.30);
    drawQuad(MODE_FILL, popX, popY, popW, popH, popX + popW / 2, popY + popH / 2, popW / 2,
             popH / 2, 8, 1.0, 1.0, 1.0, 1.0);
    iso_stroke_rect(popX, popY, popW, popH, 8, 1, 0.0, 0.0, 0.0, 0.12);
    static const char *mn[] = {"January", "February", "March", "April", "May", "June", "July",
                               "August", "September", "October", "November", "December"};
    char hdr[64];
    snprintf(hdr, sizeof(hdr), "%s %d", mn[(g.calMonth - 1 + 12) % 12], g.calYear);
    iso_draw_text("‹", 3, popX + 12, popY + 10, 24, 24, 22, 700, 0.2, 0.35, 0.85, 1.0);  // ‹
    iso_draw_text(hdr, (int)strlen(hdr), popX + 44, popY + 14, popW - 88, 22, 15, 700,
                  0.15, 0.15, 0.2, 1.0);
    iso_draw_text("›", 3, popX + popW - 28, popY + 10, 24, 24, 22, 700, 0.2, 0.35, 0.85, 1.0);  // ›
    static const char *wd[] = {"S", "M", "T", "W", "T", "F", "S"};
    float gx = popX + 10, gy = popY + 44, cw = (popW - 20) / 7.0f, chh = 30;
    for (int i = 0; i < 7; i++)
      iso_draw_text(wd[i], 1, gx + i * cw, gy, cw, 18, 12, 600, 0.5, 0.5, 0.55, 1.0);
    int sel = atoi(g.popupValue + 8);  // day from "yyyy-MM-dd"
    int first = dayOfWeek(g.calYear, g.calMonth, 1);
    int dim = daysInMonth(g.calYear, g.calMonth);
    int selY = 0, selM = 0;
    sscanf(g.popupValue, "%d-%d", &selY, &selM);
    for (int d = 1; d <= dim; d++) {
      int cell = first + d - 1;
      float cx = gx + (cell % 7) * cw, cyy = gy + 22 + (cell / 7) * chh;
      char ds[4];
      snprintf(ds, sizeof(ds), "%d", d);
      if (d == sel && g.calYear == selY && g.calMonth == selM)
        drawQuad(MODE_FILL, cx + cw / 2 - 13, cyy - 4, 26, 26, cx + cw / 2, cyy + 9, 13, 13, 13,
                 0.2, 0.45, 0.95, 1.0);
      int white = (d == sel && g.calYear == selY && g.calMonth == selM);
      iso_draw_text(ds, (int)strlen(ds), cx, cyy, cw, 20, 13, 500,
                    white ? 1.0 : 0.15, white ? 1.0 : 0.15, white ? 1.0 : 0.2, 1.0);
    }
  }
}

static void closePopup(void) {
  free(g.popupId);
  g.popupId = NULL;
  free(g.popupOptions);
  g.popupOptions = NULL;
  g.renderRequest = 1;
}

// Route a pointer event to the host widgets (controls, popups, webviews, slider
// drag) before the runtime sees it. kind: 0=down, 1=up, 2=move. Returns 1 if a
// host widget consumed the event.
int iso_host_pointer(int kind, double px, double py) {
  // While a popup is open it owns all input.
  if (g.popupId) {
    if (kind != 1) return 1;  // consume down/move; act on up
    int isCal = strcmp(g.popupKind, "datepicker") == 0;
    float ax = g.popupX, ay = g.popupY, aw = g.popupW, ah = g.popupH;
    (void)ax; (void)ay; (void)aw; (void)ah;
    if (!isCal) {
      float popX, popY, popW, popH, contentH;
      int n;
      dropdownGeom(&popX, &popY, &popW, &popH, &contentH, &n);
      if (pointIn(px, py, popX, popY, popW, popH)) {
        int i = (int)((py - popY - ISO_POP_PADV + g.popupScroll) / ISO_ROW_H);
        if (i >= 0 && i < n && g.controlChangedCb) {
          char buf[16];
          snprintf(buf, sizeof(buf), "%d", i);
          g.controlChangedCb(g.popupId, (int)strlen(g.popupId), buf, (int)strlen(buf));
        }
      }
      closePopup();
    } else {
      float popW = 252, popH = 268, popX = ax, popY = ay + ah + 4;
      if (popX + popW > g.logicalW) popX = g.logicalW - popW - 8;
      if (popY + popH > g.logicalH) popY = ay - popH - 4;
      if (pointIn(px, py, popX + 4, popY + 6, 32, 30)) {  // ‹ prev month
        if (--g.calMonth < 1) { g.calMonth = 12; g.calYear--; }
        g.renderRequest = 1;
        return 1;
      }
      if (pointIn(px, py, popX + popW - 36, popY + 6, 32, 30)) {  // › next month
        if (++g.calMonth > 12) { g.calMonth = 1; g.calYear++; }
        g.renderRequest = 1;
        return 1;
      }
      float gx = popX + 10, gy = popY + 44, cw = (popW - 20) / 7.0f, chh = 30;
      int first = dayOfWeek(g.calYear, g.calMonth, 1), dim = daysInMonth(g.calYear, g.calMonth);
      int picked = 0;
      for (int d = 1; d <= dim && !picked; d++) {
        int cell = first + d - 1;
        float cx = gx + (cell % 7) * cw, cyy = gy + 18 + (cell / 7) * chh;
        if (pointIn(px, py, cx, cyy, cw, chh)) {
          char iso[16];
          snprintf(iso, sizeof(iso), "%04d-%02d-%02d", g.calYear, g.calMonth, d);
          if (g.controlChangedCb)
            g.controlChangedCb(g.popupId, (int)strlen(g.popupId), iso, (int)strlen(iso));
          picked = 1;
        }
      }
      if (pointIn(px, py, popX, popY, popW, popH)) {
        if (picked) closePopup();
        return 1;  // stay open for taps inside the calendar chrome
      }
      closePopup();  // tap outside dismisses
    }
    return 1;
  }

  // Slider drag.
  if (g.dragSliderId) {
    if (kind == 2 || kind == 0) {
      for (int i = 0; i < g.controlCount; i++) {
        Control *c = &g.controls[i];
        if (strcmp(c->id, g.dragSliderId) != 0) continue;
        float pad = 11, trackX = c->x + pad, trackW = c->w - 2 * pad;
        float v = trackW > 0 ? (px - trackX) / trackW : 0;
        if (v < 0) v = 0;
        if (v > 1) v = 1;
        if (g.controlChangedCb) {
          char buf[16];
          snprintf(buf, sizeof(buf), "%d", (int)(v * 100 + 0.5f));
          g.controlChangedCb(c->id, (int)strlen(c->id), buf, (int)strlen(buf));
        }
        break;
      }
      return 1;
    }
    if (kind == 1) { free(g.dragSliderId); g.dragSliderId = NULL; return 1; }
    return 1;
  }

  // Hit-test the controls / webviews.
  for (int i = 0; i < g.controlCount; i++) {
    Control *c = &g.controls[i];
    if (!pointIn(px, py, c->x, c->y, c->w, c->h)) continue;
    int isSlider = strstr(c->kind, "trackbar") != NULL;
    if (isSlider) {
      if (kind == 0) {  // begin drag + jump to position
        free(g.dragSliderId);
        g.dragSliderId = dupstr(c->id, -1);
        float pad = 11, trackX = c->x + pad, trackW = c->w - 2 * pad;
        float v = trackW > 0 ? (px - trackX) / trackW : 0;
        if (v < 0) v = 0;
        if (v > 1) v = 1;
        if (g.controlChangedCb) {
          char buf[16];
          snprintf(buf, sizeof(buf), "%d", (int)(v * 100 + 0.5f));
          g.controlChangedCb(c->id, (int)strlen(c->id), buf, (int)strlen(buf));
        }
      }
      return 1;
    }
    // picker / menu / datepicker: open the popup on release.
    if (kind == 1) {
      free(g.popupId);
      g.popupId = dupstr(c->id, -1);
      g.popupScroll = 0;
      // Open the dropdown scrolled so the selected option is visible.
      if (strcmp(c->kind, "datepicker") != 0) {
        int sel = atoi(c->value);
        float want = ISO_POP_PADV + sel * ISO_ROW_H - 120;
        g.popupScroll = want > 0 ? want : 0;
      }
      snprintf(g.popupKind, sizeof(g.popupKind), "%s", c->kind);
      snprintf(g.popupValue, sizeof(g.popupValue), "%s", c->value);
      free(g.popupOptions);
      g.popupOptions = dupstr(c->options, -1);
      g.popupX = c->x; g.popupY = c->y; g.popupW = c->w; g.popupH = c->h;
      if (strcmp(c->kind, "datepicker") == 0) {
        g.calYear = 2000;
        g.calMonth = 1;
        if (sscanf(c->value, "%d-%d", &g.calYear, &g.calMonth) < 2) {
          time_t t = time(NULL);
          struct tm tmv;
          localtime_r(&t, &tmv);
          g.calYear = tmv.tm_year + 1900;
          g.calMonth = tmv.tm_mon + 1;
        }
      }
      g.renderRequest = 1;
    }
    return 1;
  }
  for (int i = 0; i < g.webviewCount; i++) {
    WebViewEntry *v = &g.webviews[i];
    if (!pointIn(px, py, v->x, v->y, v->w, v->h)) continue;
    if (kind == 1 && v->url) iso_bridge_open_url(v->url, (int)strlen(v->url));
    return 1;
  }
  return 0;
}

int iso_take_render_request(void) {
  int r = g.renderRequest;
  g.renderRequest = 0;
  return r;
}

// ---------------------------------------------------------------------------
// Networking (libcurl on detached threads; results drained on the main thread)
// ---------------------------------------------------------------------------

typedef struct {
  int id;        // fetch id (>0) ; for images id==0 and key is set
  char *url;
  char *key;     // image cache key (image downloads only)
} NetTask;

struct MemBuf {
  unsigned char *data;
  size_t len;
};

static size_t writeCb(void *ptr, size_t size, size_t nmemb, void *userp) {
  size_t total = size * nmemb;
  struct MemBuf *m = (struct MemBuf *)userp;
  m->data = (unsigned char *)realloc(m->data, m->len + total + 1);
  memcpy(m->data + m->len, ptr, total);
  m->len += total;
  m->data[m->len] = 0;
  return total;
}

static void *netThread(void *arg) {
  NetTask *t = (NetTask *)arg;
  struct MemBuf buf = {NULL, 0};
  CURL *curl = curl_easy_init();
  long code = 0;
  if (curl) {
    curl_easy_setopt(curl, CURLOPT_URL, t->url);
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, writeCb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &buf);
    curl_easy_setopt(curl, CURLOPT_USERAGENT, "Isomer/1.0");
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);
    if (curl_easy_perform(curl) == CURLE_OK)
      curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &code);
    curl_easy_cleanup(curl);
  }
  int ok = (code >= 200 && code < 300);
  pthread_mutex_lock(&g.netMutex);
  if (t->key) {
    if (g.downloadCount < 64) {
      DownloadedImage *d = &g.downloads[g.downloadCount++];
      d->key = t->key;
      d->bytes = buf.data;
      d->len = (int)buf.len;
      d->ok = ok;
      buf.data = NULL;
    }
  } else {
    if (g.fetchCount < 64) {
      CompletedFetch *f = &g.fetches[g.fetchCount++];
      f->id = t->id;
      f->body = (char *)buf.data;
      f->len = (int)buf.len;
      f->ok = ok;
      buf.data = NULL;
    }
  }
  pthread_mutex_unlock(&g.netMutex);
  free(buf.data);
  free(t->url);
  free(t);
  return NULL;
}

static void startNet(NetTask *t) {
  pthread_t th;
  if (pthread_create(&th, NULL, netThread, t) == 0)
    pthread_detach(th);
  else {
    free(t->url);
    free(t->key);
    free(t);
  }
}

void iso_fetch(int request_id, const char *url, int url_len) {
  NetTask *t = (NetTask *)calloc(1, sizeof(NetTask));
  t->id = request_id;
  t->url = dupstr(url, url_len);
  startNet(t);
}

void iso_fetch_image(const char *key) {
  NetTask *t = (NetTask *)calloc(1, sizeof(NetTask));
  t->id = 0;
  t->url = dupstr(key, -1);  // remote image key is the URL
  t->key = dupstr(key, -1);
  startNet(t);
}

int iso_drain_fetches(void) {
  CompletedFetch local[64];
  int n = 0;
  pthread_mutex_lock(&g.netMutex);
  for (int i = 0; i < g.fetchCount; i++) local[n++] = g.fetches[i];
  g.fetchCount = 0;
  pthread_mutex_unlock(&g.netMutex);
  for (int i = 0; i < n; i++) {
    if (g.fetchCb) g.fetchCb(local[i].id, local[i].ok ? 1 : 0, local[i].body, local[i].len);
    free(local[i].body);
  }
  return n;
}

int iso_drain_images(void) {
  DownloadedImage local[64];
  int n = 0;
  pthread_mutex_lock(&g.netMutex);
  for (int i = 0; i < g.downloadCount; i++) local[n++] = g.downloads[i];
  g.downloadCount = 0;
  pthread_mutex_unlock(&g.netMutex);
  for (int i = 0; i < n; i++) {
    DownloadedImage *d = &local[i];
    if (d->ok && d->bytes && d->len > 0) {
      int w, h, ch;
      unsigned char *px = stbi_load_from_memory(d->bytes, d->len, &w, &h, &ch, 4);
      if (px) {
        GLuint tex = texFromRGBA(px, w, h);
        ImageEntry *e = putImage(d->key, tex, w, h, 1);
        e->rgba = px;  // retained for iso_rasterize (straight alpha)
      } else {
        putImage(d->key, 0, 0, 0, 2);
      }
    } else {
      putImage(d->key, 0, 0, 0, 2);
    }
    free(d->bytes);
    free(d->key);
  }
  return n;
}

// ---------------------------------------------------------------------------
// SwiftGPU rasterization: the services half of the SwiftGPU renderer —
// produce [w u32 LE][h u32 LE][PREMULTIPLIED RGBA8...] for text runs,
// gradients, shadows, and images. Text renders through SDL2_ttf (matching
// iso_measure_text's wrapping exactly), gradients and shadows are evaluated
// on the CPU, images come from the retained stb decodes. No GL calls here.
// ---------------------------------------------------------------------------

static unsigned char *g_rasterBuf = NULL;
static size_t g_rasterCap = 0;

static unsigned char *rasterAlloc(int w, int h) {
  size_t need = 8 + (size_t)w * h * 4;
  if (need > g_rasterCap) {
    g_rasterBuf = (unsigned char *)realloc(g_rasterBuf, need);
    g_rasterCap = need;
  }
  memset(g_rasterBuf, 0, need);
  g_rasterBuf[0] = (unsigned char)(w & 0xff);
  g_rasterBuf[1] = (unsigned char)((w >> 8) & 0xff);
  g_rasterBuf[2] = (unsigned char)((w >> 16) & 0xff);
  g_rasterBuf[3] = (unsigned char)((w >> 24) & 0xff);
  g_rasterBuf[4] = (unsigned char)(h & 0xff);
  g_rasterBuf[5] = (unsigned char)((h >> 8) & 0xff);
  g_rasterBuf[6] = (unsigned char)((h >> 16) & 0xff);
  g_rasterBuf[7] = (unsigned char)((h >> 24) & 0xff);
  return g_rasterBuf + 8;
}

static double rnum(const char *j, const char *key, double fallback) {
  const char *p = strstr(j, key);
  return p ? atof(p + strlen(key)) : fallback;
}

// Extract and unescape (\\ \" \n — see jsonEscapedGPU) a string field.
// Returns a malloc'd buffer and sets *afterValue past the closing quote so
// numeric keys can be searched AFTER it (user text may contain JSON-looking
// content like a literal "size": inside a comment).
static char *rstr(const char *j, const char *key, const char **afterValue) {
  const char *p = strstr(j, key);
  if (afterValue) *afterValue = j;
  if (!p) return NULL;
  p += strlen(key);
  size_t cap = strlen(p) + 1;
  char *out = (char *)malloc(cap);
  size_t n = 0;
  while (*p) {
    if (*p == '\\' && p[1]) {
      p++;
      out[n++] = (*p == 'n') ? '\n' : *p;
      p++;
    } else if (*p == '"') {
      p++;
      break;
    } else {
      out[n++] = *p++;
    }
  }
  out[n] = 0;
  if (afterValue) *afterValue = p;
  return out;
}

static int rasterText(const char *spec, int *outLen) {
  const char *after = spec;
  char *text = rstr(spec, "\"text\":\"", &after);
  if (!text) return 0;
  double size = rnum(after, "\"size\":", 15);
  double weight = rnum(after, "\"weight\":", 400);
  double wrap = rnum(after, "\"wrap\":", -1);
  double r = rnum(after, "\"r\":", 0), gg = rnum(after, "\"g\":", 0);
  double b = rnum(after, "\"b\":", 0), a = rnum(after, "\"a\":", 1);
  int px = (int)lround(size * g.scale);
  TTF_Font *font = fontFor(px, weight >= 600);
  if (!font || !text[0]) {
    free(text);
    return 0;
  }
  SDL_Color color = {(Uint8)lround(r * 255), (Uint8)lround(gg * 255),
                     (Uint8)lround(b * 255), 255};
  // +2 px of slack matches the legacy draw path, so re-wrapping at the
  // measured width never breaks one line earlier than measure did.
  Uint32 wrapPx = wrap > 0 ? (Uint32)lround(wrap * g.scale) + 2 : 0;
  SDL_Surface *surf = TTF_RenderUTF8_Blended_Wrapped(font, text, color, wrapPx);
  free(text);
  if (!surf) return 0;
  SDL_Surface *rgba = SDL_ConvertSurfaceFormat(surf, SDL_PIXELFORMAT_ABGR8888, 0);
  SDL_FreeSurface(surf);
  if (!rgba) return 0;
  unsigned char *dst = rasterAlloc(rgba->w, rgba->h);
  const unsigned char *src = (const unsigned char *)rgba->pixels;
  for (int row = 0; row < rgba->h; row++) {
    const unsigned char *s = src + (size_t)row * rgba->pitch;
    unsigned char *d = dst + (size_t)row * rgba->w * 4;
    for (int cpx = 0; cpx < rgba->w; cpx++) {
      double alpha = (s[cpx * 4 + 3] / 255.0) * a;  // straight -> premultiplied
      d[cpx * 4 + 0] = (unsigned char)lround(s[cpx * 4 + 0] * alpha);
      d[cpx * 4 + 1] = (unsigned char)lround(s[cpx * 4 + 1] * alpha);
      d[cpx * 4 + 2] = (unsigned char)lround(s[cpx * 4 + 2] * alpha);
      d[cpx * 4 + 3] = (unsigned char)lround(alpha * 255);
    }
  }
  *outLen = 8 + rgba->w * rgba->h * 4;
  SDL_FreeSurface(rgba);
  return 1;
}

// Rounded-rect signed distance (pixel space), for gradient/shadow coverage.
static double sdfRoundRect(double pxx, double pxy, double cx, double cy,
                           double hx, double hy, double rad) {
  double qx = fabs(pxx - cx) - (hx - rad);
  double qy = fabs(pxy - cy) - (hy - rad);
  double ox = qx > 0 ? qx : 0, oy = qy > 0 ? qy : 0;
  double inside = qx > qy ? qx : qy;
  return sqrt(ox * ox + oy * oy) + (inside < 0 ? inside : 0) - rad;
}

static int rasterGradient(const char *spec, int *outLen) {
  double w = rnum(spec, "\"w\":", 1), h = rnum(spec, "\"h\":", 1);
  double radius = rnum(spec, "\"radius\":", 0);
  const char *json = strstr(spec, "\"gradient\":");
  if (!json) return 0;
  int kind = 0;  // 0 linear, 1 radial, 2 angular
  if (strstr(json, "\"radial\"")) kind = 1;
  else if (strstr(json, "\"angular\"")) kind = 2;
  float p0[2] = {0, 0}, p1[2] = {0, 1}, c[2] = {0.5f, 0.5f};
  float sr = 0, er = (float)fmax(w, h) / 2, a0 = 0;
  const char *s;
  if ((s = strstr(json, "\"p0\":["))) sscanf(s + 6, "%f,%f", &p0[0], &p0[1]);
  if ((s = strstr(json, "\"p1\":["))) sscanf(s + 6, "%f,%f", &p1[0], &p1[1]);
  if ((s = strstr(json, "\"c\":["))) sscanf(s + 5, "%f,%f", &c[0], &c[1]);
  if ((s = strstr(json, "\"sr\":"))) sscanf(s + 5, "%f", &sr);
  if ((s = strstr(json, "\"er\":"))) sscanf(s + 5, "%f", &er);
  if ((s = strstr(json, "\"a0\":"))) sscanf(s + 5, "%f", &a0);
  float stopCol[ISO_MAX_STOPS][4];
  float stopLoc[ISO_MAX_STOPS];
  int n = 0;
  const char *p = strstr(json, "\"stops\":[");
  if (p) {
    p += 9;
    while (n < ISO_MAX_STOPS) {
      const char *cc = strstr(p, "\"c\":[");
      if (!cc) break;
      float cr, cg, cb, ca, l = 0;
      if (sscanf(cc + 5, "%f,%f,%f,%f", &cr, &cg, &cb, &ca) != 4) break;
      const char *ll = strstr(cc, "\"l\":");
      if (ll) sscanf(ll + 4, "%f", &l);
      stopCol[n][0] = cr; stopCol[n][1] = cg; stopCol[n][2] = cb; stopCol[n][3] = ca;
      stopLoc[n] = l;
      n++;
      const char *next = ll ? ll + 4 : cc + 5;
      const char *brk = strchr(next, '}');
      if (!brk) break;
      p = brk + 1;
      if (*p != ',') break;
    }
  }
  if (n == 0) return 0;

  int pw = (int)lround(w * g.scale), ph = (int)lround(h * g.scale);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  double rad = fmin(radius, fmin(w, h) / 2) * g.scale;
  unsigned char *dst = rasterAlloc(pw, ph);
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      // Gradient parameter in unit/point space (logical points).
      double lx = (x + 0.5) / g.scale, ly = (y + 0.5) / g.scale;
      double t = 0;
      if (kind == 1) {
        double dx = lx - c[0] * w, dy = ly - c[1] * h;
        double span = er - sr;
        t = span > 0.0001 ? (sqrt(dx * dx + dy * dy) - sr) / span : 1.0;
      } else if (kind == 2) {
        double dx = lx - c[0] * w, dy = ly - c[1] * h;
        double ang = atan2(dy, dx) - a0;
        while (ang < 0) ang += 6.2831853;
        t = ang / 6.2831853;
      } else {
        double dx = (p1[0] - p0[0]) * w, dy = (p1[1] - p0[1]) * h;
        double len2 = dx * dx + dy * dy;
        t = len2 > 0.0001 ? ((lx - p0[0] * w) * dx + (ly - p0[1] * h) * dy) / len2 : 0;
      }
      if (t < 0) t = 0;
      if (t > 1) t = 1;
      // Interpolate the stops.
      float col[4];
      if (t <= stopLoc[0]) {
        memcpy(col, stopCol[0], sizeof(col));
      } else if (t >= stopLoc[n - 1]) {
        memcpy(col, stopCol[n - 1], sizeof(col));
      } else {
        int i = 0;
        while (i < n - 1 && stopLoc[i + 1] < t) i++;
        float span = stopLoc[i + 1] - stopLoc[i];
        float f = span > 0.0001f ? ((float)t - stopLoc[i]) / span : 0;
        for (int k = 0; k < 4; k++) col[k] = stopCol[i][k] + (stopCol[i + 1][k] - stopCol[i][k]) * f;
      }
      // Rounded-rect coverage (AA edge).
      double d = sdfRoundRect(x + 0.5, y + 0.5, pw / 2.0, ph / 2.0, pw / 2.0, ph / 2.0, rad);
      double coverage = 0.5 - d;
      if (coverage < 0) coverage = 0;
      if (coverage > 1) coverage = 1;
      double alpha = col[3] * coverage;
      unsigned char *o = dst + ((size_t)y * pw + x) * 4;
      o[0] = (unsigned char)lround(col[0] * alpha * 255);
      o[1] = (unsigned char)lround(col[1] * alpha * 255);
      o[2] = (unsigned char)lround(col[2] * alpha * 255);
      o[3] = (unsigned char)lround(alpha * 255);
    }
  }
  *outLen = 8 + pw * ph * 4;
  return 1;
}

// One box-blur pass (radius r) along n values.
static void boxBlur1D(float *values, float *scratch, int n, int r) {
  if (r <= 0 || n <= 0) return;
  double window = 2.0 * r + 1.0;
  double sum = 0;
  for (int i = -r; i <= r; i++) sum += values[i < 0 ? 0 : (i >= n ? n - 1 : i)];
  for (int i = 0; i < n; i++) {
    scratch[i] = (float)(sum / window);
    int add = i + r + 1;
    int drop = i - r;
    sum += values[add >= n ? n - 1 : add] - values[drop < 0 ? 0 : drop];
  }
  memcpy(values, scratch, (size_t)n * sizeof(float));
}

// CPU Gaussian drop shadow: rounded-rect SDF coverage, triple box blur
// (sigma = blur/2, matching the other hosts), tinted premultiplied.
static int rasterShadow(const char *spec, int *outLen) {
  double w = rnum(spec, "\"w\":", 1), h = rnum(spec, "\"h\":", 1);
  double corner = rnum(spec, "\"corner\":", 0), blur = rnum(spec, "\"blur\":", 0);
  double r = rnum(spec, "\"r\":", 0), gg = rnum(spec, "\"g\":", 0);
  double b = rnum(spec, "\"b\":", 0), a = rnum(spec, "\"a\":", 1);
  double pad = blur * 2;  // matches SwiftGPURenderer's dest margin
  int pw = (int)lround((w + pad * 2) * g.scale);
  int ph = (int)lround((h + pad * 2) * g.scale);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;
  if ((long long)pw * ph > 16 * 1024 * 1024) return 0;

  float *mask = (float *)malloc((size_t)pw * ph * sizeof(float));
  double rectW = w * g.scale, rectH = h * g.scale;
  double rad = fmin(corner * g.scale, fmin(rectW, rectH) / 2);
  double cx = pad * g.scale + rectW / 2, cy = pad * g.scale + rectH / 2;
  for (int y = 0; y < ph; y++) {
    for (int x = 0; x < pw; x++) {
      double d = sdfRoundRect(x + 0.5, y + 0.5, cx, cy, rectW / 2, rectH / 2, rad);
      double coverage = 0.5 - d;
      mask[(size_t)y * pw + x] = (float)(coverage < 0 ? 0 : (coverage > 1 ? 1 : coverage));
    }
  }
  double sigma = blur * 0.5 * g.scale;
  int boxR = (int)lround(sigma);
  if (boxR < 1 && sigma > 0.1) boxR = 1;
  if (boxR > 0) {
    int longest = pw > ph ? pw : ph;
    float *strip = (float *)malloc((size_t)longest * sizeof(float));
    float *scratch = (float *)malloc((size_t)longest * sizeof(float));
    for (int pass = 0; pass < 3; pass++) {
      for (int y = 0; y < ph; y++) boxBlur1D(mask + (size_t)y * pw, scratch, pw, boxR);
      for (int x = 0; x < pw; x++) {
        for (int y = 0; y < ph; y++) strip[y] = mask[(size_t)y * pw + x];
        boxBlur1D(strip, scratch, ph, boxR);
        for (int y = 0; y < ph; y++) mask[(size_t)y * pw + x] = strip[y];
      }
    }
    free(strip);
    free(scratch);
  }
  unsigned char *dst = rasterAlloc(pw, ph);
  for (size_t i = 0; i < (size_t)pw * ph; i++) {
    double alpha = a * mask[i];
    dst[i * 4 + 0] = (unsigned char)lround(r * alpha * 255);  // premultiplied
    dst[i * 4 + 1] = (unsigned char)lround(gg * alpha * 255);
    dst[i * 4 + 2] = (unsigned char)lround(b * alpha * 255);
    dst[i * 4 + 3] = (unsigned char)lround(alpha * 255);
  }
  free(mask);
  *outLen = 8 + pw * ph * 4;
  return 1;
}

static int rasterImage(const char *spec, int *outLen) {
  char *source = rstr(spec, "\"source\":\"", NULL);
  if (!source) return 0;
  ImageEntry *e = findImage(source);
  free(source);
  if (!e || e->status != 1 || !e->rgba) return 0;
  unsigned char *dst = rasterAlloc(e->w, e->h);
  const unsigned char *src = e->rgba;
  for (size_t i = 0; i < (size_t)e->w * e->h; i++) {
    double alpha = src[i * 4 + 3] / 255.0;  // straight (stb) -> premultiplied
    dst[i * 4 + 0] = (unsigned char)lround(src[i * 4 + 0] * alpha);
    dst[i * 4 + 1] = (unsigned char)lround(src[i * 4 + 1] * alpha);
    dst[i * 4 + 2] = (unsigned char)lround(src[i * 4 + 2] * alpha);
    dst[i * 4 + 3] = src[i * 4 + 3];
  }
  *outLen = 8 + e->w * e->h * 4;
  return 1;
}

const unsigned char *iso_rasterize(const char *spec, int spec_len, int *out_len) {
  *out_len = 0;
  char *z = dupstr(spec, spec_len);  // NUL-terminate for the strstr scans
  if (!z) return NULL;
  int len = 0, ok = 0;
  if (strstr(z, "\"kind\":\"text\"")) ok = rasterText(z, &len);
  else if (strstr(z, "\"kind\":\"gradient\"")) ok = rasterGradient(z, &len);
  else if (strstr(z, "\"kind\":\"shadow\"")) ok = rasterShadow(z, &len);
  else if (strstr(z, "\"kind\":\"image\"")) ok = rasterImage(z, &len);
  free(z);
  if (!ok || len <= 8) return NULL;
  *out_len = len;
  return g_rasterBuf;
}

// ---------------------------------------------------------------------------
// IsomerBridge
// ---------------------------------------------------------------------------

void iso_bridge_log(const char *message, int len) {
  fprintf(stderr, "[iso] %.*s\n", len, message);
}

double iso_bridge_epoch_millis(void) {
  struct timespec ts;
  clock_gettime(CLOCK_REALTIME, &ts);
  return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

void iso_bridge_open_url(const char *url, int len) {
  char *u = dupstr(url, len);
  char cmd[4200];
  snprintf(cmd, sizeof(cmd), "xdg-open '%s' >/dev/null 2>&1 &", u);
  int rc = system(cmd);
  (void)rc;
  free(u);
}
