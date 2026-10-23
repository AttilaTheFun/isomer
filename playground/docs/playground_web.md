# The web Playground

`web/playground_web_application` is the iOS Playground's concept as a
static website: the page itself is Isomer SwiftUI compiled to wasm
(the React renderer), with projects in a sidebar, an agent chat per project,
a code editor, and Run — which compiles the project's `App.swift` and mounts
the result full screen in the same page. The goal it serves: "This website is
written in SwiftUI. You can edit it and re-compile the code without leaving
the page."

## One Playground (2026-09-10)

Both Playgrounds compile the SAME screens — `shared/playground_ui`
(a `srcs` filegroup, compiled by the iOS app against Apple's SwiftUI and by
the web app against Isomer's): the transcript (`TranscriptView`:
bubbles, tool activity rows, streaming reply, empty state; each app maps
its chat model to `TranscriptMessage`), the editor sheet
(`ProjectEditorSheet` — Cancel confirms unsaved edits, Save; the editor
VIEW is injected: the iOS `CodeEditor`, and the web's own `CodeEditor` —
a `codeeditor` host view the React renderer draws as a transparent
textarea over a syntax-highlighted `<pre>` underlay, Swift tokenized by
a small regex highlighter, Tab inserting spaces), the
run cover shell (`ShakeToLeave`: the surface is injected — `WasmView` on
iOS, the page's run surface on the web — and a shake asks "Leave the
app?"), New Project (`NewProjectSheet` over the app's templates), and
`.onShake` (below). The chat screen has the iOS shape everywhere: Edit and
Run are navigation-bar items that open modals; there is no Chat/Code
toggle. Platform-bound pieces stay in the apps: the agent session, the
composer (iOS has attachments + model/effort pills), settings, the store.

The **run cover** on the web is a `fullScreenCover` whose content is a
`surface` host view (`RunSurface`): the React renderer hands the element to
`window.isoSurfaceMount(name, element, send)` and `hot_runner.js` parks
the running build's DOM inside it (falling back to its own overlay when no
cover is up — the headless dev hook). Its Stop bar reports "stopped" back
through the host view's value channel; leaving through the shake alert
calls `stop()`.

**Shake** is a platform service — `DeviceMotionService.nextShake() async
throws` in `shared/platform_services` (installed separately, like the
image picker): UIKit's `motionEnded` on iOS (`NativeDeviceMotionService`,
the `UIWindow` override moved out of the app), `devicemotion` on the web
(iOS Safari's permission is requested on the first touch; Esc is the
keyboard stand-in; `window.__playgroundShake()` for tests). `.onShake { }`
in `playground_ui/Shake.swift` runs one `nextShake` loop and hands each
shake to the most recently appeared listener.

**Renderer setting (2026-09-10; removed in 0.38, one renderer a platform: what follows is history).** Settings on both Playgrounds carry the
shared `RendererSettingsSection` (playground_ui/RendererSettings.swift): the
platform's component-system renderer (SwiftUI / React) or the self-drawing
SwiftGPU renderer over its GPU (Metal / WebGPU), stored through the
`PreferencesService` (`renderer` = `native` | `gpu`). Web: `index.html`
boots with `rendererName: "webGPU"` when set, on the next refresh (under
WebGPU the DOM-only host views — the highlighted editor, the run surface —
degrade: the editor becomes a `TextEditor`, runs fall back to the runner's
own overlay). iOS: `WasmView(renderer: .gpu)` draws the user's next run
with `GPUTreeView` (`apple/libraries/gpu_tree_view`: SwiftGPU over Metal
in a UIView, one live instance at a time since the core's `Runtime.shared`
is a process singleton); the agent's offscreen runs stay on SwiftUI. A
self-drawing host must tell the reactor before it starts —
`iso_hot_configure("navigation", "drawn")`, which `WasmFeatureRuntime`
sends when `drawnNavigation` is set — so it emits pre-expanded drawn chrome
(a `DrawnNavBar`, scroll-injected titles) instead of `navstack` host views
the GPU renderer cannot expand; the override survives the reactor's own
`Renderer.bind` at start. Two more fixes for this path: the decoded-tree
draw (`Runtime.drawTree`) now resolves the color scheme
(`setSystemColorScheme` alone left the palette light — white text on a
white window), and `WasmViewModel` buffers patches that arrive before a
consumer attaches (the first full tree lands when the bundle loads, before
the UIView exists). Verified on the simulator: the Pokédex's loading screen
drawn by SwiftGPU over Metal in dark scheme (`--test_env=ISO_PROBE_RENDERER=gpu`
on the play probe; `ISO_GPU_TREE_DEBUG=1` dumps the decoded tree). The
renderer line-up is now: native (SwiftUI / Compose / React) + GPU (the one
SwiftGPU renderer with Metal / OpenGL / WebGPU bound at the SwiftGPU level)
on iOS, Android and the web; GPU only (DirectX / OpenGL) on Windows and
Linux. The starter UIKit renderer and Android's classic-Views renderer were
deleted the same day.

Core additions for this: `fullScreenCover` (a sheet flagged `cover` on the
wire — the whole screen on the web, a real `fullScreenCover` on the iOS
native host), `TextEditor` (a container-filling editor: a full-height
`textarea` / SwiftUI's `TextEditor`; `mono` rides the wire for monospaced
fonts on text and fields), `ToolbarItemGroup` (every button its own bar
item; `.accessibilityLabel` → `aria-label`), `confirmationDialog`,
`navigationBarTitleDisplayMode`, and parity no-ops
(`interactiveDismissDisabled`, `presentationDetents`, `textSelection`).
Nested presentations now stack correctly (an alert inside a cover draws
above it) and alert actions sit side by side.

## Pieces

- **The app** (`App.swift`, `Store.swift`, `Agent.swift` + the shared
  screens): our SwiftUI dialect, no Foundation beyond the skim (UUID/Date);
  projects live in the page's file service (localStorage) under
  `playground/<id>/`; the sample templates are the iOS Playground's
  `playground_sample` outputs served as site assets. The agent is the iOS
  tool loop over OpenRouter chat completions
  (`list_files/read_file/write_file/build/run/logs/close_run`),
  non-streaming.
- **The host service** (`Services.swift` → `Dependencies.playgroundHostService`
  in `index.html`): `compile(source)` (a Web Worker), `run()`/`stop()`/`logs()`
  (the overlay), `chat(body)` (OpenRouter with the key kept in localStorage),
  `toolchainStatus()`.
- **Compile worker** (`compiler_worker.js`): backend 1 is the in-browser
  toolchain — `toolchain/manifest.json` + `swift-frontend.wasm` +
  `wasm-ld.wasm` + resource dir + SDK archives (tools/browser_toolchain; the
  driver `toolchain/driver.js` runs the frontend under a WASI shim over an
  in-memory FS, then the linker). Backend 2, for developing the page before
  that bundle exists: `POST /compile` on
  `tools/playground/dev_compile_server.py`, which runs the HOST toolchain
  with the exact two invocations the iOS Playground's `ToolchainCompiler`
  uses (mined from it) against the `playground_sdk` bundle. Never for the
  published site.
- **Run surface** (`hot_runner.js`): `hot_host.js` — the generic `iso_hot`
  browser host, shipped at the site root beside the ffi runtime it imports —
  mounts the reactor into the app's run cover (or its own overlay with a
  Stop bar when none is up) and keeps a log for the agent.

## Developing

    bazel build -c opt //web/playground_web_application:playground_web_application_site \
                //apple/playground_ios_application:playground_sdk
    tools/playground/dev_compile_server.py \
        --site bazel-bin/web/playground_web_application/playground_web_application_site \
        --sdk bazel-bin/apple/playground_ios_application/playground_sdk \
        --output-base "$(bazel info output_base)"        # http://127.0.0.1:8090/

Headless verification: `node tools/playground/cdp_shot.js <url> <out.png>
[wait] [w] [h] ["x,y;x,y"] [type] [postWait]` (env `CDP_PRE_EVAL="<js>"`
is awaited first — drive the page into a state: open a sheet, start a run)
drives headless Chrome over
CDP (Node's global WebSocket), clicks, screenshots and prints the console —
Chrome's `--screenshot` fires before the wasm app boots, so it cannot be
used. Verified 2026-09-08: the page renders, Run compiles the Counter sample
through `/compile` (17.8 MB reactor) and the overlay runs it.

## The site (`web/splash_web_application`)

`Splash.swift` is the front page (rewritten 2026-09-10 as a post): what
Isomer is, how it works — one render tree and pluggable renderers
(component systems vs the self-drawing SwiftGPU renderer), compiled or
WebAssembly, pluggable GPUs, dependency injection — with the example apps'
own screens (`Counter.swift`, `Game2048.swift`, `Pokedex.swift` from
`shared/sample_sources`, the examples' `shared/example_application`,
compiled into the splash) embedded INLINE as
subviews in `DemoCard`s: a 400×560 rounded, bordered, shadowed frame you
use in place and scroll past, with a pencil that opens that example's
source in the Playground. The page's own pencil (top-right overlay) opens
`Splash.swift`. Commands go through `platformCommand("splash", …)` (boot.js
forwards unknown platform commands to `window.isoPlatformCommand`):
`playground` opens `playground/`; `edit` opens
`playground/?template=This%20website`; `template:<name>` opens the
Playground on that template (the Playground links OUT — it is not embedded
in the page). The page's host injects the same browser services a
Playground build gets (the Pokédex's network + file service).

Two phone reports fixed 2026-09-10: the page could not be touch-scrolled
because `.overlay` / `.background` layers on the web were full-size
absolutely positioned divs that swallowed touches (the page's corner
pencil covered the whole ScrollView; wheel scrolling was unaffected) —
layer boxes are now `pointer-events: none` with only their content
interactive; and the self-drawing renderers (WebGPU here, Metal / OpenGL
elsewhere) laid a `NavigationSplitView` out as side-by-side columns at any
width — below 700 points they now show one column at a time, the sidebar
until a List selection advances to the content/detail (the same
selection-change rule as the semantic hosts), whose bar gets a Back to
the previous column (`Runtime.compactSplitBack`). Verified headlessly
under WebGPU (`CDP_CHROME_FLAGS="--enable-unsafe-webgpu --use-angle=metal"`
on `cdp_shot.js`, `CDP_INIT_SCRIPT` seeding the renderer preference,
pointer events dispatched on the canvas — `boot.js` now tolerates
synthetic pointer ids): sidebar → row tap → detail with Back → sidebar.

Under WebGPU the renderer setting itself could not be changed back: a
`.segmented` Picker drew as a pop-up list, and a presentation opened by
drawn chrome INSIDE a sheet (the list's popover) was appended while the
frame's presentation loop iterated a copy, so it never drew. The loop is
index-based now, `.pickerStyle(.segmented)` draws a real segmented
control (`DrawnSegmented`), drawn bar items are 44-point tinted pills
(`DrawnNavBar`), and `playground/?renderer=react|webGPU` overrides the
stored preference as the way back. Verified under headless WebGPU on both
a tall viewport and a scrolled sheet at phone size.

Finite `.frame(minWidth:maxWidth:minHeight:maxHeight:)` bounds now ride
the wire (`minW/maxW/minH/maxH` params; the web renderer and the iOS
native host clamp the flexible frame) — before, only `.infinity` did, so
the page's 760-point column and the 400-point cards were full-width.
`combine_sites` (tools/wasm/defs.bzl) assembles the splash at the root and
the Playground under `playground/` into `//web/splash_web_application:site`;
`bazel run //web/splash_web_application:serve` serves it (static only — the
dev compile server serves the same directory with `/compile`).

**Build the published site with `-c opt`.** iOS Safari reported
"RangeError: Maximum call stack size exceeded" loading the (fastbuild)
front page on a phone, never in the simulator or on a Mac: JavaScriptCore
surfaces a WebAssembly native-stack overflow as that RangeError, iOS's
WebContent stack is far smaller than macOS's, and `-Onone` Swift frames
are large and deeply nested (every modifier hop is a real call). The
optimized build has a fraction of the stack depth per view; it is also
smaller and faster. Verified 2026-09-10 headlessly (Counter tap, 2048
board, Pokédex list over the network, all four pencils); on a phone it was
still to be confirmed then.

## Publishing

The site is https://attilathefun.github.io/isomer/ (the Playground at
`playground/`), deployed to GitHub Pages by isomer's
`.github/workflows/pages.yml` from an asset of a GitHub release. No compiled
output goes into git: the site is about 115 MB with the in-browser
toolchain, and the compiler in it is built by tools/browser_toolchain from a
Swift/LLVM workspace no CI runner has. So the site is built and packaged
locally and attached to the release:

    tools/playground/package_site.sh --toolchain-from <staged toolchain dir>
    gh release upload <tag> isomer-site.tar.gz

`package_site.sh` builds `-c opt //web/splash_web_application:site` and
`//apple/playground_ios_application:playground_sdk`, stages the toolchain
with `stage_bundle.sh` against that SDK and the Swift SDK's
`wasm32-unknown-wasip1` slice (from the module's output base), puts what the
page fetches in `playground/toolchain/`, and writes `isomer-site.tar.gz`:
the site at the archive's root, dereferenced (Bazel's site is a symlink
tree), with a `.nojekyll`, every file under 95 MB. The compiler, the linker
and the macro plugins don't depend on Isomer, so they come from an earlier
toolchain (`--toolchain-from`: a deployed site's `playground/toolchain`, or
a directory `stage_bundle.sh` staged from a fresh compiler build); the
script unpacks them (the binaries' gzipped parts joined as the manifest
lists them, the plugins sliced out of `bundle.bin.gz` at the manifest's
offsets). The archive is about 90 MB; its largest file is
`swift-frontend.wasm.gz` (33 MB).

Publishing the release runs pages.yml, which downloads the release's
`isomer-site.tar.gz`, unpacks it and deploys it through Actions. Attach the
archive while the release is still a draft; for a release published before
it (or to redeploy one) run the workflow by hand: `gh workflow run pages.yml
-f tag=<tag>` (no tag: the latest release). The repository needs Pages'
source set to "GitHub Actions", and a tag rule (`v*`) on the `github-pages`
environment: a release's run is on its tag, and the environment's default
rule lets only `main` deploy.

Every URL in the site is relative, so it runs under Pages' `/isomer/`
prefix (or any other). Verified 2026-10-19 by serving the unpacked archive
under `/isomer/` from a static server and driving it with `cdp_eval.js`
(Chrome, a fresh profile): the front page renders; in the Playground the
in-browser toolchain is ready 1 s after the page loads, the Counter compiles
in 2.0 s (1.3 s again), runs, and a tap reads "Tapped 1 times"; the Pokédex
(`@Observable`: the macro plugins) compiles in 2.4 s. Every request stayed
under `/isomer/`, none to `/compile`.

Before 0.35 the site was published as committed files in a Pages repository
of its own, removed in 0.35. The hot-reload demo feed
(`publish_hot_reload.sh`: `versions.json` and its reactors) can be served
from any static host; the Playground takes its URL in the hot reloader.

## Tests

`bazel test //web/playground_web_application:smoke --test_output=streamed`
(manual, local: needs Chrome + the host toolchain) serves the site
with the dev compile server and drives the page's dev hook
(`window.__playgroundHost`): compile the Counter sample, run it, tap
"Tap me", and read "Tapped 1 times" back from the tree.
`tools/browser_toolchain/test_wasi_shim.mjs` checks the driver's WASI shim
with a C probe; `test_driver.mjs` runs the whole compile under Node against
a staged toolchain directory once swift-frontend.wasm exists.

## The in-browser toolchain (done 2026-09-09)

`tools/browser_toolchain/` (README there) cross-compiles swift-frontend and
lld to `wasm32-wasip1`: swift-frontend.wasm 97.6 MB (31 MB gzip), wasm-ld
34 MB (12 MB gzip). `stage_bundle.sh --frontend … --linker … --slice
<swift SDK wasip1 slice> --sdk <playground_sdk> --out <dir>` stages the
bundle the worker loads: `manifest.json`, `bundle.bin.gz` (the pruned
resource dir, sysroot subset and Playground SDK — 91 MB raw, 21 MB gzip —
sliced by offsets into the MemFS), and the two binaries gzipped, split into
<90 MB parts when needed. Copy those into `<site>/playground/toolchain/`
(`tools/playground/package_site.sh` does). Verified in headless Chrome: the
worker streams-compiles the frontend from the Cache API (Chrome's code cache
makes later loads instant), the Counter compiles in ~1 s and re-compiles in
0.5 s, links with wasm-ld.wasm, runs in the overlay, and `tap` reads
"Tapped 1 times" back — with no compile server involved. User code's
Foundation is Isomer's, from the Playground SDK; since 2026-10-12 macros
compile too (`@Observable`: tools/browser_toolchain/README.md "Macros").

## Gaps to close

- Streaming chat, image attachments, web_search/fetch_url — carried over
  from iOS as needed. Done: the model setting, and the driving tools
  (`ui_tree`/`tap`/`type_text`/`submit`/`swipe` — `hot_runner.js` reads the
  hot host's retained tree and sends node events; verified with
  `tools/playground/cdp_eval.js` against `window.__playgroundHost`).
- The splash page: demos + "edit this page".
- Sharing more of the Playground: the agent session + LLM client (iOS
  streams SSE over URLSession, the web goes through the host's `chat`),
  the composer with attachments, Settings.
