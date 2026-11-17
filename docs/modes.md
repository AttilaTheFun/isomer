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
  apple/libraries/remote_head), by URL or over a connection of its own
  (Android's an `IsomerSessionChannel`).

### Web-view mode on the iPhone, the Mac and Android (what there is)

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
- **Android's side** (dev.isomer.runtime's IsomerWebViewHost.kt, Kotlin
  only, `//android/libraries/swift_ui:webview_head_kotlin`):
  `IsomerWebViewHost` owns an android.webkit.WebView and serves the site
  from the APK's assets (assets/site/) at
  `https://appassets.androidplatform.net/site/` (the origin AndroidX's
  WebViewAssetLoader reserves for an app's own files, answered by
  `shouldInterceptRequest`, no AndroidX WebKit needed): a secure context
  (ES modules, wasm streaming, OffscreenCanvas, Cache Storage) and a stable
  origin, so IndexedDB keeps the app's files. Its `channel` is an
  `IsomerSessionChannel` over a WebMessagePort (API 23): once the page has
  loaded, the app posts it "isomer" with one end of a message channel, the
  page answers `{"ready":true}`, then every message either way is one
  session message's bytes as base64 (webview.html takes either channel,
  WebKit's handler or a port). `IsomerWebViewApp(site:)` keeps the web view
  1 × 1 dp and nearly transparent, attached, behind `IsomerRemote(channel)`,
  the Compose renderer. A WebView rather than JavaScriptSandbox
  (androidx.javascriptengine, the same V8 with no view): the page measures
  text with a canvas and keeps the app's files in IndexedDB, and its
  runtime is ES modules and fetch, none of which the sandbox has; and the
  sandbox is asynchronous only, no gain over a port. The system WebView needs
  WebAssembly: any updated one (Chrome 57 or later), not Android 6.0's own.
- **The reactor's compiled code, kept** (session_host.js, every head): the
  page takes the reactor from its own Cache Storage ("isomer-reactor",
  keyed by its `?v=` stamped URL, put there at the first launch) and
  compiles it streaming from there, where V8 keeps the code it compiled
  beside a cached response and takes it back at the next launch (about
  half the compile on Android: "Measured: web-view start" below);
  `?reactorCache=0` (Android's `reactorCache` extra) compiles it from the
  app's files every time, to compare. Each start's
  times go to the head as a log line (`[session] the app's first frame …`:
  logcat on Android, standard error on Apple).
- **The examples**: examples/apple/webview_ios_application, the web
  Storybook's site bundled into an iPhone app (simulator, no profile) that
  compiles none of the Storybook's Swift, and
  examples/android/webview_android_application, the same site in an APK
  with no Swift and no native library of its own
  (`isomer_android_webview_app` in tools/android/defs.bzl); CI's container
  builds both on every pull request.
- **Tests**: the examples' //tests/webview_session:session_test runs the page
  in headless Chrome with the Storybook's guest, as a head drives it: the
  first patch is the whole tree, a tap changes it. It draws nothing (a pull
  request's test). On the iPhone, verify's Apple pictures
  (tools/ci/hosted_apple_test.sh, on GitHub's Mac) open the web-view app on
  each smoke story and check it drew, keeping each launch's start; nothing
  there taps yet. On Android, verify's `android` job (GitHub's emulator,
  after the Storybook's stories) opens the web-view app on
  state.observableobject, taps its button and reads the count change on the
  screen (tools/ci/android_webview_test.sh, uiautomator), then starts it
  cold again with and without the reactor's cache, keeping the times.
- **Open**: Linux's and Windows' heads (WebKitGTK or JavaScriptCore, and
  WebView2, as transports: TODO.md); the platform services the page lacks
  (the app's container for files, the keychain, the clipboard, networking
  without CORS) over the session; an iPhone test that taps (a headful
  XCTest); Android's web view kept across a configuration change (the
  activity's recreation starts a new guest today, as a remote app's
  reconnect does). `--@isomer//:mode=webview` chooses it for an
  `isomer_application` ("The setting" below, whose example has a Mac app
  and an Android app in web-view mode too).

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

`--@isomer//:mode=compiled|webview|remote` (a string flag at isomer's root,
with config settings `@isomer//:mode_compiled`, `:mode_webview` and
`:mode_remote`) for a whole app, which `isomer_application`
(tools/application/defs.bzl) takes on every platform. The examples'
.bazelrc names two: `--config=webview_mode`, `--config=remote_mode`.

`isomer_application(name, swift_library, bundle_id, display_name, …)`
takes the app's one Swift library (its `@main App`, alwayslink,
`-parse-as-library`, on `@isomer//:swift_ui`, so it builds against Apple's
SwiftUI on Apple's platforms and Isomer's elsewhere) and its identity, and
declares each platform's app in every mode, `manual`, with the platform's
own name an alias to the one the build's mode picks:

| Target | `compiled` | `webview` | `remote` |
| --- | --- | --- | --- |
| `<name>_ios`, `<name>_macos` | `_ios_compiled`: rules_apple's application over the library | `_ios_webview`: a generated shell (`IsomerWebViewAppView`) with the web app's site bundled; none of the app's Swift compiled in | `_ios_remote`: a generated shell (`IsomerRemoteView`) over the session at the Info.plist's `IsomerSessionURL` (`remote_url`), or the launch argument `-url` |
| `<name>_android`, `<name>_android_apk` | `_android_compiled`: `isomer_android_app` | `_android_webview`: `isomer_android_webview_app`, a generated Kotlin shell (`IsomerWebViewApp`) with the web app's site in the APK's assets; no Swift, no native library of Isomer's | `_android_remote`: a generated Kotlin shell over `IsomerRemote` (the intent's `url` extra, else `android_remote_url`), no Swift |
| `<name>_web` | `isomer_web_app` | the same | the same |

and `<name>_server`, the app headless (`--@isomer//headless`), serving
itself for the remote apps (ISO_DRIVE_LISTEN, ISO_HEADLESS_PROTOCOL=serve).
The shells are generated from templates beside the macro
(webview_app.swift.tpl, remote_app.swift.tpl, remote_activity.kt.tpl; the
Android web-view one, tools/android/webview_activity.kt.tpl, beside
isomer_android_webview_app), as is the web page of an app without one of
its own (index.html.tpl). A mode
given on the command line puts the whole build in a configuration of its
own; CI builds each mode's apps by name instead, in its one configuration
(tools/ci/container_build.sh: the examples' selection probe,
shared/selection_probe_application, in every mode on the iPhone, the Mac,
Android and the web), and checks by analysis alone that the setting picks
them.

A feature-level choice for `IsomerView` is to come (item 4).

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

## Measured: web-view start, the reactor's code kept (2026-11-17)

The Storybook in web-view mode (its reactor 37 MB, a fastbuild), cold
starts (the process stopped between them), each line's numbers the page's
own (session_host.js's log): the reactor's streaming compile, then the
app's first frame after the head's start.

| Android 15 emulator (arm64, WebView 124), a shared host | compile | first frame after the start |
| --- | --- | --- |
| first launch (the page's caches empty) | 815–2,935 ms | 1,199–3,169 ms |
| from Cache Storage, V8's code kept (7 starts) | 184–555 ms, median 367 | 540–1,161 ms, median 885 |
| from the APK's assets every time (`reactorCache=0`, 5 starts) | 673–1,846 ms, median 769 | 1,111–2,322 ms, median 1,282 |

V8 keeps a module's compiled code beside a Cache Storage response it was
streamed from, across the app's processes (the WebView's "Code Cache/wasm"
in the app's cache folder): a response `shouldInterceptRequest` answers
never reaches the HTTP cache, so the reactor compiles from the start each
time without it. The page loads in 0.4–1.4 s before the start (the WebView's
own start, the runtime's modules). On the iPhone, verify's Apple job keeps
each web-view launch's line (ios-webview-starts.txt in its artifact).

## Order

1. Side modules (isomer#188's first half, once split): every mode gains.
2. Apple's head over a session: web-view and remote apps on the iPhone and
   the Mac.
3. Web-view mode: the in-page runtime behind the session protocol, its
   transport over WebKit's message channel and Android's WebView (all
   there: "Web-view mode on the iPhone, the Mac and Android" above; then
   Linux's WebKitGTK and Windows' WebView2); the platform services over the
   session.
4. Embedded interpreted mode (isomer#188's second half, with its crash fixed
   and its native set profiled per feature).
5. `--@isomer//:mode` and `isomer_application` ("The setting" above).
