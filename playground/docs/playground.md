# Playground — compile-and-run Swift, inside an app

`apple/playground_ios_application` is an agent-driven playground:
describe an app in a chat, a coding agent (any tool-capable model via OpenRouter, or Claude through the
Anthropic API) writes the SwiftUI, and the app compiles it **with the real
Swift compiler, on the device**, into a `iso_hot` wasm feature reactor,
feeds compiler errors back to the agent until the build is clean, and runs
the result two ways:

- **Play (native)** — a full-screen modal: the reactor loads in-process
  under `WasmView` and renders with the REAL SwiftUI renderer
  (`IsomerTreeView`), edge to edge with no chrome — the project's SwiftUI
  is meant to feel like the whole app. Shake the device to get an alert with
  Dismiss/Cancel. The engine is the WasmView default, WasmKit's interpreter.
- **Web** — a sheet: the in-app HTTP server publishes the same bytes and
  `SFSafariViewController` opens the react-renderer page (`web/index.html`,
  which injects the platform services over browser APIs): the browser's own
  WebAssembly engine runs the reactor and the tree mounts as real DOM.

The composer's pills open the **Model** and **Effort** sheets. The model
picker shows the selected model in its own section, then the provider's
catalog: searchable, and (OpenRouter lists hundreds) sortable by most used
for coding (OpenRouter's `?category=programming` ranking — the only
popularity signal its API exposes), coding-arena score (its design-arena
benchmarks), newest, name, price or context, with show-only filters for
popular-for-coding, tool use, image input, free, and a provider. The Effort
sheet offers the efforts the selected model accepts (some add xhigh/max).
Both lists are cached on disk and refreshed in the background.

The chat also takes **images**: the photo button beside the composer attaches
mocks or screenshots (JPEG, ≤1280px) that go to the model as image content
(OpenRouter `image_url` parts; Anthropic `image` blocks). The agent can check
its own work with three tools beyond the file/build ones — `run` (launches
the build **offscreen** and waits for it to load), `screenshot` (captures
that run and returns it as an image; Anthropic gets it inside the tool
result, chat-completions models in a follow-up user turn), `logs` (the
run's status, guest `print()` output and load errors, from `RunMonitor`),
and `close_run`. The system prompt tells it to run → screenshot → compare
with the request or mock → fix → repeat, then close.

**Offscreen runs** (`HeadlessRun.swift`): the agent's build runs in a
screen-sized `UIWindow` behind the app's own (`windowLevel = normal - 1`,
touches disabled), so the user keeps the chat and can play their own copy
full screen at the same time — two WasmView runtimes, each with its own
`WasmViewModel` and dependency table. `drawHierarchy` renders the covered
window for the screenshot (no status bar in it). Only the agent's run feeds
`RunMonitor` (`ServicedWasmView(monitored: true)`); the user's runs just log.
The presenter owns the engine: `HeadlessRun` / `PlayFullScreen` create the
`WasmViewModel` (`WasmViewModel.playground()`, engine injected from the
registry) and hand it to `ServicedWasmView`, so leaving a run is
`model.shutdown(timeout: 1)` — graceful (the build's view tasks unwind,
`iso_hot_shutdown` + job drain) and forced after one second — before the
window or cover goes away; `close_run` reports a forced shutdown to the
agent. Footprint lines (`[playground] footprint …`, phys_footprint) bracket
each run for memory measurements. See docs/wasm_view_architecture.md
"Lifecycle".

**Run snapshots** (`ProjectStore.snapshotForRun`): every build — the play
button's and the agent's `build` tool, both through `ProjectBuilder` —
first copies the sources into a fresh directory under `tmp/runs/<project>/`
and compiles from the copy, writing the wasm beside it. A write landing
mid-compile (the agent's while the user plays, or the user's edit while the
agent builds) is picked up by the next build instead of tearing this one,
and `buildIsCurrent` stays false when the source changed during the
compile. Snapshots are pruned at launch.

**Crash attribution** (`CrashRecorder.swift`): every run leaves a marker
(`Documents/active_runs/<id>.json`: project, agent-or-user, start time)
and streams its status + guest log to a file beside it, removed when the
run's view disappears. A marker left behind means the process died with
that run up; the next launch turns it into a crash record under the
project's `crashes/` (owner, log tail), notes it in that project's
transcript (a red "crash" row — sent to the model as a user-turn note, like
imports), and subscribes to MetricKit so the OS diagnostic (signal,
exception, call-stack JSON), delivered on that next launch, attaches to
the record. The `crash_report` tool returns the project's latest record;
the prompt tells the agent to call it when the user says "it crashed".

**Driving the run** (`HeadlessRun` + five tools): the offscreen run is a
live WasmView, and the host talks to the guest over the same event channel
a finger uses (node id + value), so the agent drives the app semantically
instead of by pixels. `ui_tree` lists every node — path, kind, text,
accessibility label/identifier, placeholder, and what it accepts
(`[tap]`, `[edit]`, `[submit]`, `[drag]`); `tap`, `type_text`, `submit`
and `swipe` take a node by path (`0.2.1`) or by label (accessibility
label/identifier, text or placeholder; exact then prefix, case-insensitive)
and send the event the renderer would send — the nearest handler on, inside
or above the node, so tapping a Button's label taps the button. `swipe`
synthesizes a guest `DragGesture`'s stream (`changed:` over eight steps,
then `ended:` at the requested translation), which is how the 2048 sample
is driven. Native scrolling is the gap: a ScrollView scrolls in the host
and cannot be swiped from here; rows it hides are still in the tree and
still tappable. The mock agent taps `Add` and reads `Count: 1` back.

**Hot reloaders** (`HotReload.swift`): the project list has two sections —
Projects (with a "New Project" row) and Hot Reloaders (with a "New Hot
Reloader" row). A hot reloader is a name, a polling interval and a URL
(GitHub Pages works) that returns the published versions of an app as JSON
— a bare array or `{"versions": [...]}`, newest first, each `{"version",
"url" (absolute or relative to the JSON), "notes"?, "published"?}`; the
`url` is a Isomer feature bundle (a `iso_hot` reactor built against
the framework version the Playground embeds).
`tools/playground/publish_hot_reload.sh <site-dir> <app.wasm> [version]`
maintains that JSON beside the wasm for a static site, so a remote Claude
Code / Codex session can publish builds while the phone follows along.
Opening a hot reloader fetches the list; invalid JSON or an empty list is
an alert (Retry / Cancel). Otherwise the newest version's wasm is fetched
and run full screen like a project's build; the first run explains which
version is running, that new versions announce themselves, and that a
shake exits. Polling continues while it runs: a newer version shows an
alert with Reload (swap in place — the same graceful shutdown as a project
run, then the new bundle) or Later (kept as the pending version; the next
open uses it). The versions are cached per reloader
(`Documents/HotReloaders/<id>/`), so a phone offline still runs the last
fetched build.

Two **research tools** (`WebTools.swift`) let it look things up, like a
search engine and then reading a page: `web_search` returns a short answer
plus the pages found, and `fetch_url` returns one public page or API
response as text (HTML reduced to visible text, JSON verbatim, 30k-char
cap, private hosts refused). Search goes through the signed-in provider so
it rides the user's one key — OpenRouter's `web` plugin (Exa, ~$0.007 per
call, a small model summarizes; `url_citation` annotations become the
result list) or Anthropic's server-side `web_search` tool on Haiku. The
prompt scopes them to facts (find the endpoint, fetch its real JSON, then
write the parsing), not SwiftUI questions. The mock agent fetches
example.com as its first step so the headless loop covers `fetch_url`.

Both build first when the last build is stale: a blocking "Compiling…" panel
over the chat, then either the run or a "Build Failed" sheet (wrapped,
selectable diagnostics with a Copy button).

```sh
bazel run //apple/playground_ios_application:run   # from playground/, this module's root
```

## Projects and templates

A new project starts from a **template**: Blank (an App and a ContentView)
or any bundled example — Counter, 2048, Meme Creator, Wikipedia, Hacker
News, Pokédex. The examples are the example apps' sources
(examples/shared/example_application), copied here
(shared/sample_sources); `samples.bzl`'s `playground_sample`
assembles each into one file at build time (a `@main` wrapper hosting the
screen, imports stripped, plus the platform-services helpers and a `Bridge`
shim where needed), A fresh install seeds one
project per example (each seeds once; a deleted example stays deleted and
can be recreated from the picker). An untouched example is refreshed when
its bundled source changes; one the user or the agent edited is never
overwritten (its file no longer matches the seeded hash). Saved builds are
stamped with the app build and redone after an app update.

## The shell

- **Sign-in splash** until a model provider is linked: a provider picker
  (OpenRouter / Anthropic) + an API-key field + Continue. Keys live in the
  Keychain (`Auth.swift`). OpenRouter's OAuth PKCE flow is implemented too
  (`AuthStore.signInWithOpenRouter`, callback `iso-playground://auth`) but
  not on the splash — in testing the web view never reached the approval
  screen, and a pasted key with a spending limit is the simpler story. A claude.ai subscription cannot be used by a
  third-party app (Anthropic does not allow third parties to offer claude.ai
  login), hence the provider seam — cheap OpenRouter models for testing,
  pricier ones when it matters (Settings lists OpenRouter's tool-capable
  models with prompt prices).
- **NavigationSplitView**: sidebar = projects (+ new project, settings);
  detail = the chat (`ChatView`: the shared `TranscriptView` — bubbles,
  tool activity rows, streaming reply — over the composer) with three
  toolbar items that all present MODALLY (`PreviewPane.swift`): **Edit**
  (the shared `ProjectEditorSheet` around `CodeEditor` — Cancel confirms
  unsaved edits, Save writes App.swift and invalidates the last build,
  Share hands the .swift file to the system share sheet), **Web** and
  **Play** (above; both wrapped in the shared `ShakeToLeave`). There is no
  run button in the editor by design. The screens live in
  `shared/playground_ui` and the web Playground compiles the same
  sources (docs/playground_web.md, "One Playground").
- **Projects** (`Projects.swift`): `Documents/Projects/<id>/{project.json,
  files/*.swift, chat.json}`.

## The agent

`Agent.swift`: a tool loop over a streaming chat model (`LLMClient.swift`
— OpenRouter's OpenAI-style chat completions with tool calls, or the
Anthropic Messages API; SSE parsed by hand, provider-neutral transcript).
Tools: `list_files`, `read_file`, `write_file`, `delete_file`, `build` (the
in-process compiler; returns `ok` or the diagnostics), `run` (shows the
build in the preview), `screenshot`, `logs`, `close_run`, `web_search`,
`fetch_url`. The system prompt pins the Isomer SwiftUI
subset (one module, `import SwiftUI` only, one `@main` App, the skim Foundation subset)
and the workflow (write → build → fix → run). Up to 16 rounds; every
compiler call is serialized on `ToolchainCompiler.queue`.

Headless: `ISO_PLAYGROUND_AUTORUN=agent` with `ISO_PLAYGROUND_AGENT_MOCK=1`
and `ISO_PLAYGROUND_OPENROUTER_KEY=mock` drives a canned transcript through
the REAL loop (write → build fails on a deliberate type error → fix → build
ok → run), logging the transcript — verified in the simulator and on device.
`ISO_PLAYGROUND_OPENROUTER_KEY=<real key>` runs the real model headlessly.

## Foundation and the injected services

Since 0.31 an agent-written app reaches the network, its files and its
settings the way an app on Apple platforms does: `URLSession`,
`FileManager` in its own directories (`URL.documentsDirectory`,
`.applicationSupportDirectory`) and `UserDefaults` / `@AppStorage`, from
Isomer's Foundation. Each project's runs have a home of their own: iOS
gives WasmView `<project>/data` (`WasmViewModel.guestHomeDirectory`), the
web passes `dev.isomer.playground.run.<id>` as the run's bundle identifier
(its files kept in the browser's IndexedDB under it); Android's WasmView
gives a run no home yet. A run's `URLSession` goes through the transports
its host injects (the Playground SDK links isomer's `hot_bridge_network`).
Models are `@Observable`: every Playground compiler expands the
toolchain's prebuilt macros (iOS and Android load the plugin libraries,
the browser runs them as wasm: tools/browser_toolchain/README.md "Macros").

What stays a host service (`shared/platform_services`, swift_ffi
`@ExportedInterface`s the host implements natively, injected per preview
through `apple/platform_services_host`'s
`applePlatformDependencies(namespace:)`):

- `KeychainService.get(key:) async throws` / `set(value:for:) async throws`,
  per project
- `ImagePickerService.pickImage(maxDimension:) async throws -> String` — the
  platform image chooser (PHPicker on iOS, NSOpenPanel on macOS, the system
  content picker on Android, `<input type="file" accept="image/*">` on the
  web), returning a URL of a JPEG copy scaled to `maxDimension` (a `file://`
  copy natively, a blob URL on the web; "" when cancelled) for
  `AsyncImage(url:)`; installed separately (`installPlatformImagePicker`)
  so UI-less hosts can leave it out
- `AnalyticsService.track(event:)`, `ConfigurationService.flag(key:)`
- `DeviceMotionService.nextShake() async throws` — suspends until the next
  shake (UIKit motion events on iOS; the accelerometer on the web, Esc on a
  keyboard; throws where there is no motion so listener loops end);
  installed separately (`installPlatformDeviceMotion`). The Playground's
  own `.onShake` (shake to leave a run) is built on it, and agent-written
  apps can use it too.

**Imported assets**: the composer's + menu imports photos and files into
the run's Documents (`imported/`; the transcript notes them, `list_files`
lists them), where an app reads them with `Data(contentsOf:
URL.documentsDirectory.appendingPathComponent("imported/<name>"))`.

Settings' **Renderer** choice (SwiftUI or Metal for the user's runs; React
or WebGPU on the web page) is UserDefaults' on iOS
(`playground.preferences.renderer`), the host's elsewhere (the page reads
it before boot: `PlaygroundHostService.renderer()`), and applies to the
next run / page refresh.

Feature code reaches the services through `PlatformDependencies.keychain`
etc. (`import PlatformServices`). Async methods simply suspend: swift_ffi's
interface-method effects send a call id ahead of the arguments and the host
answers through the fixed `swift_ffi_async_resume` entry; the guest's Swift
concurrency jobs drain on the host's main queue. The system prompts
document the surface. The out-of-the-box **Pokédex** project is the example
apps' `Pokedex.swift` verbatim (assembled by a genrule with its URLSession
and FileManager helpers and a `@main`), so the same Swift runs in the
Playground and in every example app.

## Deep links

`iso-playground://project/<id>` opens that project's last successful build
(`Documents/Projects/<id>/build.wasm`, saved on every build) full screen
with the services injected; the preview's "…" menu offers "Open full
screen" and "Share link". Relaunching without a link returns to the main UI.

## How a user build works

Two commands, mirroring bazel's own actions for the examples'
`//wasm/hot_demo_feature` (mined from `aquery`):

1. `swiftc -target wasm32-unknown-wasip1 -sdk <WASI.sdk> -resource-dir
   <swift_static> -static-stdlib -parse-as-library -wmo -emit-object` over
   every playground file, compiled **against the bundled SDK**;
2. `clang --target=wasm32-unknown-wasip1` linking the user object +
   the SDK archives (whole-archive) + `swiftrt.o` + the static stdlib with
   the reactor flags (`-mexec-model=reactor`, `--export-all`, 16 MiB stack).

**The bundled SDK** is `wasm_sdk_bundle` (tools/wasm/defs.bzl): a rule that
transitions its deps to wasm32 and collects the transitive `.swiftmodule`s +
static archives into one directory with a manifest — here the slim `SwiftUI`
module + the `hot_bridge` library (`HotBridge.swift` prebuilt, so user builds
never recompile the bridge). User code just writes `import SwiftUI`.

**The compile backend is a seam** (`ToolchainCompiler`):

- *Simulator*: a sim app is an unhardened macOS process, so it can
  `posix_spawn` the HOST SwiftWasm toolchain — the same binaries bazel uses,
  paths injected by `:run` via `SIMCTL_CHILD_ISO_PLAYGROUND_*`. The iOS SDK
  hides `Process`/`posix_spawn`, so `Spawn.swift` resolves them with `dlsym`.
- *Embedded* (`--define iso_playground_embedded=1`) — THE DEVICE BACKEND,
  working: swift-frontend + lld cross-compiled for iOS as static libraries
  (tools/playground_toolchain, staged by build_embedded_toolchain.sh) and
  linked INTO the app (~145MB binary + 193MB of bundled WASI sysroot/static
  stdlib). Compilation is two in-process calls — `iso_swiftc_main` →
  `swift::mainEntry` as `swift-frontend -frontend` (spawns nothing) and
  `iso_wasm_ld_main` → a wasm-only `lldMain` — with diagnostics captured by
  dup2-ing a pipe over fds 1+2. Repeated in-process invocation requires the
  idempotent-init patch (see tools/playground_toolchain/README.md).
  Compiling wasm produces pure data and running it (WasmKit's interpreter)
  needs no JIT pages, so the whole loop is iOS-legal — **verified on a
  physical iPhone 15 Pro** (2026-09-02): `install_device.sh autorun=native`
  compiles the sample in-process about 3s after launch, a second in-process
  compile 25s later also succeeds, and a `@TaskLocal` macro sample expands
  and renders. Both platform variants stage from the same campaign builds.

**Device packaging** (the part the simulator never exercises): iOS only
loads code the bundle embeds in `Frameworks/` *with a signature* — dylibs
shipped as resources are refused by dyld ("missing code signature"). So
`frameworkize_host.sh` (run by the staging script) wraps every host dylib
— the 13 compiler SwiftSyntax libs, the plugin server's own 13 swift-syntax
libs, the in-process plugin server, the prebuilt macro plugins — as a
framework with a SHORT name (`CSyntax`, `SPluginSrv`, …: install_name_tool
can only rewrite a load command in place when the new path is no longer
than the old one, and the simulator dylibs have no header padding — the
first attempt with long names silently left the simulator's references
dangling), rewrites install names to `@rpath/<N>.framework/<N>`, verifies
nothing still points at a `.dylib`, and the BUILD imports each one with
`apple_dynamic_framework_import` (rules_apple copies + signs them). Two
naming rules collide for the macro plugins: the frontend derives a plugin's
module name only from a `lib<Name>.dylib` file name (PluginLoader.cpp), and
rules_apple requires a framework's binary to be named after the framework —
hence `libSwiftMacros.dylib.framework/libSwiftMacros.dylib`, imported
`bundle_only` (copied + signed, never linked) and passed with
`-load-plugin-library`. Provisioning: free-team profiles last 7 days and
allow three sideloaded apps per device (`mint_profile.sh` refreshes; the
install error lists which apps hold the slots). The first launch right after
an install is sometimes refused by SpringBoard ("invalid code signature…
not explicitly trusted") and succeeds on retry — the script retries once.

**Macros work** (embedded backend): the compiler is built with swift-syntax
(`SWIFT_BUILD_SWIFT_SYNTAX`), and the staging ships the compiler's
SwiftSyntax dylibs (which the app links + rpaths into the bundle), the
in-process plugin server, and the PREBUILT macro plugins
(libSwiftMacros — `@TaskLocal`, `@DebugDescription` — and
ObservationMacros). Expansion is `-in-process-plugin-server-path` +
`-load-plugin-library` (per bundled plugin framework): the frontend dlopens
the server, the server dlopens plugin dylibs, still zero subprocesses.
Verified in the sim AND on device: playground code using `@TaskLocal`
compiles and renders. Scope: PREBUILT macro dylibs only —
user-DEFINED macros would need compiling a host-arch plugin at runtime,
which real devices can't codesign (the simulator could; unwired). They ship
as embedded, individually signed frameworks (see Device packaging above).

**The web run** rides `runtime/hot_host.js` — a NEW generic browser host for
`iso_hot` feature bundles (the web peer of the native WasmView): it binds the
four `iso_hot` imports + WASI + inert swift_ffi stubs, drives
`iso_hot_start/render/event`, and mounts tree patches through the react
renderer. No generated bindings, so it can run a reactor compiled seconds ago
on a phone.

## Editor

The iOS editor is a `UITextView` (`CodeEditor.swift`) set up for code:
smart quotes/dashes, autocorrect, auto-capitalization and spell-check OFF
(the keyboard would otherwise turn `"` into `“`), an ASCII-capable keyboard,
Return keeps the previous line's indentation (+4 after `{`), and a **coding
keyboard** accessory row above the keyboard with the characters code needs
(`" ' { } ( ) [ ] < > = : ; . , _ \ / $ ! ? & | * + - @ #`, Tab, hide).
Syntax highlighting is a built-in single-pass Swift lexer over
`NSAttributedString` (keywords, Capitalized types, strings with `\( )`
interpolation left plain, `//` and nesting `/* */` comments, numbers,
`@attributes`/`#directives`), re-colored 250ms after typing settles.

**Syntax squiggles**: half a second after typing stops, the editor runs the
frontend's parse-only action (`swift-frontend -frontend -parse`, ~10ms
in-process on device, spawned `swiftc -frontend -parse` in the simulator)
on the buffer and underlines each error line (red dotted underline from the
error column to the end of the line) with the first message in a red footer.
All compiler invocations share one serial queue (`ToolchainCompiler.queue`)
because the embedded frontend is process-global state and its diagnostics
capture dup2s fds 1+2. `ISO_PLAYGROUND_AUTORUN=check` logs the check for
every file (headless verification).

Build failures present full-screen in a read-only, selectable, wrapping
monospaced text view (`ReadOnlyCodeText`, a UITextView) with Done.

RSPM alternatives, if a richer editor is wanted (all resolvable through the
`swift_package` extension the way the examples' `proto_greeter` pulls
SwiftProtobuf, or this module's graph AgentUI):
`twostraws/Sourceful` (SourceEditor: UITextView + Swift lexer + themes,
closest to this built-in), `raspu/Highlightr` (highlight.js in
JavaScriptCore, 180 languages), `mchakravarty/CodeEditorView` (SwiftUI,
language configurations, minimap), `simonbs/Runestone` (TextKit editor with
tree-sitter grammars — the heaviest, best for large files).

## Build failures and repeated builds

Compiler diagnostics present **modally** (the "Build Failed" sheet: wrapped,
selectable, Copy + Done); a run reuses the last build only while it is
current (an Edit-sheet Save or an agent write invalidates it). Repeated in-process builds needed a second toolchain patch:
LLVM keeps a fixed table of 8 signal callbacks and every `InitLLVM` (once
per `swift::mainEntry`) registers another, so the 9th build aborted in
`report_fatal_error("too many signal callbacks already registered")` — a
compile ERROR did not cause it, the build count did.
tools/playground_toolchain/llvm-signal-handler-reentry.patch re-points an
existing slot for a repeated callback instead; rebuild `LLVMSupport`
(`ninja -C build/<suffix>-llvm LLVMSupport`) and re-stage. Verified on
device: 10 consecutive builds with macros, then 3 consecutive failing
builds, no crash.

## Simulator gotchas (hard-won)

- **Module-cache poisoning**: the frontend's implicit clang-module cache
  lands in the container's `tmp/.cache/clang/ModuleCache`; simctl MIGRATES
  data containers on reinstall (new UUID, same contents), so cached `.pcm`s
  embed a dead absolute path and every later compile fails with
  "was compiled with module cache path …". No flag reliably redirects the
  implicit builds; `ToolchainCompiler` deletes the cache before each build.
- **Stale installs**: some simctl builds silently keep the OLD app bundle
  when version strings match (while still migrating the data container!).
  `run_playground.sh` byte-compares the installed binary and force-reinstalls
  on mismatch.
- **Editor-vs-build races**: swiftc refuses inputs whose mtime moves
  mid-build; sources are snapshotted into the work directory first.
