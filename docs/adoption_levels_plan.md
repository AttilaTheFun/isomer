# Adoption-levels plan (in progress)

Goal (2026-07-05): refine the APIs at each adoption level, port
the SwiftUI `App` protocol/`@main` properly, and ship separate example apps
for incremental (Level 3) and full (Level 4) adoption.

The four levels (docs/adoption_levels.md is the user-facing writeup, §G):

1. **rules_swift** — Swift *runs* on the platform; raw JNI/wasm/C calls.
2. **swift_ffi** — Swift is *easy*: idiomatic Kotlin/TS interfaces, marshaling
   at the boundary. For sharing business logic or building layers like
   isomer.
3. **Embedded isomer** — the `UIHostingController` analogue: a Fragment/
   Composable on Android, a React component (or canvas mount) on web, inside
   an *existing* app. Incremental adoption.
4. **isomer app** — the whole app is SwiftUI: `@main struct ... : App`,
   the platform entry (MainActivity / index.html boot) is *generated*, and
   platform APIs are mapped to SwiftUI analogs (lifecycle → scenePhase,
   intents/URL → onOpenURL, …) with platform-specific modifiers as the escape
   hatch.

## Existing state (recon 2026-07-05)

- `shared/swift_ui_core/App.swift`: `App`/`Scene`/`WindowGroup` + `@main`
  installs via `Runtime.installApp`; `IsomerHostingController` installs a
  root view. WindowGroup `title` is currently unused.
- Web: `boot.js` `boot({canvas,…})` + `mountIsomer(container)` (canvas/
  low-level only; no React-component embed; react path skips input wiring by
  design). Bundled per-app via `web_site`/esbuild.
- Android: ALL Kotlin host code lives in the example app
  (`examples/android/example_application/kotlin/...`): NativeBridge,
  IsomerView (GL), ComposeRenderer, HostViewManager, UIRenderer,
  MainActivity. Bindings (`SwiftUIBridge`) are generated per-app by
  swift_ffi's `kotlin_swift_library` from the app's Swift deps.
- No scenePhase / onOpenURL / lifecycle mapping. No platform-specific
  modifiers beyond representables (`android:`/`html:`… + openURL).

## Work breakdown

### A. Core API refinement (shared/swift_ui_core)
- [x] `ScenePhase` (`active`/`inactive`/`background`) + `@Environment(\.scenePhase)`;
  runtime entry `Runtime.setScenePhase(_:)` for hosts; fires `.onChange`.
- [x] `.onOpenURL { url in }` + `Runtime.openURL(external:)` entry point for
  hosts (Android intent data / web initial-URL + custom events).
- [x] WindowGroup `title` → `host.setWindowTitle` (document.title on web,
  activity label/task description on Android; no-op default).
- [x] `IsomerHostingController`: docs + `rootView` init overload taking
  a concrete `View` value (not just a closure).

### B. Android Level 3: reusable runtime library + embed API
- [x] Move reusable Kotlin out of the example app into
  `android/libraries/swift_ui/kotlin/dev/isomer/runtime/`:
  IsomerHost (NativeBridge minus app specifics), IsomerView (GL),
  IsomerComposable (`Isomer()` @Composable wrapping IsoTree +
  lifecycle), IsomerFragment (embeds either renderer), ComposeRenderer.
- [x] `isomer_android_library` macro (tools/android/defs.bzl):
  kotlin_swift_library bindings for the app's Swift + the runtime Kotlin
  sources compiled together (bindings are per-app, so the runtime kt sources
  are compiled with them; package stays `dev.isomer.runtime`).
- [x] Example app's Kotlin shrinks to app-specific bits only.

### C. Web Level 3: embed APIs
- [x] `react_embed.js`: `<Isomer wasmURL renderer />` React component —
  nested root for the tree renderer (high level) or canvas boot (low level),
  ResizeObserver-driven relayout, unmount cleanup.
- [x] `mountIsomer(container, { renderer })`: renderer selectable,
  react path mounts the tree container instead of a canvas.

### D. Level 4: generated platform entries
- [x] Android `isomer_android_app` macro: generates MainActivity.kt
  (renderer choice via manifest meta-data + intent extra override, back
  dispatch, scenePhase from onResume/onPause/onStop, onNewIntent →
  onOpenURL) + AndroidManifest.xml; example app adopts it.
- [x] Web: index.html stays a one-liner (`mountIsomer(document.body)`);
  boot wires visibilitychange → scenePhase, initial URL + `uui:openurl`
  event → onOpenURL, WindowGroup title → document.title.

### E. Platform-specific SwiftUI surface
- [x] Environment: `\.platform` (existing `Platform.current`) documented as
  the branch point; `#if os(...)` continues to work in bodies.
- [x] Android modifiers (no-ops elsewhere): `.androidStatusBarStyle(dark:)`,
  `.androidKeepScreenOn(_:)` → host chrome calls.
- [x] Web modifiers (no-ops elsewhere): `.webDocumentTitle(_:)`.
- [x] These ride a generic `host.platformCommand(key, value)` channel so new
  platform knobs don't require FFI-surface changes.

### F. Example apps (separate targets)
- [x] `examples/shared/embedded_example`: one small shared SwiftUI view (order-status
  card w/ interactions) used by both embed demos.
- [x] `examples/android/embedded_example_application`: a *normal* Kotlin
  Compose app (native chrome/screens) that embeds the SwiftUI card via
  `Isomer()` composable — Level 3 demo, `bazel run` target.
- [x] `examples/wasm/embedded_example_application`: a static marketing-y
  page with the SwiftUI card mounted inline via the React component + a
  second canvas (low-level) embed — Level 3 demo, `bazel run` target.
- [x] Existing `example_application`s become the Level 4 demos (generated
  MainActivity via the macro; web boot one-liner).

### G. Docs
- [x] `docs/adoption_levels.md`: the four-level story with code snippets and
  pointers to the examples; linked from README + AGENTS.md.

## Verification
- [x] Android: embedded example on the emulator (native screen + SwiftUI card
  interacting), full example still passes the Pokédex/back/sheet walk.
- [x] Web: embedded example headless (CDP driver, scratchpad
  webharness/cdp.py), full example root page still renders in both renderers.
- [x] scenePhase/onOpenURL: verified on Android (uui:// VIEW intent →
  "Opened URL" alert with title+message; home/relaunch → inactive/background/
  active in logcat) and web (WindowGroup title → document.title via CDP;
  embeds keep the host page title). Alert title/message were previously
  dropped by the high-level serializer — fixed in Runtime + both renderers.

## Status
- DONE (2026-07-05). All six sections landed and verified; the emulator
  walk + headless CDP checks are recorded in the commit messages.
