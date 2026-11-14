# How an Isomer app runs: compiled, web view, remote; and embedded features

The owner's plan (2026-11-14), after benchmarking isomer#188's side modules
and mixed mode against the web view and native code on an iPhone XS: each
engine where it is strongest, chosen at build time.

## A whole app (an `App` built with Isomer)

The app target says how its Swift runs (a Bazel setting, so the same app can
hot-reload as wasm and ship compiled):

| Mode | Where the app's Swift runs | The seam to the head | The app ships |
| --- | --- | --- | --- |
| `compiled` (the default) | natively, in the app's process | direct calls, synchronous (IsomerLocalServer) | the app's Swift, Isomer, the head |
| `webview` | wasm, with the JIT, in an invisible web view the app owns | the session protocol (protobuf), asynchronous, over the web view's message channel | the head and the wasm; no compiled Swift of the app's |
| `remote` | elsewhere: compiled (natively on Linux, or in an Android emulator) or wasm (headless Chromium on a server) | the session protocol, over WebSockets or gRPC | the head alone |

- **Web view and remote are one shape with two transports.** Both put a
  guest behind the session protocol (shared/wire/session.proto,
  docs/remote_sessions.md). A compiled remote guest is what exists today: an
  app built headless serves itself (`ISO_DRIVE_LISTEN`). A wasm guest runs
  the web's own runtime (boot.js) in a page, which speaks the same protocol.
- **Inside the page the guest is synchronous with its own host:** text is
  measured and rasterized by the page, so layout never waits on the app.
  Only the session crosses the seam: patches out; events, sizes, appearance
  and scene phase in.
- **The heads** are the renderers that already read the tree's patches:
  Apple's tree renderer (apple/libraries/swift_ui_tree, FlatPatchTree), the
  Compose interpreter (FlatTree.kt), the DOM renderer (flat_tree.js). The web
  and Android heads already take a session (`connectIsomer`,
  `IsomerRemote`), and Apple's too (`IsomerRemoteView`,
  apple/libraries/remote_head), by URL or over a connection of its own.

### Web-view mode on the iPhone and the Mac (what there is)

- **The page** is the app's own web site: every `isomer_web_app` site has
  `webview.html` beside index.html, which serves the app's session
  (wasm/libraries/swift_ui/runtime/session_host.js) instead of drawing it.
  The guest starts with the head's `start` (its size, scale, appearance, the
  ISO_ launch environment) under the head's renderer by name (`isoStart`
  with "swiftui" binds `SwiftUIRenderer`, "compose" Compose's; the app's
  `Bridge.rendererName` says so); each ClientMessage is the guest's export
  called (`isoHostEvent`, `isoResize`, `isoKeyEvent`, `isoSetColorScheme`,
  `isoSetDisplayScale`, `isoSetScenePhase`, `isoOpenURL`, `isoBack`), as
  headless/libraries/swift_ui/RemoteSession.swift maps them on a server;
  out go its patches, the pictures it registers, its platform commands,
  the URLs it opens and its appearance. Text is measured by the page's
  canvas; files, networking and SecureStore are the page's, as on the web.
  The messages are written and read by hand (session_messages.js).
- **Apple's side** (apple/libraries/webview_head, `IsomerWebViewHead`, its own
  library so a remote-only app links no WebKit): `IsomerWebViewHost` owns a
  WKWebView and serves the bundled site from `isomer-app://app/`
  (`IsomerSiteSchemeHandler`: a stable origin, so the page's IndexedDB keeps
  the app's files). `IsomerWebViewConnection` is an `IsomerConnection`:
  client messages go to the page with `callAsyncJavaScript` (base64), one at
  a time; server messages come back through the `isomer` message handler.
  Each session loads the page afresh. `IsomerWebViewAppView(site:)` keeps the
  web view 1×1 point and nearly transparent behind `IsomerRemoteView(connection:)`
  in the app's window, where WebKit counts it visible.
- **The example**: examples/apple/webview_ios_application, the web
  Storybook's site bundled into an iPhone app (simulator, no profile) that
  compiles none of the Storybook's Swift; CI's container builds it on every
  pull request.
- **Tests**: the examples' //tests/webview_session:session_test runs the page
  in headless Chrome with the Storybook's guest, as a head drives it: the
  first patch is the whole tree, a tap changes it. It draws nothing (a pull
  request's test). The iPhone side has no automated test yet: it needs a
  simulator (a hosted XCTest on a Mac at verify, as the Storybook's).
- **Open**: Android's WebView and Windows' WebView2 as transports; the
  platform services the page lacks (the app's container for files, the
  keychain, the clipboard, networking without CORS) over the session; an
  iPhone test; a Mac example; and `--@isomer//:mode` choosing it.

### What crosses an asynchronous seam

What a compiled app answers in the same call, a web-view or remote one
answers a frame later, or keeps on the guest's side:

- **Text measurement** happens in the guest's own host (the page, or the
  headless host's estimate on a server). The head lays text out with its own
  fonts, as it does in process; what the app computes from a measurement
  (`GeometryReader` around text) can differ slightly from compiled mode.
- **Images:** a bundled asset by name (the head loads it), a remote one by
  URL (the head fetches it), pixels the guest made (`Image(data:)`, ImageIO,
  a CGImage) sent once as an `image` message keyed by its source, which the
  tree then names.
- **Platform services** the page lacks go over the session as requests:
  files in the app's container, the keychain (SecureStore), the clipboard,
  networking without CORS. Where an app's files live in web-view mode (the
  app's container, through the session, or the page's own storage) is to
  decide; the container keeps them the app's across modes.
- **Keys and back** come too late to be refused (docs/remote_sessions.md).
- **App Review:** code WebKit runs is allowed; an app whose UI logic is all
  downloaded wasm is to check against the guideline on downloaded code
  (its wasm can ship in the bundle).

## A feature embedded in an existing app or site

`IsomerView` (and `Isomer()`, `IsomerFragment`, `<isomer-view>`) shows an
Isomer feature inside an app that isn't Isomer's. It is compiled, or
interpreted:

- **compiled:** the feature's Swift built into the app (isomer_compiled_feature
  on Apple; the app's JNI library on Android).
- **interpreted** (isomer#188's design): the runtime (the standard library,
  Foundation, Isomer's SwiftUI) compiled into the host app once, and each
  feature a small wasm side module over it, its hot paths native (mixed mode:
  wasm2c copies of the runtime's profiled functions, sharing its memory and
  table), the guest on a thread of its own. Here an in-process engine's
  strengths count most: synchronous calls into the host (0.30 µs against
  about 195 µs from a web view), no second process, and places with no web
  view (widgets, watchOS, background work).
- **On a website**, interpreted is the page's own wasm, as today.

## The setting

`--@isomer//:mode=compiled|webview|remote` for a whole app (an
`isomer_application` macro that takes it on every platform; today the macros
are per platform: `isomer_android_app`, `isomer_web_app`, rules_apple's on
Apple), and a feature-level choice for `IsomerView`.

## Measured (iPhone XS, A12, iOS 18.7; 2026-11-14)

2048, event to frame (ms). Side modules: 2048 is 33 KB gzipped against
5.2 MB as a self-contained reactor; the runtime, once, 6.7 MB.

| 100 drags paced at 120 Hz | mean | p99 | over 8.3 ms |
| --- | --- | --- | --- |
| Web view | 4.1 | 14 | 4.7% |
| Mixed | 5.0 | 38 | 8.7% |
| Interpreted | 7.5 | 42 | 35% |

| Played, real renderer | mean | p90 | dropped frames |
| --- | --- | --- | --- |
| Web view | 1.8 | 3.2 | 10–14 |
| Mixed, own thread | 3.6 | 6.4 | 2–5 |
| Mixed, main thread | 4.6 | 9.8 | 68–80 |

Unpaced, no renderer: native 0.63 mean / 1.35 p99; mixed 1.28 / 6.7;
interpreted 2.65–2.71 / 11. Main's WasmKit about 4% slower than #188's fork
on the same reactor.

## Order

1. Side modules (isomer#188's first half, once split): every mode gains.
2. Apple's head over a session: web-view and remote apps on the iPhone and
   the Mac.
3. Web-view mode: the in-page runtime behind the session protocol, its
   transport over WebKit's message channel (both there: "Web-view mode on
   the iPhone and the Mac" above; then Android's WebView, Windows'
   WebView2); the platform services over the session.
4. Embedded interpreted mode (isomer#188's second half, with its crash fixed
   and its native set profiled per feature).
5. `--@isomer//:mode` and `isomer_application`.
