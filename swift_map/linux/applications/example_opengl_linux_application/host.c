// The SDL2 half of the native Linux SwiftMap example: window, core-3.3 GL
// context, input events, buffer swap, and the attribution text raster the
// OSM tile policy requires. Rendering happens in Swift through swift_gpu's
// GL backend; this file only owns the surface (the same host/backend
// division the Android GLSurfaceView uses).

#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

#include <stdlib.h>
#include <string.h>

static SDL_Window *g_window = NULL;
static SDL_GLContext g_gl = NULL;
static double g_scale = 1.0;

static void (*g_pointer)(int phase, double x, double y) = NULL;
static void (*g_wheel)(double x, double y, double delta) = NULL;
static void (*g_resize)(void) = NULL;

void smw_set_pointer_callback(void (*cb)(int, double, double)) { g_pointer = cb; }
void smw_set_wheel_callback(void (*cb)(double, double, double)) { g_wheel = cb; }
void smw_set_resize_callback(void (*cb)(void)) { g_resize = cb; }

static void refreshScale(void) {
  int ww = 0, wh = 0, dw = 0, dh = 0;
  SDL_GetWindowSize(g_window, &ww, &wh);
  SDL_GL_GetDrawableSize(g_window, &dw, &dh);
  g_scale = (ww > 0) ? (double)dw / (double)ww : 1.0;
  if (g_scale < 0.5) g_scale = 1.0;
}

int smw_create(int width, int height, const char *title) {
  if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) != 0) return 0;
  TTF_Init();
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  g_window = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                              width, height,
                              SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALLOW_HIGHDPI);
  if (!g_window) return 0;
  g_gl = SDL_GL_CreateContext(g_window);
  if (!g_gl) return 0;
  SDL_GL_SetSwapInterval(1);
  refreshScale();
  return 1;
}

void smw_size_px(int *out_width, int *out_height) {
  int dw = 0, dh = 0;
  if (g_window) SDL_GL_GetDrawableSize(g_window, &dw, &dh);
  *out_width = dw;
  *out_height = dh;
}

double smw_scale(void) { return g_scale; }

void smw_swap(void) { SDL_GL_SwapWindow(g_window); }

// Pump events into the callbacks, blocking up to `timeout_ms` for the first
// (0 = poll). Returns 0 once the window closes.
int smw_poll(int timeout_ms) {
  SDL_Event e;
  int got = timeout_ms > 0 ? SDL_WaitEventTimeout(&e, timeout_ms) : SDL_PollEvent(&e);
  while (got) {
    switch (e.type) {
      case SDL_QUIT:
        return 0;
      case SDL_MOUSEBUTTONDOWN:
        if (e.button.button == SDL_BUTTON_LEFT && g_pointer) g_pointer(0, e.button.x, e.button.y);
        break;
      case SDL_MOUSEMOTION:
        if ((e.motion.state & SDL_BUTTON_LMASK) && g_pointer) g_pointer(1, e.motion.x, e.motion.y);
        break;
      case SDL_MOUSEBUTTONUP:
        if (e.button.button == SDL_BUTTON_LEFT && g_pointer) g_pointer(2, e.button.x, e.button.y);
        break;
      case SDL_MOUSEWHEEL: {
        int mx = 0, my = 0;
        SDL_GetMouseState(&mx, &my);
        if (g_wheel) g_wheel(mx, my, (double)e.wheel.y);
        break;
      }
      case SDL_WINDOWEVENT:
        if (e.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
          refreshScale();
          if (g_resize) g_resize();
        }
        break;
      default:
        break;
    }
    got = SDL_PollEvent(&e);
  }
  return 1;
}

// Rasterize the attribution line once (DejaVu Sans; both distro layouts) as
// straight-alpha RGBA. The Swift side premultiplies and uploads a texture.
unsigned char *smw_attribution_rgba(const char *text, int *out_width, int *out_height) {
  const char *candidates[] = {
      "/usr/share/fonts/TTF/DejaVuSans.ttf",
      "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
  };
  TTF_Font *font = NULL;
  for (unsigned i = 0; i < sizeof(candidates) / sizeof(candidates[0]) && !font; i++) {
    font = TTF_OpenFont(candidates[i], (int)(13 * g_scale));
  }
  if (!font) return NULL;
  SDL_Color dark = {40, 40, 45, 255};
  SDL_Surface *surf = TTF_RenderUTF8_Blended(font, text, dark);
  TTF_CloseFont(font);
  if (!surf) return NULL;
  SDL_Surface *rgba = SDL_ConvertSurfaceFormat(surf, SDL_PIXELFORMAT_ABGR8888, 0);
  SDL_FreeSurface(surf);
  if (!rgba) return NULL;
  unsigned char *out = (unsigned char *)malloc((size_t)rgba->w * rgba->h * 4);
  for (int row = 0; row < rgba->h; row++) {
    memcpy(out + (size_t)row * rgba->w * 4,
           (const unsigned char *)rgba->pixels + (size_t)row * rgba->pitch,
           (size_t)rgba->w * 4);
  }
  *out_width = rgba->w;
  *out_height = rgba->h;
  SDL_FreeSurface(rgba);
  return out;
}

void smw_free_rgba(unsigned char *pixels) { free(pixels); }
