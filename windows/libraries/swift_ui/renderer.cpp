// Native Windows host + renderer for isomer.
//
// A Win32 window hosting a Direct2D / DirectWrite / WIC renderer. The runtime
// (via WindowsHost.swift) calls the flat C API in renderer.h to drive a window,
// pump events, and replay the per-frame draw list. Direct2D natively supports
// every display-list primitive the core emits (rounded rects, strokes,
// gradients, text, images, clips, affine transforms), so the renderer is a thin
// translation rather than a hand-written GPU pipeline.

#ifndef NOMINMAX
#define NOMINMAX
#endif
// Use the wide (UTF-16) Win32 API surface throughout, so resource macros like
// `IDC_ARROW` expand to their `LPCWSTR` form. (Not WIN32_LEAN_AND_MEAN: the full
// <windows.h> is what pulls in the COM headers for CLSCTX / CoCreateInstance.)
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
// Raise the API level (the cc toolchain defaults to 0x0601 / Windows 7) so the
// Windows 10 per-monitor DPI APIs are declared.
#undef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#undef WINVER
#define WINVER 0x0A00

#include <windows.h>
// <windows.h> defines `DrawText` as a macro (`DrawTextW`). Undefine it before
// including <d2d1.h> so `ID2D1RenderTarget::DrawText` keeps its real name.
#undef DrawText
#include <windowsx.h>
#include <shellapi.h>
#include <objbase.h>
#include <winhttp.h>
#include <dbghelp.h>
#include <d2d1.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <d2d1helper.h>
#include <dwrite.h>
#include <wincodec.h>
// WebView host: the classic in-process WebBrowser ActiveX control (Trident),
// embedded via OLE in-place activation. Needs no external SDK (unlike WebView2).
#include <exdisp.h>     // IWebBrowser2, CLSID_WebBrowser
#include <mshtmhst.h>   // IDocHostUIHandler
#include <docobj.h>     // IOleInPlaceFrame / IOleInPlaceSite
#include <ole2.h>
#include <commctrl.h>   // COMBOBOX item messages, SysDateTimePick32 (Picker/DatePicker)
#include <cstdio>       // sscanf / snprintf for control value formatting
#include <cstdlib>

#include <string>
#include <vector>
#include <unordered_map>
#include <cmath>
#include <mutex>
#include <thread>
#include <deque>
#include <condition_variable>
#include <fstream>

#include "windows/libraries/swift_ui/renderer.h"

// This toolchain's header configuration declares CoCreateInstance but doesn't
// always surface the CLSCTX enum values; it is a stable COM ABI constant.
#ifndef CLSCTX_INPROCESS_SERVER
#define CLSCTX_INPROCESS_SERVER 0x1
#endif

namespace {

template <class T>
void SafeRelease(T** pp) {
  if (*pp) {
    (*pp)->Release();
    *pp = nullptr;
  }
}

// --- Global renderer state ----------------------------------------------

struct CompletedFetch {
  int id;
  bool ok;
  std::string body;
};

struct DownloadedImage {
  std::string key;
  bool ok;
  std::string bytes;
};

// A queued HTTP GET handled by the bounded worker pool.
struct HttpTask {
  bool isImage;  // false = fetch (id), true = image download (key)
  int id;
  std::string key;
  std::wstring url;
};

struct Renderer {
  HWND hwnd = nullptr;
  // D2D draws only offscreen now (iso_rasterize's WIC targets): drawing to
  // the window is SwiftGPU's job (swift_gpu's D3D11 swapchain on this HWND).
  ID2D1Factory* d2dFactory = nullptr;
  IDWriteFactory* dwriteFactory = nullptr;
  IWICImagingFactory* wicFactory = nullptr;

  // Current logical client size (DIPs) and device pixel scale (DPI / 96).
  double width = 0;
  double height = 0;
  float dpiScale = 1.0f;

  // Caches keyed by (fontSize, weight) and image source. Image pixels stay
  // encoded (g_imageEncoded) until iso_rasterize decodes them; only status
  // and dimensions live here.
  std::unordered_map<uint64_t, IDWriteTextFormat*> textFormats;
  std::unordered_map<std::string, std::pair<UINT, UINT>> imageDims;
  std::unordered_map<std::string, int> imageStatus;  // 0 loading, 1 ready, 2 failed

  iso_pointer_callback pointerCb = nullptr;
  iso_wheel_callback wheelCb = nullptr;
  iso_resize_callback resizeCb = nullptr;
  iso_paint_callback paintCb = nullptr;
  iso_control_changed_callback controlChangedCb = nullptr;

  // Async fetch results, produced on worker threads and drained on the main
  // thread so completion callbacks run where the runtime expects them.
  iso_fetch_callback fetchCb = nullptr;
  std::mutex fetchMutex;
  std::vector<CompletedFetch> completedFetches;

  // Text input: a native EDIT child overlays the drawn field between
  // begin/end; edits flow back through these callbacks (EN_CHANGE / Enter).
  iso_text_changed_callback textChangedCb = nullptr;
  iso_text_submit_callback textSubmitCb = nullptr;

  // Effective color scheme, reported by the runtime; styles the text overlay.
  bool darkScheme = false;

  // Remote image downloads: started lazily, decoded on the main thread.
  std::unordered_map<std::string, bool> imageRequested;
  std::mutex imageMutex;
  std::vector<DownloadedImage> downloadedImages;

  // Bounded HTTP worker pool (fetch + image downloads). A fixed set of workers
  // drains `httpQueue`, instead of spawning one thread per request — which
  // under heavy scrolling could create hundreds of threads/sessions.
  bool workersStarted = false;
  std::mutex queueMutex;
  std::condition_variable queueCv;
  std::deque<HttpTask> httpQueue;
};

// Leaked intentionally: detached worker threads outlive `main`, so the globals
// (mutexes / condition variable) must never be destroyed underneath them at
// static-destruction time.
Renderer& g = *(new Renderer());

D2D1_COLOR_F Color(double r, double gg, double b, double a) {
  return D2D1::ColorF(static_cast<float>(r), static_cast<float>(gg),
                      static_cast<float>(b), static_cast<float>(a));
}

D2D1_RECT_F Rect(double x, double y, double w, double h) {
  return D2D1::RectF(static_cast<float>(x), static_cast<float>(y),
                     static_cast<float>(x + w), static_cast<float>(y + h));
}

std::wstring Widen(const char* s, int len) {
  if (len <= 0) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s, len, nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s, len, &out[0], n);
  return out;
}

std::string Narrow(const std::wstring& s) {
  if (s.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0, nullptr, nullptr);
  std::string out(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), &out[0], n,
                      nullptr, nullptr);
  return out;
}

// --- Text input overlay ---------------------------------------------------
// The focused TextField is a real EDIT child window positioned over the drawn
// field: the display list draws the field box and focus ring but not the value
// while focused — the overlay owns the live text, caret, selection, and IME
// (mirroring the web host's visible DOM input overlay in boot.js).

HWND g_textEdit = nullptr;
WNDPROC g_textEditBaseProc = nullptr;
HFONT g_textEditFont = nullptr;
float g_textEditFontScale = 0.0f;
double g_textEditFontSize = 0.0;
HBRUSH g_textEditBrush = nullptr;
bool g_textEditBrushDark = false;
bool g_textEditSyncing = false;  // suppress EN_CHANGE from programmatic sets

// Subclass: Enter submits (a single-line EDIT otherwise just beeps).
LRESULT CALLBACK TextEditProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_KEYDOWN && wParam == VK_RETURN) {
    if (g.textSubmitCb) g.textSubmitCb();
    return 0;
  }
  if (msg == WM_CHAR && (wParam == 0x0D || wParam == 0x1B)) return 0;  // no beep
  return CallWindowProcW(g_textEditBaseProc, hwnd, msg, wParam, lParam);
}

void NotifyTextEditChanged() {
  if (!g.textChangedCb || !g_textEdit || g_textEditSyncing) return;
  int len = GetWindowTextLengthW(g_textEdit);
  std::wstring text(static_cast<size_t>(len) + 1, L'\0');
  GetWindowTextW(g_textEdit, &text[0], len + 1);
  text.resize(len);
  std::string utf8 = Narrow(text);
  g.textChangedCb(utf8.c_str(), static_cast<int>(utf8.size()));
}

IDWriteTextFormat* TextFormat(double fontSize, int weight) {
  uint64_t key = (static_cast<uint64_t>(static_cast<int>(fontSize * 100)) << 16) ^
                 static_cast<uint64_t>(weight);
  auto it = g.textFormats.find(key);
  if (it != g.textFormats.end()) return it->second;
  IDWriteTextFormat* fmt = nullptr;
  DWRITE_FONT_WEIGHT w = static_cast<DWRITE_FONT_WEIGHT>(weight <= 0 ? 400 : weight);
  g.dwriteFactory->CreateTextFormat(
      L"Segoe UI", nullptr, w, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
      static_cast<float>(fontSize), L"en-us", &fmt);
  g.textFormats[key] = fmt;
  return fmt;
}

// --- WIC image decoding -------------------------------------------------

// --- Bundled asset resolution (Bazel runfiles manifest) -------------------
// Windows runfiles are a MANIFEST (no symlinked tree), so a bundled-image name
// like "tab-gallery" must be mapped to its real .png path. Parse the manifest
// once into a map from imageset base name -> the highest-scale real file path.

std::unordered_map<std::string, std::wstring> g_assetPaths;
bool g_assetsLoaded = false;

std::wstring ManifestPath() {
  wchar_t env[32767];
  DWORD n = GetEnvironmentVariableW(L"RUNFILES_MANIFEST_FILE", env, 32767);
  if (n > 0 && n < 32767) return std::wstring(env, n);
  wchar_t exe[MAX_PATH];
  DWORD en = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  std::wstring base(exe, en);
  std::wstring c1 = base + L".runfiles\\MANIFEST";
  if (GetFileAttributesW(c1.c_str()) != INVALID_FILE_ATTRIBUTES) return c1;
  std::wstring c2 = base + L".runfiles_manifest";
  if (GetFileAttributesW(c2.c_str()) != INVALID_FILE_ATTRIBUTES) return c2;
  return L"";
}

void LoadAssets() {
  if (g_assetsLoaded) return;
  g_assetsLoaded = true;
  std::wstring manifest = ManifestPath();
  if (manifest.empty()) return;
  std::ifstream in(manifest.c_str());
  if (!in) return;
  std::unordered_map<std::string, int> bestScale;
  std::string line;
  while (std::getline(in, line)) {
    // "<runfiles-path> <real-path>"; the asset paths have no embedded spaces.
    size_t sp = line.find(' ');
    if (sp == std::string::npos) continue;
    std::string rf = line.substr(0, sp);
    std::string real = line.substr(sp + 1);
    if (!real.empty() && real.back() == '\r') real.pop_back();
    // Match ".../<X>.imageset/<X>[@Nx].png" and key by the imageset name <X>.
    const std::string marker = ".imageset/";
    size_t ip = rf.find(marker);
    if (ip == std::string::npos) continue;
    if (rf.size() < 4 || rf.compare(rf.size() - 4, 4, ".png") != 0) continue;
    size_t nameStart = (ip == 0) ? std::string::npos : rf.rfind('/', ip - 1);
    std::string setName = (nameStart == std::string::npos)
                              ? rf.substr(0, ip)
                              : rf.substr(nameStart + 1, ip - nameStart - 1);
    int scale = 1;
    if (rf.find("@2x.png") != std::string::npos) scale = 2;
    else if (rf.find("@3x.png") != std::string::npos) scale = 3;
    auto bs = bestScale.find(setName);
    if (bs == bestScale.end() || scale > bs->second) {
      bestScale[setName] = scale;
      for (auto& ch : real) if (ch == '/') ch = '\\';
      g_assetPaths[setName] = Widen(real.c_str(), static_cast<int>(real.size()));
    }
  }
}

// Real path for a bundled asset name, or empty if it isn't a known imageset.
std::wstring ResolveAssetPath(const std::string& name) {
  LoadAssets();
  auto it = g_assetPaths.find(name);
  return it == g_assetPaths.end() ? std::wstring() : it->second;
}

// Probe an image's pixel dimensions (for imageInfo — layout only needs
// status + size; iso_rasterize decodes the actual pixels on demand).
bool ProbeImageDimsFile(const std::wstring& path, UINT* outW, UINT* outH) {
  if (!g.wicFactory) return false;
  IWICBitmapDecoder* decoder = nullptr;
  if (FAILED(g.wicFactory->CreateDecoderFromFilename(
          path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad, &decoder))) {
    return false;
  }
  IWICBitmapFrameDecode* frame = nullptr;
  bool ok = SUCCEEDED(decoder->GetFrame(0, &frame)) && frame &&
            SUCCEEDED(frame->GetSize(outW, outH));
  SafeRelease(&frame);
  SafeRelease(&decoder);
  return ok && *outW > 0 && *outH > 0;
}

bool ProbeImageDimsMemory(const std::string& bytes, UINT* outW, UINT* outH) {
  if (!g.wicFactory || bytes.empty()) return false;
  IWICStream* stream = nullptr;
  if (FAILED(g.wicFactory->CreateStream(&stream))) return false;
  bool ok = false;
  if (SUCCEEDED(stream->InitializeFromMemory(
          reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data())),
          static_cast<DWORD>(bytes.size())))) {
    IWICBitmapDecoder* decoder = nullptr;
    IWICBitmapFrameDecode* frame = nullptr;
    if (SUCCEEDED(g.wicFactory->CreateDecoderFromStream(
            stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)) &&
        SUCCEEDED(decoder->GetFrame(0, &frame)) && frame) {
      ok = SUCCEEDED(frame->GetSize(outW, outH)) && *outW > 0 && *outH > 0;
    }
    SafeRelease(&frame);
    SafeRelease(&decoder);
  }
  SafeRelease(&stream);
  return ok;
}

// --- Networking (synchronous WinHTTP GET, run on a worker thread) -------

bool HttpGet(const std::wstring& url, std::string& out) {
  URL_COMPONENTS uc = {};
  uc.dwStructSize = sizeof(uc);
  wchar_t host[256] = {};
  wchar_t path[2048] = {};
  uc.lpszHostName = host;
  uc.dwHostNameLength = ARRAYSIZE(host);
  uc.lpszUrlPath = path;
  uc.dwUrlPathLength = ARRAYSIZE(path);
  if (!WinHttpCrackUrl(url.c_str(), 0, 0, &uc)) return false;

  bool secure = uc.nScheme == INTERNET_SCHEME_HTTPS;
  HINTERNET session = WinHttpOpen(L"isomer/1.0",
                                  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                  WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
  if (!session) return false;
  HINTERNET connect = WinHttpConnect(session, host, uc.nPort, 0);
  HINTERNET request = nullptr;
  bool ok = false;
  if (connect) {
    request = WinHttpOpenRequest(connect, L"GET", path, nullptr, WINHTTP_NO_REFERER,
                                 WINHTTP_DEFAULT_ACCEPT_TYPES,
                                 secure ? WINHTTP_FLAG_SECURE : 0);
  }
  if (request &&
      WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                         WINHTTP_NO_REQUEST_DATA, 0, 0, 0) &&
      WinHttpReceiveResponse(request, nullptr)) {
    DWORD avail = 0;
    ok = true;
    do {
      avail = 0;
      if (!WinHttpQueryDataAvailable(request, &avail)) {
        ok = false;
        break;
      }
      if (avail == 0) break;
      std::string chunk(avail, '\0');
      DWORD read = 0;
      if (!WinHttpReadData(request, &chunk[0], avail, &read)) {
        ok = false;
        break;
      }
      out.append(chunk.data(), read);
    } while (avail > 0);
  }
  if (request) WinHttpCloseHandle(request);
  if (connect) WinHttpCloseHandle(connect);
  WinHttpCloseHandle(session);
  return ok;
}

void HttpWorkerLoop() {
  for (;;) {
    HttpTask task;
    {
      std::unique_lock<std::mutex> lock(g.queueMutex);
      g.queueCv.wait(lock, [] { return !g.httpQueue.empty(); });
      task = std::move(g.httpQueue.front());
      g.httpQueue.pop_front();
    }
    std::string body;
    bool ok = HttpGet(task.url, body);
    if (task.isImage) {
      std::lock_guard<std::mutex> lock(g.imageMutex);
      g.downloadedImages.push_back({task.key, ok, std::move(body)});
    } else {
      std::lock_guard<std::mutex> lock(g.fetchMutex);
      g.completedFetches.push_back({task.id, ok, std::move(body)});
    }
  }
}

void EnqueueHttp(HttpTask task) {
  {
    std::lock_guard<std::mutex> lock(g.queueMutex);
    if (!g.workersStarted) {
      g.workersStarted = true;
      for (int i = 0; i < 6; ++i) std::thread(HttpWorkerLoop).detach();
    }
    g.httpQueue.push_back(std::move(task));
  }
  g.queueCv.notify_one();
}

// --- Gradient JSON parsing ----------------------------------------------
//
// Parses the fixed shape emitted by Paint.swift, e.g.
//   {"kind":"linear","p0":[x,y],"p1":[x,y],"stops":[{"c":[r,g,b,a],"l":n},...]}
// Points are unit coordinates (0..1) within the filled rect.

struct GradStop {
  float pos;
  D2D1_COLOR_F color;
};

struct ParsedGradient {
  std::string kind;
  double p0[2] = {0, 0};
  double p1[2] = {0, 1};  // default top->bottom
  double center[2] = {0.5, 0.5};
  double endRadius = 0.5;
  std::vector<GradStop> stops;
};

void ParseGradient(const std::string& j, ParsedGradient& out) {
  size_t k = j.find("\"kind\":\"");
  if (k != std::string::npos) {
    k += 8;
    out.kind = j.substr(k, j.find('"', k) - k);
  }
  size_t p;
  if ((p = j.find("\"p0\":[")) != std::string::npos)
    sscanf(j.c_str() + p + 6, "%lf,%lf", &out.p0[0], &out.p0[1]);
  if ((p = j.find("\"p1\":[")) != std::string::npos)
    sscanf(j.c_str() + p + 6, "%lf,%lf", &out.p1[0], &out.p1[1]);
  if ((p = j.find("\"c\":[")) != std::string::npos)
    sscanf(j.c_str() + p + 5, "%lf,%lf", &out.center[0], &out.center[1]);
  if ((p = j.find("\"er\":")) != std::string::npos)
    sscanf(j.c_str() + p + 5, "%lf", &out.endRadius);

  // Stops live after "stops":[ ; each stop's color is the only "c":[ past it
  // (the radial/angular center "c" appears earlier).
  size_t sp = j.find("\"stops\":[");
  if (sp == std::string::npos) return;
  size_t cur = sp;
  while ((cur = j.find("\"c\":[", cur)) != std::string::npos) {
    double r = 0, gg = 0, b = 0, a = 1, loc = 0;
    sscanf(j.c_str() + cur + 5, "%lf,%lf,%lf,%lf", &r, &gg, &b, &a);
    size_t lp = j.find("\"l\":", cur);
    if (lp != std::string::npos) sscanf(j.c_str() + lp + 4, "%lf", &loc);
    GradStop s;
    s.pos = static_cast<float>(loc);
    s.color = Color(r, gg, b, a);
    out.stops.push_back(s);
    cur += 5;
  }
}

// --- Crash diagnostics --------------------------------------------------

void WriteCrashLog(EXCEPTION_POINTERS* info) {
  char path[MAX_PATH] = {};
  GetTempPathA(MAX_PATH, path);
  strcat_s(path, "iso_crash.log");
  FILE* f = nullptr;
  fopen_s(&f, path, "w");
  if (!f) f = stderr;

  EXCEPTION_RECORD* rec = info ? info->ExceptionRecord : nullptr;
  fprintf(f, "[crash] code=0x%08lx addr=%p\n", rec ? rec->ExceptionCode : 0,
          rec ? rec->ExceptionAddress : nullptr);

  HANDLE proc = GetCurrentProcess();
  SymSetOptions(SYMOPT_LOAD_LINES | SYMOPT_UNDNAME | SYMOPT_DEFERRED_LOADS);
  SymInitialize(proc, nullptr, TRUE);

  if (info && info->ContextRecord) {
    CONTEXT ctx = *info->ContextRecord;  // StackWalk64 mutates the context.
    STACKFRAME64 frame = {};
    // The program counter, frame and stack pointers of the faulting
    // context, as the CPU names them (x64 or ARM64).
#if defined(_M_ARM64)
    const DWORD machine = IMAGE_FILE_MACHINE_ARM64;
    frame.AddrPC.Offset = ctx.Pc;
    frame.AddrFrame.Offset = ctx.Fp;
    frame.AddrStack.Offset = ctx.Sp;
#else
    const DWORD machine = IMAGE_FILE_MACHINE_AMD64;
    frame.AddrPC.Offset = ctx.Rip;
    frame.AddrFrame.Offset = ctx.Rbp;
    frame.AddrStack.Offset = ctx.Rsp;
#endif
    frame.AddrPC.Mode = AddrModeFlat;
    frame.AddrFrame.Mode = AddrModeFlat;
    frame.AddrStack.Mode = AddrModeFlat;
    for (int i = 0; i < 60; ++i) {
      if (!StackWalk64(machine, proc, GetCurrentThread(), &frame, &ctx,
                       nullptr, SymFunctionTableAccess64, SymGetModuleBase64, nullptr) ||
          frame.AddrPC.Offset == 0) {
        break;
      }
      char buf[sizeof(SYMBOL_INFO) + 512] = {};
      SYMBOL_INFO* sym = reinterpret_cast<SYMBOL_INFO*>(buf);
      sym->SizeOfStruct = sizeof(SYMBOL_INFO);
      sym->MaxNameLen = 511;
      DWORD64 disp = 0;
      if (SymFromAddr(proc, frame.AddrPC.Offset, &disp, sym)) {
        fprintf(f, "  %s + 0x%llx\n", sym->Name, disp);
      } else {
        DWORD64 base = SymGetModuleBase64(proc, frame.AddrPC.Offset);
        fprintf(f, "  0x%llx (module base 0x%llx + 0x%llx)\n", frame.AddrPC.Offset, base,
                base ? frame.AddrPC.Offset - base : 0);
      }
    }
  }
  fflush(f);
  if (f != stderr) fclose(f);
}

LONG WINAPI CrashHandler(EXCEPTION_POINTERS* info) {
  WriteCrashLog(info);
  return EXCEPTION_EXECUTE_HANDLER;
}

// --- Win32 window -------------------------------------------------------

void NotifyResize() {
  RECT rc;
  GetClientRect(g.hwnd, &rc);
  UINT px = rc.right - rc.left;
  UINT py = rc.bottom - rc.top;
  float dpi = static_cast<float>(GetDpiForWindow(g.hwnd));
  if (dpi <= 0) dpi = 96.0f;
  g.dpiScale = dpi / 96.0f;
  g.width = px / g.dpiScale;  // logical points
  g.height = py / g.dpiScale;
  // The resize callback resizes the D3D11 swapchain (via iso_window_size_px)
  // before the runtime lays out at the new logical size.
  if (g.resizeCb) g.resizeCb(g.width, g.height);
}

// ---------------------------------------------------------------------------
// Native form controls: Picker/Menu -> COMBOBOX, DatePicker -> SysDateTimePick32.
// Like the WebView, each is a child window positioned over its display-list
// region every frame; value/option changes are reconciled, and user edits flow
// back through iso_set_control_changed_callback -> the runtime's host-view event
// channel (so the existing onChange handler updates the binding).
// ---------------------------------------------------------------------------
struct NativeControl {
  HWND hwnd = nullptr;
  std::string id;
  std::string kind;         // "picker" | "menu" | "datepicker"
  std::string lastOptions;  // detect when the combo list must be rebuilt
  std::string lastValue;    // detect when the selection must be updated
  bool seen = true;
};
std::unordered_map<std::string, NativeControl*> g_controls;
std::unordered_map<HWND, NativeControl*> g_controlsByHwnd;
HFONT g_controlFont = nullptr;
float g_controlFontScale = 0.0f;

HFONT ControlFont() {
  if (!g_controlFont || g_controlFontScale != g.dpiScale) {
    if (g_controlFont) DeleteObject(g_controlFont);
    LONG h = -static_cast<LONG>(15.0f * g.dpiScale);
    g_controlFont = CreateFontW(h, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    g_controlFontScale = g.dpiScale;
  }
  return g_controlFont;
}

// Report a control's user edit to the runtime as a "<id> -> <value>" event.
void NotifyControlChanged(HWND ctrl) {
  auto it = g_controlsByHwnd.find(ctrl);
  if (it == g_controlsByHwnd.end()) return;
  NativeControl* c = it->second;
  int idx = static_cast<int>(SendMessageW(ctrl, CB_GETCURSEL, 0, 0));
  if (idx < 0) return;
  if (g.controlChangedCb) {
    char buf[16];
    int n = snprintf(buf, sizeof(buf), "%d", idx);
    g.controlChangedCb(c->id.c_str(), static_cast<int>(c->id.size()), buf, n);
  }
  if (c->kind == "menu") {
    // A Menu fires the chosen action and snaps back to showing its label.
    SendMessageW(ctrl, CB_SETCURSEL, 0, 0);
  } else {
    c->lastValue = std::to_string(idx);  // already reflects the new selection
  }
}

void NotifyDateChanged(HWND ctrl) {
  auto it = g_controlsByHwnd.find(ctrl);
  if (it == g_controlsByHwnd.end()) return;
  NativeControl* c = it->second;
  SYSTEMTIME st = {};
  if (SendMessageW(ctrl, DTM_GETSYSTEMTIME, 0, reinterpret_cast<LPARAM>(&st)) != GDT_VALID)
    return;
  char buf[32];
  int n = snprintf(buf, sizeof(buf), "%04d-%02d-%02d", st.wYear, st.wMonth, st.wDay);
  if (g.controlChangedCb)
    g.controlChangedCb(c->id.c_str(), static_cast<int>(c->id.size()), buf, n);
  c->lastValue = std::string(buf, n);
}

void NotifyTrackbarChanged(HWND ctrl) {
  auto it = g_controlsByHwnd.find(ctrl);
  if (it == g_controlsByHwnd.end()) return;
  NativeControl* c = it->second;
  int pos = static_cast<int>(SendMessageW(ctrl, TBM_GETPOS, 0, 0));
  char buf[16];
  int n = snprintf(buf, sizeof(buf), "%d", pos);
  if (g.controlChangedCb)
    g.controlChangedCb(c->id.c_str(), static_cast<int>(c->id.size()), buf, n);
  c->lastValue = std::string(buf, n);
}

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  switch (msg) {
    case WM_MOUSEMOVE:
      if (g.pointerCb)
        g.pointerCb(2, GET_X_LPARAM(lParam) / g.dpiScale, GET_Y_LPARAM(lParam) / g.dpiScale);
      return 0;
    case WM_LBUTTONDOWN:
      SetCapture(hwnd);
      if (g.pointerCb)
        g.pointerCb(0, GET_X_LPARAM(lParam) / g.dpiScale, GET_Y_LPARAM(lParam) / g.dpiScale);
      return 0;
    case WM_LBUTTONUP:
      ReleaseCapture();
      if (g.pointerCb)
        g.pointerCb(1, GET_X_LPARAM(lParam) / g.dpiScale, GET_Y_LPARAM(lParam) / g.dpiScale);
      return 0;
    case WM_MOUSEWHEEL: {
      POINT pt = {GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
      ScreenToClient(hwnd, &pt);
      double delta = GET_WHEEL_DELTA_WPARAM(wParam) / 120.0 * 40.0;
      if (g.wheelCb) g.wheelCb(pt.x / g.dpiScale, pt.y / g.dpiScale, 0, delta);
      return 0;
    }
    case WM_COMMAND:
      // A Picker/Menu combo box reported a new selection.
      if (HIWORD(wParam) == CBN_SELCHANGE) {
        NotifyControlChanged(reinterpret_cast<HWND>(lParam));
        return 0;
      }
      // The text-input overlay's content changed under the user's keys/IME.
      if (HIWORD(wParam) == EN_CHANGE &&
          reinterpret_cast<HWND>(lParam) == g_textEdit) {
        NotifyTextEditChanged();
        return 0;
      }
      break;
    case WM_CTLCOLOREDIT:
      // Style the text-input overlay: opaque scheme-aware colors (the web
      // host styles its DOM overlay the same way in setColorScheme).
      if (reinterpret_cast<HWND>(lParam) == g_textEdit) {
        HDC dc = reinterpret_cast<HDC>(wParam);
        COLORREF bg = g.darkScheme ? RGB(0x1c, 0x1c, 0x1e) : RGB(0xff, 0xff, 0xff);
        COLORREF fg = g.darkScheme ? RGB(0xeb, 0xeb, 0xf0) : RGB(0x21, 0x21, 0x26);
        SetBkColor(dc, bg);
        SetTextColor(dc, fg);
        if (!g_textEditBrush || g_textEditBrushDark != g.darkScheme) {
          if (g_textEditBrush) DeleteObject(g_textEditBrush);
          g_textEditBrush = CreateSolidBrush(bg);
          g_textEditBrushDark = g.darkScheme;
        }
        return reinterpret_cast<LRESULT>(g_textEditBrush);
      }
      break;
    case WM_NOTIFY: {
      // A DatePicker reported a new date.
      NMHDR* hdr = reinterpret_cast<NMHDR*>(lParam);
      if (hdr && hdr->code == DTN_DATETIMECHANGE) {
        NotifyDateChanged(hdr->hwndFrom);
        return 0;
      }
      break;
    }
    case WM_HSCROLL:
      // A trackbar (WindowsViewRepresentable "win:trackbar") moved.
      if (lParam) {
        NotifyTrackbarChanged(reinterpret_cast<HWND>(lParam));
        return 0;
      }
      break;
    case WM_ERASEBKGND:
      // SwiftGPU paints the whole client every frame; skip the GDI erase so
      // the background brush never flashes through (a classic flicker source).
      return 1;
    case WM_SIZE:
      NotifyResize();
      // Render synchronously so the window keeps up during an interactive
      // resize, when this message arrives from the modal move/size loop and
      // the normal render loop is blocked.
      if (wParam != SIZE_MINIMIZED && g.paintCb) g.paintCb();
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      if (g.paintCb) g.paintCb();
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_DPICHANGED: {
      RECT* r = reinterpret_cast<RECT*>(lParam);
      SetWindowPos(hwnd, nullptr, r->left, r->top, r->right - r->left, r->bottom - r->top,
                   SWP_NOZORDER | SWP_NOACTIVATE);
      NotifyResize();
      return 0;
    }
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ---------------------------------------------------------------------------
// WebView: embeds the in-process WebBrowser (Trident) ActiveX control via OLE
// in-place activation. One instance per display-list "webview" host view, each
// parented to a container child window the renderer positions over the view's
// region every frame. Needs no external SDK (unlike Edge WebView2). The minimal
// OLE site below implements just the interfaces the control queries for.
// ---------------------------------------------------------------------------
class WebHost : public IOleClientSite,
                public IOleInPlaceSite,
                public IOleInPlaceFrame,
                public IDocHostUIHandler {
 public:
  HWND container = nullptr;      // child of g.hwnd; the control lives here
  IOleObject* oleObject = nullptr;
  IWebBrowser2* browser = nullptr;
  std::wstring url;              // currently navigated url
  bool seen = true;             // touched during the current sync round
  ULONG refs = 1;

  // IUnknown ---------------------------------------------------------------
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** ppv) override {
    if (!ppv) return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_IOleClientSite)
      *ppv = static_cast<IOleClientSite*>(this);
    else if (riid == IID_IOleInPlaceSite || riid == IID_IOleWindow)
      *ppv = static_cast<IOleInPlaceSite*>(this);
    else if (riid == IID_IOleInPlaceFrame || riid == IID_IOleInPlaceUIWindow)
      *ppv = static_cast<IOleInPlaceFrame*>(this);
    else if (riid == IID_IDocHostUIHandler)
      *ppv = static_cast<IDocHostUIHandler*>(this);
    else { *ppv = nullptr; return E_NOINTERFACE; }
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override { return ++refs; }
  ULONG STDMETHODCALLTYPE Release() override {
    ULONG r = --refs;
    if (r == 0) delete this;
    return r;
  }

  // IOleClientSite ---------------------------------------------------------
  HRESULT STDMETHODCALLTYPE SaveObject() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE GetMoniker(DWORD, DWORD, IMoniker** ppmk) override {
    if (ppmk) *ppmk = nullptr;
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetContainer(IOleContainer** pp) override {
    if (pp) *pp = nullptr;
    return E_NOINTERFACE;
  }
  HRESULT STDMETHODCALLTYPE ShowObject() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnShowWindow(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE RequestNewObjectLayout() override { return E_NOTIMPL; }

  // IOleWindow (shared by IOleInPlaceSite and IOleInPlaceFrame) -------------
  HRESULT STDMETHODCALLTYPE GetWindow(HWND* phwnd) override {
    if (!phwnd) return E_INVALIDARG;
    *phwnd = container;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE ContextSensitiveHelp(BOOL) override { return E_NOTIMPL; }

  // IOleInPlaceSite --------------------------------------------------------
  HRESULT STDMETHODCALLTYPE CanInPlaceActivate() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnInPlaceActivate() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnUIActivate() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE GetWindowContext(
      IOleInPlaceFrame** ppFrame, IOleInPlaceUIWindow** ppDoc,
      LPRECT lprcPosRect, LPRECT lprcClipRect,
      LPOLEINPLACEFRAMEINFO info) override {
    if (ppFrame) { *ppFrame = static_cast<IOleInPlaceFrame*>(this); AddRef(); }
    if (ppDoc) *ppDoc = nullptr;
    RECT rc;
    GetClientRect(container, &rc);
    if (lprcPosRect) *lprcPosRect = rc;
    if (lprcClipRect) *lprcClipRect = rc;
    if (info) {
      info->cb = sizeof(OLEINPLACEFRAMEINFO);
      info->fMDIApp = FALSE;
      info->hwndFrame = container;
      info->haccel = nullptr;
      info->cAccelEntries = 0;
    }
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE Scroll(SIZE) override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE OnUIDeactivate(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnInPlaceDeactivate() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE DiscardUndoState() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE DeactivateAndUndo() override { return E_NOTIMPL; }
  HRESULT STDMETHODCALLTYPE OnPosRectChange(LPCRECT) override { return S_OK; }

  // IOleInPlaceUIWindow (base of IOleInPlaceFrame) -------------------------
  HRESULT STDMETHODCALLTYPE GetBorder(LPRECT) override { return INPLACE_E_NOTOOLSPACE; }
  HRESULT STDMETHODCALLTYPE RequestBorderSpace(LPCBORDERWIDTHS) override {
    return INPLACE_E_NOTOOLSPACE;
  }
  HRESULT STDMETHODCALLTYPE SetBorderSpace(LPCBORDERWIDTHS) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE SetActiveObject(IOleInPlaceActiveObject*, LPCOLESTR) override {
    return S_OK;
  }

  // IOleInPlaceFrame -------------------------------------------------------
  HRESULT STDMETHODCALLTYPE InsertMenus(HMENU, LPOLEMENUGROUPWIDTHS) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE SetMenu(HMENU, HOLEMENU, HWND) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE RemoveMenus(HMENU) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE SetStatusText(LPCOLESTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE EnableModeless(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE TranslateAccelerator(LPMSG, WORD) override { return S_FALSE; }

  // IDocHostUIHandler (suppress context menu and the sunken 3D border) -----
  HRESULT STDMETHODCALLTYPE ShowContextMenu(DWORD, POINT*, IUnknown*, IDispatch*) override {
    return S_OK;  // S_OK => host handled it (no default IE menu)
  }
  HRESULT STDMETHODCALLTYPE GetHostInfo(DOCHOSTUIINFO* pInfo) override {
    if (!pInfo) return E_POINTER;
    pInfo->cbSize = sizeof(DOCHOSTUIINFO);
    pInfo->dwFlags = DOCHOSTUIFLAG_NO3DBORDER | DOCHOSTUIFLAG_DPI_AWARE;
    pInfo->dwDoubleClick = DOCHOSTUIDBLCLK_DEFAULT;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE ShowUI(DWORD, IOleInPlaceActiveObject*, IOleCommandTarget*,
                                   IOleInPlaceFrame*, IOleInPlaceUIWindow*) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE HideUI() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE UpdateUI() override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnDocWindowActivate(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE OnFrameWindowActivate(BOOL) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE ResizeBorder(LPCRECT, IOleInPlaceUIWindow*, BOOL) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE TranslateAccelerator(LPMSG, const GUID*, DWORD) override {
    return S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE GetOptionKeyPath(LPOLESTR* pchKey, DWORD) override {
    if (pchKey) *pchKey = nullptr;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE GetDropTarget(IDropTarget*, IDropTarget** pp) override {
    if (pp) *pp = nullptr;
    return E_NOTIMPL;
  }
  HRESULT STDMETHODCALLTYPE GetExternal(IDispatch** pp) override {
    if (pp) *pp = nullptr;
    return S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE TranslateUrl(DWORD, LPWSTR, LPWSTR* ppchURLOut) override {
    if (ppchURLOut) *ppchURLOut = nullptr;
    return S_FALSE;
  }
  HRESULT STDMETHODCALLTYPE FilterDataObject(IDataObject*, IDataObject** pp) override {
    if (pp) *pp = nullptr;
    return S_FALSE;
  }
};

std::unordered_map<std::string, WebHost*> g_webviews;

// Render pages as modern IE11 (edge mode) rather than the control's default IE7
// quirks mode, so contemporary sites lay out reasonably.
void SetBrowserEmulation() {
  static bool done = false;
  if (done) return;
  done = true;
  wchar_t exe[MAX_PATH];
  DWORD n = GetModuleFileNameW(nullptr, exe, MAX_PATH);
  const wchar_t* name = exe;
  for (DWORD i = 0; i < n; ++i)
    if (exe[i] == L'\\') name = exe + i + 1;
  HKEY key;
  if (RegCreateKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Internet Explorer\\Main\\FeatureControl\\FEATURE_BROWSER_EMULATION",
          0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr) == ERROR_SUCCESS) {
    DWORD val = 11001;  // IE11 edge mode
    RegSetValueExW(key, name, 0, REG_DWORD,
                   reinterpret_cast<const BYTE*>(&val), sizeof(val));
    RegCloseKey(key);
  }
}

HWND CreateWebContainer(int x, int y, int w, int h) {
  static const wchar_t* kClass = L"IsoWebContainer";
  static bool registered = false;
  if (!registered) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);
    registered = true;
  }
  return CreateWindowExW(0, kClass, L"", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN,
                         x, y, w, h, g.hwnd, nullptr, GetModuleHandleW(nullptr), nullptr);
}

void NavigateWebHost(WebHost* host, const std::wstring& url) {
  if (!host->browser) return;
  host->url = url;
  VARIANT v;
  VariantInit(&v);
  BSTR burl = SysAllocString(url.c_str());
  host->browser->Navigate(burl, &v, &v, &v, &v);
  SysFreeString(burl);
}

WebHost* CreateWebHost(int x, int y, int w, int h) {
  SetBrowserEmulation();
  WebHost* host = new WebHost();
  host->container = CreateWebContainer(x, y, w, h);
  if (!host->container) {
    host->Release();
    return nullptr;
  }
  if (FAILED(CoCreateInstance(CLSID_WebBrowser, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IOleObject,
                              reinterpret_cast<void**>(&host->oleObject)))) {
    DestroyWindow(host->container);
    host->Release();
    return nullptr;
  }
  host->oleObject->SetClientSite(static_cast<IOleClientSite*>(host));
  OleSetContainedObject(host->oleObject, TRUE);
  RECT rc = {0, 0, w, h};
  host->oleObject->DoVerb(OLEIVERB_INPLACEACTIVATE, nullptr,
                          static_cast<IOleClientSite*>(host), 0, host->container, &rc);
  host->oleObject->QueryInterface(IID_IWebBrowser2,
                                  reinterpret_cast<void**>(&host->browser));
  if (host->browser) {
    host->browser->put_Left(0);
    host->browser->put_Top(0);
    host->browser->put_Width(w);
    host->browser->put_Height(h);
  }
  return host;
}

void DestroyWebHost(WebHost* host) {
  if (host->browser) {
    host->browser->Stop();
    SafeRelease(&host->browser);
  }
  if (host->oleObject) {
    host->oleObject->Close(OLECLOSE_NOSAVE);
    host->oleObject->SetClientSite(nullptr);
    SafeRelease(&host->oleObject);
  }
  if (host->container) {
    DestroyWindow(host->container);
    host->container = nullptr;
  }
  host->Release();
}

// --- Native form control helpers (used by iso_control_sync) ----------------

void EnsureCommonControls() {
  static bool done = false;
  if (done) return;
  done = true;
  INITCOMMONCONTROLSEX icc = {};
  icc.dwSize = sizeof(icc);
  icc.dwICC = ICC_DATE_CLASSES | ICC_BAR_CLASSES | ICC_STANDARD_CLASSES;
  InitCommonControlsEx(&icc);
}

std::vector<std::string> SplitOptions(const std::string& joined) {
  std::vector<std::string> out;
  if (joined.empty()) return out;
  size_t start = 0;
  while (true) {
    size_t nl = joined.find('\n', start);
    if (nl == std::string::npos) {
      out.push_back(joined.substr(start));
      break;
    }
    out.push_back(joined.substr(start, nl - start));
    start = nl + 1;
  }
  return out;
}

void PopulateCombo(NativeControl* c, const std::vector<std::string>& opts) {
  SendMessageW(c->hwnd, CB_RESETCONTENT, 0, 0);
  for (const auto& o : opts) {
    std::wstring w = Widen(o.c_str(), static_cast<int>(o.size()));
    SendMessageW(c->hwnd, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(w.c_str()));
  }
}

void SetComboSelectionSafe(NativeControl* c, const std::string& value) {
  int idx = atoi(value.c_str());
  if (idx < 0) idx = 0;
  SendMessageW(c->hwnd, CB_SETCURSEL, static_cast<WPARAM>(idx), 0);
}

void SetDate(NativeControl* c, const std::string& iso) {
  int y = 0, m = 0, d = 0;
  if (sscanf(iso.c_str(), "%d-%d-%d", &y, &m, &d) == 3 && y > 0) {
    SYSTEMTIME st = {};
    st.wYear = static_cast<WORD>(y);
    st.wMonth = static_cast<WORD>(m);
    st.wDay = static_cast<WORD>(d);
    SendMessageW(c->hwnd, DTM_SETSYSTEMTIME, GDT_VALID, reinterpret_cast<LPARAM>(&st));
  }
}

void SetTrackbar(NativeControl* c, const std::string& v) {
  SendMessageW(c->hwnd, TBM_SETPOS, TRUE, static_cast<LPARAM>(atoi(v.c_str())));
}

// picker/menu use a COMBOBOX (with a drop-down list); datepicker and the
// WindowsViewRepresentable controls use a fixed-height control.
bool IsCombo(const std::string& kind) { return kind == "picker" || kind == "menu"; }

NativeControl* CreateNativeControl(const std::string& id, const std::string& kind,
                                   int px, int py, int pw, int ph) {
  HINSTANCE inst = GetModuleHandleW(nullptr);
  NativeControl* c = new NativeControl();
  c->id = id;
  c->kind = kind;
  if (kind == "datepicker") {
    EnsureCommonControls();
    c->hwnd = CreateWindowExW(0, DATETIMEPICK_CLASSW, L"",
                              WS_CHILD | WS_VISIBLE | DTS_SHORTDATEFORMAT,
                              px, py, pw, ph, g.hwnd, nullptr, inst, nullptr);
  } else if (kind == "win:trackbar") {
    EnsureCommonControls();
    c->hwnd = CreateWindowExW(0, TRACKBAR_CLASSW, L"",
                              WS_CHILD | WS_VISIBLE | WS_TABSTOP | TBS_HORZ | TBS_NOTICKS,
                              px, py, pw, ph, g.hwnd, nullptr, inst, nullptr);
    if (c->hwnd) SendMessageW(c->hwnd, TBM_SETRANGE, TRUE, MAKELONG(0, 100));
  } else {
    // picker / menu -> a drop-down list combo box. The list pops as a native
    // top-level window, so it escapes the renderer's clipping for free.
    c->hwnd = CreateWindowExW(0, L"COMBOBOX", L"",
                              WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST,
                              px, py, pw, ph + 220, g.hwnd, nullptr, inst, nullptr);
  }
  if (!c->hwnd) {
    delete c;
    return nullptr;
  }
  SendMessageW(c->hwnd, WM_SETFONT, reinterpret_cast<WPARAM>(ControlFont()), TRUE);
  if (IsCombo(kind) && ph > 12)
    SendMessageW(c->hwnd, CB_SETITEMHEIGHT, static_cast<WPARAM>(-1),
                 static_cast<LPARAM>(ph - 8));  // closed field ~ host-view height
  g_controls[id] = c;
  g_controlsByHwnd[c->hwnd] = c;
  return c;
}

void DestroyNativeControl(NativeControl* c) {
  g_controlsByHwnd.erase(c->hwnd);
  if (c->hwnd) DestroyWindow(c->hwnd);
  delete c;
}

}  // namespace

// --- Exported C API -----------------------------------------------------

extern "C" {

void iso_set_pointer_callback(iso_pointer_callback cb) { g.pointerCb = cb; }
void iso_set_wheel_callback(iso_wheel_callback cb) { g.wheelCb = cb; }
void iso_set_resize_callback(iso_resize_callback cb) { g.resizeCb = cb; }
void iso_set_paint_callback(iso_paint_callback cb) { g.paintCb = cb; }

void iso_window_create(double width, double height, const char* title) {
  // Per-monitor DPI awareness so we render at the display's native resolution.
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  // Reserve stack so the crash handler can run (and log) even on a stack
  // overflow, which otherwise terminates silently.
  ULONG guarantee = 65536;
  SetThreadStackGuarantee(&guarantee);
  SetUnhandledExceptionFilter(CrashHandler);
  HINSTANCE inst = GetModuleHandleW(nullptr);
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  // No CS_HREDRAW/CS_VREDRAW: those invalidate the whole client on every resize
  // step, which flickers during an interactive drag-resize. We repaint on
  // WM_SIZE/WM_PAINT explicitly instead. No background brush either (Direct2D
  // owns the surface).
  wc.style = 0;
  wc.lpfnWndProc = WndProc;
  wc.hInstance = inst;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = L"IsomerWindow";
  RegisterClassExW(&wc);

  // `width`/`height` are logical points; scale to physical pixels for the
  // initial window so it's a consistent size across DPIs.
  UINT sysDpi = GetDpiForSystem();
  float initScale = sysDpi / 96.0f;
  RECT rc = {0, 0, static_cast<LONG>(width * initScale), static_cast<LONG>(height * initScale)};
  AdjustWindowRectExForDpi(&rc, WS_OVERLAPPEDWINDOW, FALSE, 0, sysDpi);
  std::wstring wtitle = Widen(title, title ? static_cast<int>(strlen(title)) : 0);

  // WS_CLIPCHILDREN so the Direct2D present (a BitBlt to the window DC) excludes
  // any WebView child windows, which would otherwise be overpainted each frame.
  g.hwnd = CreateWindowExW(
      0, wc.lpszClassName, wtitle.c_str(), WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
      CW_USEDEFAULT, CW_USEDEFAULT, rc.right - rc.left, rc.bottom - rc.top,
      nullptr, nullptr, inst, nullptr);

  // Create an ID2D1Factory1 (D2D 1.1) so render targets expose ID2D1DeviceContext,
  // which is needed for the built-in Gaussian shadow effect. ID2D1Factory1 derives
  // from ID2D1Factory, so it stores fine in the ID2D1Factory* field.
  D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1),
                    nullptr, reinterpret_cast<void**>(&g.d2dFactory));
  DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                      reinterpret_cast<IUnknown**>(&g.dwriteFactory));
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROCESS_SERVER,
                   IID_PPV_ARGS(&g.wicFactory));

  ShowWindow(g.hwnd, SW_SHOW);
  UpdateWindow(g.hwnd);
  NotifyResize();
}

void iso_window_size(double* out_width, double* out_height) {
  if (out_width) *out_width = g.width;
  if (out_height) *out_height = g.height;
}

void* iso_window_hwnd(void) { return g.hwnd; }

void iso_window_size_px(double* out_width, double* out_height) {
  RECT rc = {};
  if (g.hwnd) GetClientRect(g.hwnd, &rc);
  if (out_width) *out_width = rc.right - rc.left;
  if (out_height) *out_height = rc.bottom - rc.top;
}

double iso_window_scale(void) { return g.dpiScale > 0 ? g.dpiScale : 1.0; }

int iso_pump_events(void) {
  MSG msg;
  while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
    if (msg.message == WM_QUIT) return 0;
    TranslateMessage(&msg);
    DispatchMessageW(&msg);
  }
  return 1;
}

void iso_frame_wait(void) { Sleep(8); }

// The per-frame draw path lives in Swift now: SwiftGPURenderer draws shapes
// via swift_gpu's D3D11 backend and asks this host to *rasterize* text /
// gradients / shadows / images (iso_rasterize below). The old Direct2D
// display-list replay (begin/end frame, fill/stroke/gradient/shadow/text/
// image draws, clip + transform stacks) is deleted.

void iso_measure_text(const char* text, int text_len, double font_size, int weight,
                      double wrap_width, double* out_width, double* out_height) {
  *out_width = 0;
  *out_height = 0;
  IDWriteTextFormat* fmt = TextFormat(font_size, weight);
  if (!fmt) return;
  std::wstring wtext = Widen(text, text_len);
  float maxW = wrap_width < 0 ? 100000.0f : static_cast<float>(wrap_width);
  IDWriteTextLayout* layout = nullptr;
  if (FAILED(g.dwriteFactory->CreateTextLayout(
          wtext.c_str(), static_cast<UINT32>(wtext.size()), fmt, maxW, 100000.0f, &layout))) {
    return;
  }
  DWRITE_TEXT_METRICS m = {};
  layout->GetMetrics(&m);
  *out_width = m.widthIncludingTrailingWhitespace;
  *out_height = m.height;
  SafeRelease(&layout);
}

int iso_image_info(const char* source, int source_len, int is_remote,
                   double* out_width, double* out_height) {
  *out_width = 0;
  *out_height = 0;
  std::string key(source, source_len > 0 ? source_len : 0);

  auto it = g.imageDims.find(key);
  if (it != g.imageDims.end()) {
    *out_width = it->second.first;
    *out_height = it->second.second;
    return 1;
  }
  auto sIt = g.imageStatus.find(key);
  if (sIt != g.imageStatus.end() && sIt->second == 2) return 2;

  if (is_remote) {
    // Kick off a background download once; the bytes are probed on the main
    // thread in iso_drain_images (and decoded on demand by iso_rasterize).
    if (g.imageRequested.find(key) == g.imageRequested.end()) {
      g.imageRequested[key] = true;
      HttpTask task;
      task.isImage = true;
      task.id = 0;
      task.key = key;
      task.url = Widen(source, source_len);
      EnqueueHttp(std::move(task));
    }
    return 0;  // loading
  }

  // Bundled image: resolve the asset name to its real runfiles path first,
  // falling back to treating the source as a literal file path.
  std::wstring assetPath = ResolveAssetPath(key);
  UINT width = 0, height = 0;
  if (ProbeImageDimsFile(assetPath.empty() ? Widen(source, source_len) : assetPath,
                         &width, &height)) {
    g.imageDims[key] = {width, height};
    g.imageStatus[key] = 1;
    *out_width = width;
    *out_height = height;
    return 1;
  }
  g.imageStatus[key] = 2;
  return 2;
}

// --- Text input ----------------------------------------------------------

void iso_set_text_changed_callback(iso_text_changed_callback cb) { g.textChangedCb = cb; }
void iso_set_text_submit_callback(iso_text_submit_callback cb) { g.textSubmitCb = cb; }

void iso_begin_text_input(const char* text, int text_len,
                          double x, double y, double w, double h,
                          double font_size) {
  if (!g.hwnd) return;
  if (!g_textEdit) {
    g_textEdit = CreateWindowExW(0, L"EDIT", L"", WS_CHILD | ES_AUTOHSCROLL | ES_LEFT,
                                 0, 0, 10, 10, g.hwnd, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
    g_textEditBaseProc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(
        g_textEdit, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(TextEditProc)));
    SendMessageW(g_textEdit, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, 0);
  }
  if (!g_textEditFont || g_textEditFontScale != g.dpiScale ||
      g_textEditFontSize != font_size) {
    if (g_textEditFont) DeleteObject(g_textEditFont);
    LONG fh = -static_cast<LONG>(font_size * g.dpiScale + 0.5);
    g_textEditFont = CreateFontW(fh, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                                 DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                                 CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE, L"Segoe UI");
    g_textEditFontScale = g.dpiScale;
    g_textEditFontSize = font_size;
  }
  SendMessageW(g_textEdit, WM_SETFONT, reinterpret_cast<WPARAM>(g_textEditFont), TRUE);

  // Align with the drawn field's text box: 8pt horizontal inset, one text
  // line (the drawn field uses fontSize * 1.3) centered vertically.
  double lineH = font_size * 1.3;
  int px = static_cast<int>((x + 8) * g.dpiScale);
  int py = static_cast<int>((y + (h - lineH) / 2) * g.dpiScale);
  int pw = static_cast<int>((w - 16) * g.dpiScale);
  int ph = static_cast<int>(lineH * g.dpiScale + 0.5);

  g_textEditSyncing = true;
  std::wstring wide = Widen(text, text_len);
  SetWindowTextW(g_textEdit, wide.c_str());
  g_textEditSyncing = false;
  SetWindowPos(g_textEdit, HWND_TOP, px, py, pw, ph, SWP_SHOWWINDOW);
  SetFocus(g_textEdit);
  // Caret to the end (SetWindowText leaves it at the start).
  int end = static_cast<int>(wide.size());
  SendMessageW(g_textEdit, EM_SETSEL, end, end);
}

void iso_end_text_input(void) {
  if (!g_textEdit) return;
  if (GetFocus() == g_textEdit) SetFocus(g.hwnd);
  ShowWindow(g_textEdit, SW_HIDE);
}

void iso_set_color_scheme(int dark) { g.darkScheme = dark != 0; }

// --- Networking ----------------------------------------------------------

void iso_set_fetch_callback(iso_fetch_callback cb) { g.fetchCb = cb; }

void iso_fetch(int request_id, const char* url, int url_len) {
  HttpTask task;
  task.isImage = false;
  task.id = request_id;
  task.url = Widen(url, url_len);
  EnqueueHttp(std::move(task));
}

void iso_drain_fetches(void) {
  std::vector<CompletedFetch> done;
  {
    std::lock_guard<std::mutex> lock(g.fetchMutex);
    done.swap(g.completedFetches);
  }
  for (const auto& f : done) {
    if (g.fetchCb) {
      g.fetchCb(f.id, f.ok ? 1 : 0, f.body.data(), static_cast<int>(f.body.size()));
    }
  }
}

// Downloaded (still encoded) image bytes, kept for iso_rasterize's WIC
// decode — the SwiftGPU path uploads pixels itself instead of drawing the
// D2D bitmaps.
std::unordered_map<std::string, std::string> g_imageEncoded;

void iso_drain_images(void) {
  std::vector<DownloadedImage> done;
  {
    std::lock_guard<std::mutex> lock(g.imageMutex);
    done.swap(g.downloadedImages);
  }
  for (auto& d : done) {
    UINT width = 0, height = 0;
    if (d.ok && ProbeImageDimsMemory(d.bytes, &width, &height)) {
      g.imageDims[d.key] = {width, height};
      g.imageStatus[d.key] = 1;
      // Keep the encoded bytes; iso_rasterize decodes pixels on demand.
      g_imageEncoded[d.key] = std::move(d.bytes);
    } else {
      g.imageStatus[d.key] = 2;
    }
  }
}

// --- SwiftGPU rasterization -------------------------------------------------
// The services half of the SwiftGPU renderer: produce premultiplied-RGBA
// pixels for text runs, gradients, shadows, and images. NO GPU calls here —
// Swift draws the returned bytes through swift_gpu's D3D11 backend.

}  // extern "C" (the helpers below are C++; iso_rasterize reopens it)

namespace {

double JsonNumber(const std::string& j, const char* key, double fallback) {
  std::string needle = std::string("\"") + key + "\":";
  size_t p = j.find(needle);
  if (p == std::string::npos) return fallback;
  return atof(j.c_str() + p + needle.size());
}

bool JsonBool(const std::string& j, const char* key, bool fallback) {
  std::string needle = std::string("\"") + key + "\":";
  size_t p = j.find(needle);
  if (p == std::string::npos) return fallback;
  return j.compare(p + needle.size(), 4, "true") == 0;
}

// Unescape the producer's escapes (\\ \" \n — see jsonEscapedGPU in
// SwiftGPURenderer.swift). `afterValue` (optional) receives the index past
// the closing quote, so callers can search later keys AFTER the value —
// user text may itself contain JSON-looking content like a literal "size":.
std::string JsonString(const std::string& j, const char* key,
                       size_t* afterValue = nullptr) {
  std::string needle = std::string("\"") + key + "\":\"";
  size_t p = j.find(needle);
  if (afterValue) *afterValue = 0;
  if (p == std::string::npos) return "";
  std::string out;
  size_t i = p + needle.size();
  for (; i < j.size(); ++i) {
    char c = j[i];
    if (c == '\\' && i + 1 < j.size()) {
      char n = j[++i];
      out.push_back(n == 'n' ? '\n' : n);
    } else if (c == '"') {
      ++i;
      break;
    } else {
      out.push_back(c);
    }
  }
  if (afterValue) *afterValue = i;
  return out;
}

void WriteRasterHeader(std::vector<unsigned char>& out, UINT px, UINT py) {
  out[0] = px & 0xff;
  out[1] = (px >> 8) & 0xff;
  out[2] = (px >> 16) & 0xff;
  out[3] = (px >> 24) & 0xff;
  out[4] = py & 0xff;
  out[5] = (py >> 8) & 0xff;
  out[6] = (py >> 16) & 0xff;
  out[7] = (py >> 24) & 0xff;
}

// Render `draw` (drawing in logical units) into [w u32][h u32][premultiplied
// RGBA] at the window's DPI scale, via a WIC-bitmap D2D target (PBGRA is
// premultiplied BGRA; rows swizzle to RGBA on readback).
template <typename F>
bool RasterizeD2D(double logicalW, double logicalH, F&& draw,
                  std::vector<unsigned char>& out) {
  if (!g.d2dFactory || !g.wicFactory) return false;
  double scale = g.dpiScale > 0 ? g.dpiScale : 1.0;
  UINT px = static_cast<UINT>(lround(logicalW * scale));
  UINT py = static_cast<UINT>(lround(logicalH * scale));
  if (px < 1) px = 1;
  if (py < 1) py = 1;
  IWICBitmap* wic = nullptr;
  if (FAILED(g.wicFactory->CreateBitmap(px, py, GUID_WICPixelFormat32bppPBGRA,
                                        WICBitmapCacheOnDemand, &wic))) {
    return false;
  }
  D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_DEFAULT,
      D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96.0f * static_cast<float>(scale), 96.0f * static_cast<float>(scale));
  ID2D1RenderTarget* rt = nullptr;
  bool ok = false;
  if (SUCCEEDED(g.d2dFactory->CreateWicBitmapRenderTarget(wic, &props, &rt))) {
    rt->BeginDraw();
    rt->Clear(D2D1::ColorF(0, 0, 0, 0.0f));
    draw(rt);
    ok = SUCCEEDED(rt->EndDraw());
  }
  SafeRelease(&rt);
  if (ok) {
    out.assign(8 + static_cast<size_t>(px) * py * 4, 0);
    WriteRasterHeader(out, px, py);
    WICRect all = {0, 0, static_cast<INT>(px), static_cast<INT>(py)};
    IWICBitmapLock* lock = nullptr;
    if (SUCCEEDED(wic->Lock(&all, WICBitmapLockRead, &lock))) {
      UINT stride = 0, size = 0;
      BYTE* data = nullptr;
      lock->GetStride(&stride);
      lock->GetDataPointer(&size, &data);
      for (UINT row = 0; row < py; ++row) {
        const BYTE* src = data + static_cast<size_t>(row) * stride;
        unsigned char* dst = out.data() + 8 + static_cast<size_t>(row) * px * 4;
        for (UINT c = 0; c < px; ++c) {
          dst[c * 4] = src[c * 4 + 2];      // R <- B slot
          dst[c * 4 + 1] = src[c * 4 + 1];  // G
          dst[c * 4 + 2] = src[c * 4];      // B <- R slot
          dst[c * 4 + 3] = src[c * 4 + 3];  // A
        }
      }
      lock->Release();
    } else {
      ok = false;
    }
  }
  SafeRelease(&wic);
  return ok;
}

bool RasterizeTextSpec(const std::string& spec, std::vector<unsigned char>& out) {
  size_t afterText = 0;
  std::string text = JsonString(spec, "text", &afterText);
  // Search the numeric keys AFTER the text value (the text itself may
  // contain JSON-looking content).
  std::string tail = spec.substr(afterText);
  double size = JsonNumber(tail, "size", 15);
  int weight = static_cast<int>(JsonNumber(tail, "weight", 400));
  double wrap = JsonNumber(tail, "wrap", -1);
  double r = JsonNumber(tail, "r", 0), gg = JsonNumber(tail, "g", 0);
  double b = JsonNumber(tail, "b", 0), a = JsonNumber(tail, "a", 1);
  IDWriteTextFormat* fmt = TextFormat(size, weight);
  if (!fmt) return false;
  std::wstring wtext = Widen(text.c_str(), static_cast<int>(text.size()));
  // The wrap width is the measured frame; a hair of slack keeps float
  // rounding from re-wrapping the widest line.
  float maxW = wrap > 0 ? static_cast<float>(wrap) + 0.01f : 100000.0f;
  IDWriteTextLayout* layout = nullptr;
  if (FAILED(g.dwriteFactory->CreateTextLayout(
          wtext.c_str(), static_cast<UINT32>(wtext.size()), fmt, maxW, 100000.0f,
          &layout))) {
    return false;
  }
  DWRITE_TEXT_METRICS m = {};
  layout->GetMetrics(&m);
  double w = m.widthIncludingTrailingWhitespace > 1 ? m.widthIncludingTrailingWhitespace : 1;
  double h = m.height > 1 ? m.height : 1;
  bool ok = RasterizeD2D(w, h, [&](ID2D1RenderTarget* rt) {
    ID2D1SolidColorBrush* brush = nullptr;
    rt->CreateSolidColorBrush(Color(r, gg, b, a), &brush);
    if (brush) {
      rt->DrawTextLayout(D2D1::Point2F(0, 0), layout, brush, D2D1_DRAW_TEXT_OPTIONS_NONE);
      brush->Release();
    }
  }, out);
  SafeRelease(&layout);
  return ok;
}

bool RasterizeGradientSpec(const std::string& spec, std::vector<unsigned char>& out) {
  double w = JsonNumber(spec, "w", 1), h = JsonNumber(spec, "h", 1);
  double radius = JsonNumber(spec, "radius", 0);
  size_t gp = spec.find("\"gradient\":");
  if (gp == std::string::npos || spec.empty() || spec.back() != '}') return false;
  std::string gradientJSON = spec.substr(gp + 11, spec.size() - (gp + 11) - 1);
  ParsedGradient pg;
  ParseGradient(gradientJSON, pg);
  if (pg.stops.empty()) return false;
  double rad = radius;
  if (rad > w / 2) rad = w / 2;
  if (rad > h / 2) rad = h / 2;
  return RasterizeD2D(w, h, [&](ID2D1RenderTarget* rt) {
    std::vector<D2D1_GRADIENT_STOP> d2dStops;
    d2dStops.reserve(pg.stops.size());
    for (const auto& s : pg.stops) d2dStops.push_back({s.pos, s.color});
    ID2D1GradientStopCollection* collection = nullptr;
    if (FAILED(rt->CreateGradientStopCollection(
            d2dStops.data(), static_cast<UINT32>(d2dStops.size()), D2D1_GAMMA_2_2,
            D2D1_EXTEND_MODE_CLAMP, &collection))) {
      return;
    }
    ID2D1Brush* brush = nullptr;
    if (pg.kind == "radial") {
      float endRadius = static_cast<float>(pg.endRadius * (w < h ? w : h));
      D2D1_RADIAL_GRADIENT_BRUSH_PROPERTIES rp = {};
      rp.center = D2D1::Point2F(static_cast<float>(pg.center[0] * w),
                                static_cast<float>(pg.center[1] * h));
      rp.radiusX = endRadius;
      rp.radiusY = endRadius;
      ID2D1RadialGradientBrush* rb = nullptr;
      rt->CreateRadialGradientBrush(rp, collection, &rb);
      brush = rb;
    } else {
      D2D1_LINEAR_GRADIENT_BRUSH_PROPERTIES lp = {};
      lp.startPoint = D2D1::Point2F(static_cast<float>(pg.p0[0] * w),
                                    static_cast<float>(pg.p0[1] * h));
      lp.endPoint = D2D1::Point2F(static_cast<float>(pg.p1[0] * w),
                                  static_cast<float>(pg.p1[1] * h));
      ID2D1LinearGradientBrush* lb = nullptr;
      rt->CreateLinearGradientBrush(lp, collection, &lb);
      brush = lb;
    }
    SafeRelease(&collection);
    if (!brush) return;
    if (rad > 0.5) {
      D2D1_ROUNDED_RECT rr = {Rect(0, 0, w, h), static_cast<float>(rad),
                              static_cast<float>(rad)};
      rt->FillRoundedRectangle(rr, brush);
    } else {
      rt->FillRectangle(Rect(0, 0, w, h), brush);
    }
    brush->Release();
  }, out);
}

// One box-blur pass (radius `r`) along a row/column strip of `n` values.
void BoxBlur1D(float* values, float* scratch, int n, int r) {
  if (r <= 0 || n <= 0) return;
  double window = 2.0 * r + 1.0;
  double sum = 0;
  for (int i = -r; i <= r; ++i) sum += values[i < 0 ? 0 : (i >= n ? n - 1 : i)];
  for (int i = 0; i < n; ++i) {
    scratch[i] = static_cast<float>(sum / window);
    int add = i + r + 1;
    int drop = i - r;
    sum += values[add >= n ? n - 1 : add] - values[drop < 0 ? 0 : drop];
  }
  memcpy(values, scratch, static_cast<size_t>(n) * sizeof(float));
}

// CPU Gaussian drop shadow: rounded-rect SDF coverage, triple box blur
// (σ = blur/2, matching the web host's canvas filter and the old D2D
// effect's blur * 0.5), tinted premultiplied. The WIC target has no D2D
// effects, and rasterization is CPU-side by design.
bool RasterizeShadowSpec(const std::string& spec, std::vector<unsigned char>& out) {
  double w = JsonNumber(spec, "w", 1), h = JsonNumber(spec, "h", 1);
  double corner = JsonNumber(spec, "corner", 0), blur = JsonNumber(spec, "blur", 0);
  double r = JsonNumber(spec, "r", 0), gg = JsonNumber(spec, "g", 0);
  double b = JsonNumber(spec, "b", 0), a = JsonNumber(spec, "a", 1);
  double scale = g.dpiScale > 0 ? g.dpiScale : 1.0;
  double pad = blur * 2;  // matches SwiftGPURenderer's dest margin
  int px = static_cast<int>(lround((w + pad * 2) * scale));
  int py = static_cast<int>(lround((h + pad * 2) * scale));
  if (px < 1) px = 1;
  if (py < 1) py = 1;
  if (static_cast<long long>(px) * py > 16 * 1024 * 1024) return false;

  std::vector<float> mask(static_cast<size_t>(px) * py);
  double rectW = w * scale, rectH = h * scale;
  double rad = corner * scale;
  if (rad > rectW / 2) rad = rectW / 2;
  if (rad > rectH / 2) rad = rectH / 2;
  double cx = pad * scale + rectW / 2, cy = pad * scale + rectH / 2;
  double hx = rectW / 2 - rad, hy = rectH / 2 - rad;
  for (int y = 0; y < py; ++y) {
    for (int x = 0; x < px; ++x) {
      double qx = fabs(x + 0.5 - cx) - hx;
      double qy = fabs(y + 0.5 - cy) - hy;
      double ox = qx > 0 ? qx : 0, oy = qy > 0 ? qy : 0;
      double inside = (qx > qy ? qx : qy);
      double d = sqrt(ox * ox + oy * oy) + (inside < 0 ? inside : 0) - rad;
      double coverage = 0.5 - d;
      mask[static_cast<size_t>(y) * px + x] =
          static_cast<float>(coverage < 0 ? 0 : (coverage > 1 ? 1 : coverage));
    }
  }

  double sigma = blur * 0.5 * scale;
  int boxR = static_cast<int>(lround(sigma));
  if (boxR < 1 && sigma > 0.1) boxR = 1;
  if (boxR > 0) {
    std::vector<float> strip(static_cast<size_t>(px > py ? px : py));
    std::vector<float> scratch(strip.size());
    for (int pass = 0; pass < 3; ++pass) {
      for (int y = 0; y < py; ++y) {
        BoxBlur1D(mask.data() + static_cast<size_t>(y) * px, scratch.data(), px, boxR);
      }
      for (int x = 0; x < px; ++x) {
        for (int y = 0; y < py; ++y) strip[y] = mask[static_cast<size_t>(y) * px + x];
        BoxBlur1D(strip.data(), scratch.data(), py, boxR);
        for (int y = 0; y < py; ++y) mask[static_cast<size_t>(y) * px + x] = strip[y];
      }
    }
  }

  out.assign(8 + static_cast<size_t>(px) * py * 4, 0);
  WriteRasterHeader(out, static_cast<UINT>(px), static_cast<UINT>(py));
  for (size_t i = 0; i < mask.size(); ++i) {
    double alpha = a * mask[i];
    unsigned char* dst = out.data() + 8 + i * 4;
    dst[0] = static_cast<unsigned char>(lround(r * alpha * 255));  // premultiplied
    dst[1] = static_cast<unsigned char>(lround(gg * alpha * 255));
    dst[2] = static_cast<unsigned char>(lround(b * alpha * 255));
    dst[3] = static_cast<unsigned char>(lround(alpha * 255));
  }
  return true;
}

// Decode a WIC source (file or downloaded bytes) to the raster payload at
// the image's native size (PBGRA is already premultiplied; swizzle to RGBA).
bool DecodeSourceToPayload(IWICBitmapDecoder* decoder, std::vector<unsigned char>& out) {
  if (!decoder) return false;
  IWICBitmapFrameDecode* frame = nullptr;
  IWICFormatConverter* converter = nullptr;
  bool ok = false;
  if (SUCCEEDED(decoder->GetFrame(0, &frame)) &&
      SUCCEEDED(g.wicFactory->CreateFormatConverter(&converter)) &&
      SUCCEEDED(converter->Initialize(frame, GUID_WICPixelFormat32bppPBGRA,
                                      WICBitmapDitherTypeNone, nullptr, 0.0,
                                      WICBitmapPaletteTypeMedianCut))) {
    UINT width = 0, height = 0;
    converter->GetSize(&width, &height);
    if (width > 0 && height > 0) {
      out.assign(8 + static_cast<size_t>(width) * height * 4, 0);
      WriteRasterHeader(out, width, height);
      if (SUCCEEDED(converter->CopyPixels(nullptr, width * 4,
                                          static_cast<UINT>(out.size() - 8),
                                          out.data() + 8))) {
        for (size_t i = 8; i + 3 < out.size(); i += 4) {
          unsigned char tmp = out[i];
          out[i] = out[i + 2];
          out[i + 2] = tmp;
        }
        ok = true;
      }
    }
  }
  SafeRelease(&converter);
  SafeRelease(&frame);
  return ok;
}

bool RasterizeImageSpec(const std::string& spec, std::vector<unsigned char>& out) {
  if (!g.wicFactory) return false;
  std::string source = JsonString(spec, "source");
  bool remote = JsonBool(spec, "remote", false);
  bool ok = false;
  if (remote) {
    auto it = g_imageEncoded.find(source);
    if (it == g_imageEncoded.end() || it->second.empty()) return false;
    IWICStream* stream = nullptr;
    if (FAILED(g.wicFactory->CreateStream(&stream))) return false;
    if (SUCCEEDED(stream->InitializeFromMemory(
            reinterpret_cast<BYTE*>(const_cast<char*>(it->second.data())),
            static_cast<DWORD>(it->second.size())))) {
      IWICBitmapDecoder* decoder = nullptr;
      if (SUCCEEDED(g.wicFactory->CreateDecoderFromStream(
              stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder))) {
        ok = DecodeSourceToPayload(decoder, out);
        decoder->Release();
      }
    }
    SafeRelease(&stream);
  } else {
    std::wstring assetPath = ResolveAssetPath(source);
    std::wstring path = assetPath.empty()
                            ? Widen(source.c_str(), static_cast<int>(source.size()))
                            : assetPath;
    IWICBitmapDecoder* decoder = nullptr;
    if (SUCCEEDED(g.wicFactory->CreateDecoderFromFilename(
            path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
            &decoder))) {
      ok = DecodeSourceToPayload(decoder, out);
      decoder->Release();
    }
  }
  return ok;
}

}  // namespace

extern "C" {

const unsigned char* iso_rasterize(const char* spec, int spec_len, int* out_len) {
  static std::vector<unsigned char> buffer;  // main thread only
  *out_len = 0;
  std::string s(spec, spec_len > 0 ? spec_len : 0);
  buffer.clear();
  bool ok = false;
  if (s.find("\"kind\":\"text\"") != std::string::npos) {
    ok = RasterizeTextSpec(s, buffer);
  } else if (s.find("\"kind\":\"gradient\"") != std::string::npos) {
    ok = RasterizeGradientSpec(s, buffer);
  } else if (s.find("\"kind\":\"shadow\"") != std::string::npos) {
    ok = RasterizeShadowSpec(s, buffer);
  } else if (s.find("\"kind\":\"image\"") != std::string::npos) {
    ok = RasterizeImageSpec(s, buffer);
  }
  if (!ok || buffer.size() <= 8) return nullptr;
  *out_len = static_cast<int>(buffer.size());
  return buffer.data();
}

// --- IsomerBridge -----------------------------------------------------

void iso_bridge_log(const char* message, int len) {
  std::string s(message, len > 0 ? len : 0);
  s += "\n";
  OutputDebugStringA(s.c_str());
  fputs(s.c_str(), stderr);
}

double iso_bridge_epoch_millis(void) {
  FILETIME ft;
  GetSystemTimeAsFileTime(&ft);
  ULARGE_INTEGER u;
  u.LowPart = ft.dwLowDateTime;
  u.HighPart = ft.dwHighDateTime;
  // 100-ns intervals since 1601 -> ms since 1970.
  const unsigned long long kEpochDiff = 116444736000000000ULL;
  return static_cast<double>((u.QuadPart - kEpochDiff) / 10000ULL);
}

void iso_bridge_open_url(const char* url, int len) {
  std::wstring w = Widen(url, len);
  ShellExecuteW(nullptr, L"open", w.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

// --- Native host views (WebView + form controls) -------------------------
// Each frame the runtime calls iso_host_sync_begin, then iso_webview_sync /
// iso_control_sync for every native host view present, then iso_host_sync_end
// (which tears down any child window not synced this round). Geometry arrives in
// logical points and is scaled to physical pixels for the native child windows.

void iso_host_sync_begin(void) {
  for (auto& kv : g_webviews) kv.second->seen = false;
  for (auto& kv : g_controls) kv.second->seen = false;
}

void iso_set_control_changed_callback(iso_control_changed_callback cb) {
  g.controlChangedCb = cb;
}

void iso_control_sync(const char* id, int id_len, const char* kind, int kind_len,
                      const char* value, int value_len,
                      const char* options, int options_len,
                      double x, double y, double w, double h) {
  if (!g.hwnd) return;
  std::string sid(id, id_len > 0 ? id_len : 0);
  std::string skind(kind, kind_len > 0 ? kind_len : 0);
  std::string sval(value, value_len > 0 ? value_len : 0);
  std::string sopts(options, options_len > 0 ? options_len : 0);
  float s = g.dpiScale;
  int px = static_cast<int>(x * s);
  int py = static_cast<int>(y * s);
  int pw = static_cast<int>(w * s);
  int ph = static_cast<int>(h * s);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;

  bool combo = IsCombo(skind);
  NativeControl* c = nullptr;
  auto it = g_controls.find(sid);
  if (it == g_controls.end()) {
    c = CreateNativeControl(sid, skind, px, py, pw, ph);
    if (!c) return;
    if (skind == "datepicker") {
      SetDate(c, sval);
    } else if (skind == "win:trackbar") {
      SetTrackbar(c, sval);
    } else {
      PopulateCombo(c, SplitOptions(sopts));
      SetComboSelectionSafe(c, sval);
    }
    c->lastOptions = sopts;
    c->lastValue = sval;
  } else {
    c = it->second;
    // Don't disturb an open combo drop-down mid-interaction.
    if (combo && SendMessageW(c->hwnd, CB_GETDROPPEDSTATE, 0, 0)) {
      c->seen = true;
      return;
    }
    if (skind == "datepicker") {
      if (sval != c->lastValue) {
        SetDate(c, sval);
        c->lastValue = sval;
      }
    } else if (skind == "win:trackbar") {
      if (sval != c->lastValue) {
        SetTrackbar(c, sval);
        c->lastValue = sval;
      }
    } else {
      if (sopts != c->lastOptions) {
        PopulateCombo(c, SplitOptions(sopts));
        c->lastOptions = sopts;
        c->lastValue.clear();  // force a re-select against the rebuilt list
      }
      if (sval != c->lastValue) {
        SetComboSelectionSafe(c, sval);
        c->lastValue = sval;
      }
    }
  }
  c->seen = true;
  int height = combo ? ph + 220 : ph;  // a combo needs extra drop-down room
  SetWindowPos(c->hwnd, HWND_TOP, px, py, pw, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void iso_webview_sync(const char* id, int id_len, const char* url, int url_len,
                      double x, double y, double w, double h) {
  if (!g.hwnd) return;
  std::string key(id, id_len > 0 ? id_len : 0);
  std::wstring wurl = Widen(url, url_len);
  float s = g.dpiScale;
  int px = static_cast<int>(x * s);
  int py = static_cast<int>(y * s);
  int pw = static_cast<int>(w * s);
  int ph = static_cast<int>(h * s);
  if (pw < 1) pw = 1;
  if (ph < 1) ph = 1;

  WebHost* host = nullptr;
  auto it = g_webviews.find(key);
  if (it == g_webviews.end()) {
    host = CreateWebHost(px, py, pw, ph);
    if (!host) return;
    g_webviews[key] = host;
    NavigateWebHost(host, wurl);
  } else {
    host = it->second;
    if (host->url != wurl) NavigateWebHost(host, wurl);
  }
  host->seen = true;
  SetWindowPos(host->container, HWND_TOP, px, py, pw, ph,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  if (host->browser) {
    host->browser->put_Width(pw);
    host->browser->put_Height(ph);
  }
}

void iso_host_sync_end(void) {
  for (auto it = g_webviews.begin(); it != g_webviews.end();) {
    if (!it->second->seen) {
      DestroyWebHost(it->second);
      it = g_webviews.erase(it);
    } else {
      ++it;
    }
  }
  for (auto it = g_controls.begin(); it != g_controls.end();) {
    if (!it->second->seen) {
      DestroyNativeControl(it->second);
      it = g_controls.erase(it);
    } else {
      ++it;
    }
  }
}

}  // extern "C"
