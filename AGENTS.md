# AGENTS.md — isomer

Context for AI agents (and new humans) working in this repo. Last updated
2026-10-24. If something here contradicts the code, trust the code and
update this file.

## The name

This repo was `universal_ui` until 2026-09-29. It is now **Isomer** ("Isomer
Swift" where the longer name reads better): the repo and the Bazel module are
`isomer`, public types are `Isomer…` (`IsomerView`, `IsomerBridge`,
`IsomerCore`), the Android runtime package is `dev.isomer.runtime`, and the
macros are `isomer_android_app` / `isomer_web_app`. GitHub redirects the old
URL. The internal prefix is `iso` since 0.31 (C symbols `iso_*`, CSS
variables `--iso-*`, `data-iso-*` attributes, `ISO_*` environment variables,
`__iso*` JS hooks, the FlatBuffers namespace `IsoFlat`); it was `uui` (for
"universal UI") before, and docs written then (benchmarks, plans) still say
"UUI". Bundles built before 0.31 (the Playground's hot-reload demo feed, a
Playground toolchain staged before it) export the old `uui_hot_*` names
and need rebuilding.

## The Isomer stack (2026-09-29)

Isomer is Swift across platforms: SwiftUI → SQLite → gRPC Swift 2 → a Swift
server, the client on iOS, macOS, web (wasm), Android, Linux and Windows.
Each piece is usable alone.

**One module since 2026-10-02.** swift_ffi, swift_gpu and swift_map were
repositories of their own; they were folded in to simplify version
management. The repo is ONE Bazel module, `isomer`, plus the examples and
the Playground:

| Directory | Module | What |
| --- | --- | --- |
| `.` | `isomer` | everything below |
| `swift_ffi/` | (isomer) | the Swift <-> Kotlin/TypeScript/C bridge generator: macros, analyzer, generator, rules, runtimes. Labels `//swift_ffi/...` (`@isomer//swift_ffi/...` from outside). Its own examples are `swift_ffi/examples`; docs in `docs/swift_ffi/`. Every BUILD file under it carries `package(features = [swift.enable_v6, treat_warnings_as_errors, ...])` — what its REPO.bazel said when it was a repo; keep that on new packages there |
| `core_graphics/`, `foundation/` | (isomer) | Isomer's `CoreGraphics` and `Foundation` for the platforms without Apple's (see "Apple's frameworks off Apple") |
| `frameworks/` | (isomer) | the other Apple frameworks SwiftUI's interface names, off Apple: `CoreTransferable`, `UniformTypeIdentifiers`, `PhotosUI`. Not Combine, UIKit or Dispatch (see "Apple's frameworks off Apple") |
| `metal/` | (isomer) | Isomer's `Metal` (`//metal/metal`), IsomerMetal (`//metal/isomer_metal`: the MSL→WGSL translator, the backend interface), the web backend (`//metal/web`, `//metal/runtime`) |
| `swift_gpu/` | (isomer) | the GPU abstraction (`//swift_gpu/{core,metal,apple,android,wasm,linux,windows}`) |
| `swift_map/` | (isomer) | the OpenStreetMap renderer (`//swift_map/swift_map/{core,renderer}`, platform libraries under `//swift_map/<platform>/libraries/...`, its example apps and their small tools) |
| `examples/` | `isomer_examples` | Isomer's applications: the Storybook (`examples/storybook`, its apps `examples/<platform>/storybook_<platform>_application`), the Playground (`examples/playground`: write SwiftUI on the device, build it there, run it on Isomer: iOS, web, Android; `examples/playground/AGENTS.md` is its guide) and the example apps and probes. A module of its own: it consumes isomer the way an outside application does. |

Layering still points one way: CoreGraphics < Foundation < swift_ffi <
Metal < swift_gpu < swift_map < the SwiftUI libraries < the Isomer module;
nothing under `swift_ffi/` may depend on anything outside it but Foundation,
and so on up. A consumer pins ONE version of isomer (by version from the
project's registry, AttilaTheFun/bazel_registry, from 0.36.0; a commit
between releases), lists that registry before the BCR in its .bazelrc, and
repeats the root-only overrides (flatbuffers + patches, rules_foreign_cc).

**Versions (from 0.38).** A version is MAJOR.MINOR.BUILD; there are no
point releases. MODULE.bazel and the Playground's apps commit MAJOR.MINOR.0
(the iPhone's build number is always 1, Android's versionCode MAJOR×1,000,000
+ MINOR×1,000 + BUILD); CI stamps each build's own, 0.38.N, N the
Playground's build from the release server's number, and a release is
tagged v0.38.N, the build it releases. The registry's isomer 0.38.N entry is
the tag with one patch setting module() to 0.38.N (its tools/add_version.py
--stamped). The examples' apps are tests and stay at 1.0.

**Pins by version (2026-10-20).** Pins between the project's repos are
by version at a release (a commit is fine on a branch, or on main between
releases). Bazel modules come from bazel_registry, before the BCR: isomer's
releases, visor's, and the forks isomer carries until upstream takes their
changes, as patched versions that sort above upstream's (rules_swift
3.6.1.isomer.1: the fork's commit plus tools/patches' two rules_swift
patches; swift-foundation 6.3.2.isomer.1). A change to a fork or to those
patches is a new entry (.isomer.2), made with the registry's
tools/add_version.py --fork and approved there like any version. Swift
packages are SwiftPM's, through rules_swift_package_manager, never Bazel
modules. tools/released_pins.sh says whether every pin is a released
version (the Playground's and examples' Package.swift by version, no
git/archive override, a local_path_override only inside this repository);
CI's `pins` job runs it on main's commits, and Reviews holds a release until
its commit's `pins` passes. A release is added to the registry once
tagged.

Things the fold taught:

- **The root module must not use rules_js's `npm` extension.** flatbuffers
  hands it a tag rules_js 3 rejects (`root_package`); that is harmless only
  while nobody evaluates the extension. swift_ffi's web example therefore
  declares the two Node APIs it uses by hand (`node.d.ts`) instead of pulling
  `@types/node`, and tsc's version is written in MODULE.bazel.
- **SQLite (0.34).** SQLite is swift_sql's (AttilaTheFun/swift_sql,
  public: the C API as `CSwiftSQL`, the Swift layer `SwiftSQL`; swift_sqlite
  with `CSQLite`/`SwiftSQLite` until 0.35, renamed because Apple's systems
  carry a private `SwiftSQLite` framework whose class names clashed), a Swift
  package only: Bazel takes it through rules_swift_package_manager as
  `@swiftpkg_swift_sql//:SwiftSQL`. Isomer's root has no SQLite
  dependency; the examples list swift_sql in their Package.swift and
  check SQLite's WASI builds under WasmKit (examples' //tests/sqlite_wasi);
  `@isomer//:sqlite` is gone.
- swift_ffi's gazelle setup (`//:update_build_files`) was dropped in the fold.
- **isomer's `swift` extension use is dev-only.** rules_swift takes that
  extension's tags from the last module that uses it, so a non-dev use in
  isomer overrode every consumer's SDK choice. Consumers declare
  `swift.toolchain`/`wasm_sdk`/`android_sdk` and register the Swift
  toolchains themselves (examples/MODULE.bazel is the block to copy).
- **The Playground lives in `examples/playground/`** (since 0.39), part of
  the examples' module (`//playground/...` there): the iOS, web and Android
  apps, the splash page, the compilers' build scripts
  (`tools/playground_toolchain`, `tools/browser_toolchain`), its docs and
  tests; `examples/playground/AGENTS.md` is its guide. It was
  `examples/*/playground_*` until 0.15, a repository of its own until 0.35,
  and a module of its own in `playground/` until 0.39 (one output base and
  one copy of isomer's overrides now, with the Storybook's: one Bazel
  workspace for both apps). What is framework stays in isomer proper: `wasm_sdk_bundle`,
  `site_imports_test`, `assemble_directory` (tools/wasm/defs.bzl), WasmView,
  `AppHostViews`, hot_host.js. The headless Chrome drivers
  `cdp_shot.js`/`cdp_eval.js` are in `tools/testing` beside cdp.py.
- **isomer has no agent_ui dependency** since 0.16: the transcript stress
  apps (the only users) moved to the Playground. The examples' SwiftPM
  graph is SwiftProtobuf, gRPC and swift_sql.
- **wasi-threads**: the Swift change it was for merged upstream on
  2026-10-09 (swiftlang/swift#92018, multi-threaded Concurrency for
  `wasm32-unknown-wasip1-threads`; swift-platform-executors#33 before it),
  so its test cell (`wasm_threads/` here until 2026-10-02, then a
  repository of its own) is gone; the main snapshots after that date carry
  the change. Threaded modules run under WasmKit's WASI Threads (below).

What building a whole application on the stack taught (a todos app, with a
gRPC server over PostgreSQL, was the reference until 0.35, when it moved to
a repository of its own):

- **Foundation on wasm/Android** is Isomer's (//foundation, from the
  swift-foundation fork; see "Foundation and CoreGraphics" below). Every
  SwiftPM package an app links there depends on `@isomer//:foundation`
  through `configure_package(target_deps = ...)` in its MODULE.bazel;
  `tools/foundation/check_link.py <app targets>` finds one that doesn't.
- **Two modules, one RSPM extension**: a module that has its own SwiftPM
  graph AND depends on one that does re-exports `swift_deps` from its own
  `.bzl` (extension identity) and `override_repo`s the dependency's package
  repos onto its graph. Generated package repos see the apparent repo names
  of the module that owns the extension (hence `rules_license`,
  `build_bazel_rules_apple` deps and `inject_repo(build_bazel_rules_swift)`).
  The examples do this for their graph.
- **A server built in a Linux container from a consumer's module** means
  that module has to resolve on Linux.
- **C for wasm**: rules_swift's wasm cc toolchain gave compiles no clang
  resource directory, so clang found `<stdarg.h>`/`<stddef.h>` in the host
  toolchain by an absolute path that Bazel's inclusion check rejects; C
  compiled for wasm had to avoid them (-nobuiltininc and shims, a
  hand-declared pthread_self). tools/patches/rules_swift_wasm_clang_resource_dir.patch
  (0.34; in the registry's rules_swift 3.6.1.isomer.1 since 0.36) gives
  compiles the Swift SDK's clang resource directory, as links already had:
  the headers come from the SDK, among the action's inputs. A package's C
  (swift_sql's amalgamation, through rules_swift_package_manager) then
  builds for wasm as is.
- **No Dispatch on wasm**: guard with `#if canImport(Dispatch)`.
- **Browsers cannot speak gRPC**: a web client uses gRPC-Web (a
  `ClientTransport` over an HTTP closure) to a proxy such as Envoy. Envoy's
  image entrypoint fails under rootless Podman (chown of stdout): run
  `/usr/local/bin/envoy` directly.
- **Views and `@MainActor`**: Isomer's `View`, `App`, `Scene` and
  `ViewModifier` are `@MainActor @preconcurrency`, as SwiftUI's are (since
  2026-10-01): a view an app declares is main-actor isolated, `body` and
  helpers alike, and `.task`/`.refreshable` closures run as the actor they
  are written in. Nothing has to be marked. Isomer's own views take the
  conformance in an extension and their modifiers are `nonisolated`, so —
  like Apple's `nonisolated` initializers — they can be made anywhere
  (a free `@ViewBuilder` function, a default argument). A host's entry
  points (C exports, JNI, a native loop) call the runtime inside
  `MainActor.assumeIsolated`.

- **Frames build only what changed** (shared/swift_ui_core/InPlace.swift,
  since 2026-10-10). A frame whose changes are all keyed (a `@State` write,
  an `@Observable`'s change, a list's window)
  rebuilds just the views owning them, where they stand in last frame's
  tree, unless one registers for a container above it (a title, a toolbar
  item) or the tree holds a volatile build; then the whole tree is built,
  as before. The public `Runtime.setNeedsRender()` asks for a whole build
  (for an app's own value changed outside any state); the core's own paths
  use `requestFrame()`. Composite-node changes made by modifiers in place
  are recorded and replayed; a container that changes a child's node any
  other way must call `pinRebuildSite()` on it first. `ISO_VERIFY_PARTIAL=1`
  in the host's environment (the mock tests set `verifyPartialFrames`)
  compares each partial frame with a whole build and logs differences
  (`[partial] differs`); a value the app deliberately leaves untracked
  (Visor's `SessionTranscript` batching) can show up there legitimately.
  `ISO_PARTIAL=0` turns partial frames off for comparison.

## What this repo is

A cross-platform **SwiftUI subset**: one Bazel module builds the same SwiftUI
application code for every platform. The application code lives in `shared/`;
each platform directory wraps it with a native renderer/host:

| Directory  | Platform            | How it renders                                    |
| ---------- | ------------------- | ------------------------------------------------- |
| `apple/`   | iOS / macOS         | the real SwiftUI via rules_apple (local Xcode)    |
| `android/` | Android             | Swift cross-compiled; Jetpack Compose (component system) or SwiftGPU/OpenGL ES (self-drawing), Kotlin host via JNI |
| `wasm/`    | shared wasm build   | Swift → wasm32-unknown-wasip1 libraries; apps live in `web/` + `electron/` |
| `web/` + `electron/` | Web / Electron | React (component system) or SwiftGPU/WebGPU (self-drawing) over the wasm libraries |
| `linux/`   | Linux (SteamOS etc.)| native swift_binary, SwiftGPU/OpenGL over SDL2 (self-drawing) |
| `windows/` | Windows             | native swift_binary, SwiftGPU/D3D11 (self-drawing) |

**At most two renderers a platform** (2026-10-15): SwiftUI and
Metal on iOS and macOS, Compose and OpenGL on Android, React and WebGPU on
the web, DirectX on Windows, OpenGL on Linux. The UIKit and Android Views
renderers (and their baseline benchmark cells) and the WinUI stub are gone.

**Design goal** (see docs/renderer_layers.md + docs/renderer_parity_plan.md):
- **Component-system renderers** (React, Jetpack Compose) build the UI from the
  platform's *native components* and should feel native to that platform —
  Material on Android, web-idiomatic on the web — even where that differs
  from iOS.
- **The self-drawing `SwiftGPURenderer`** draws *everything* — chrome
  included — at the GPU layer (WebGPU, OpenGL ES, Metal backends via
  swift_gpu), so every GPU backend looks and feels the same. The only native bridges there are
  app-authored representables and the invisible IME-capture text input.

**The Storybook** (examples/storybook/, the examples' `//storybook`, since
0.38; in isomer's root until 0.39): every
SwiftUI API Isomer implements, a story each (stories/<Area>.swift), its
page the story's code, what the API does and the code running. A story's
view sits between `// story: <id>` and `// end story` lines; :snippets
(snippets.awk) copies that source into the page's table, so the code shown
is the code run. It is the primary integration test: the Storybook apps
(examples/<platform>/storybook_<platform>_application,
com.LoganShire.IsomerStorybook, "Storybook"), one a platform with that
platform's renderer, are released with Isomer, and their proof is a
screenshot of every story's page (`ISO_STORYBOOK_STORY=<id>` opens one; the
web page's `?ISO_STORYBOOK_STORY=`). A story uses only what both Apple's
SwiftUI (iOS 17, macOS 14) and Isomer's have: the web build is the check.
The mini apps are the Playground's canned projects only.

**The release proof** (tools/proof/proof.py, since 0.38): Isomer's two apps
on its six platforms, one renderer each (SwiftUI on iOS and the Mac,
Compose on Android, React on the web, OpenGL on Linux, DirectX on
Windows): the Storybook's every story, and the Playground's projects with
2048 and the Pokédex built on the device and running. On the iPhone the
Storybook is also compiled against Isomer's frameworks
(examples/apple/storybook_isomer_ios_application: a test, not released)
and every story is held to Apple's SwiftUI's same screen
(review-ios-storybook-isomer: a reference, a diff and changed pixels each,
and Reviews' parity): they should match, and a difference is Isomer's (it
found radial and angular gradients drawn linear, Grid's columns unaligned
and text runs' `.primary` drawn at the Mac's 85% black in the tree view).
The platforms run at once, each on its own oss lease, after this Mac's
builds; the runs go to the review server, and Reviews holds a release
until its commit has them.

**Adoption levels** (docs/adoption_levels.md): (1) rules_swift — raw Swift
on the platform; (2) swift_ffi — idiomatic bindings; (3) embedded Isomer
— `Isomer()` composable / `IsomerFragment` / `<Isomer/>`
React component / `mountIsomer` inside an existing app (see the
example_partial_* application targets); (4) whole-app SwiftUI — `@main App`
with generated platform entries via `isomer_android_app` /
`isomer_web_app` (tools/{android,wasm}/defs.bzl), lifecycle mapped to
scenePhase/.onOpenURL/window titles, platform modifiers over the
`platformCommand` channel.

## The layers (formerly three repos)

```
SwiftUI libraries  →  swift_map/  →  swift_gpu/  →  metal/  →  swift_ffi/  →  foundation/, core_graphics/  →  rules_swift
```

- **rules_swift**: this project's Swift-SDK cross-compilation work is merged
  upstream (PRs #1817 wasm, #1818 Android, #1819 Windows, #1820 linkshared,
  #1821 SDK frameworks, #1830 Android dispatch autolink). MODULE.bazel pins
  rules_swift via `git_override` (see the comment there for the current
  commit and why). **The one standing action: when the next rules_swift
  release is tagged, replace the git_override with a plain `bazel_dep`
  version** (here and in examples/MODULE.bazel).
- **`swift_ffi/`**: the FFI layer (macros → aspect → codegen → idiomatic
  Kotlin/TypeScript bindings). It has its own AGENTS.md; its paths there are
  relative to `swift_ffi/` as they were when it was a repo.
- **`swift_map/`**: the Swift OpenStreetMap renderer. It
  backs the Isomer module's `Map` view (Isomer's, not MapKit's: `import
  Isomer` on every platform): on Apple the real Metal-rendered map
  (apple/libraries/swift_ui/Map.swift, with a two-way MapCamera binding
  incl. bearing/tilt); on every SwiftGPURenderer
  platform (web/Android/Windows/Linux) the renderer draws real SwiftMap
  tile scenes inline (a "map" hostView node claimed via
  `HostBridge.drawHostView`; the engine's tiles ride the existing
  imageInfo/rasterize services, drawn through a RegionRenderPass that
  remaps the frame's matrices into the node's rect — gated on
  `Renderer.hostRendersMaps`, set by the binding bridge). wasm/Android
  link `//swift_map/{wasm,android}/libraries/swift_map_engine:engine` (the
  bridge-less SwiftMap module), behind the `//shared:map_engine_*` label
  flags (`--config=map`; on by default in the examples). Component-system renderers show the
  placeholder (shared/swift_ui_extensions/Map.swift). Host-drawn specs
  are excluded from the native host-view sync (RenderPass.hostDrawnViewIDs)
  or the host's fallback overlay swallows pointer events over the map; the
  Android remote-image loader sends an identifying User-Agent or
  tile.openstreetmap.org serves 403 "Access blocked" tiles. `Map(camera:annotations:
  polygons:polylines:onAnnotationTap:)` also renders overlays: MapAnnotation
  (billboarded dot markers with `title` callouts on tap), MapPolygon
  (map-plane fill + stroke), and MapPolyline (open paths, round joints),
  drawn inside the map's GPU pass; taps hit-test in the engine and the
  built-in callout is native text repositioned per frame. Example: the "Map Explorer" catalog screen (zoom slider top
  right, tilt/rotate pad bottom left, pan pad bottom right, SF landmark
  markers + the Golden Gate Park polygon).
- **`metal/`**: Isomer's Metal (0.31; see "Apple's frameworks off Apple").
  In a browser SwiftGPU runs on it: navigator.gpu is touched only by
  metal/runtime/isomer_metal_webgpu.js.
- **`swift_gpu/`**: the
  GPU abstraction. Its Metal backend (swift_gpu/metal/MetalGPUDevice.swift)
  is one source for Apple's Metal (swift_gpu/apple adds the MTKView
  surface) and Isomer's (swift_gpu/wasm adds MetalWebSurface over
  IsomerMetalLayer); GL and D3D calls stay in its android, linux and
  windows backends. isomer's single
  self-drawing renderer is `SwiftGPURenderer`
  (shared/swift_ui_core/SwiftGPURenderer.swift — one of only two
  `import SwiftGPU` sites outside swift_gpu and swift_map, canImport-guarded): shapes via
  the SDF rect pipeline, text/gradients/shadows/images host-rasterized
  through `HostBridge.rasterize(spec) -> [UInt8]` ([w u32][h u32]
  [premultiplied RGBA]), clips as scissors. Wired on web (runtime/raster.js
  rasterizes; boot.js's ensureMetalHost makes the page's one Metal executor,
  `createIsomerMetalHost(canvas)`, and `host.connect(bridge)` installs it,
  then isoSetDisplayScale) and Android
  (NativeBridge.rasterizeSpec, nativeSurfaceChanged px feed, nativeRender
  draws in Swift and returns an empty draw list; UIRenderer keeps the
  wantsRender continuation on that path or nav transitions freeze; its GL
  context is current on the main thread, MainThreadGLSurface, since 0.38:
  the runtime is main-actor isolated, and GLSurfaceView's render thread
  trapped in `MainActor.assumeIsolated`).
  Windows (DirectXGPUDevice over D3D11; the host rasterizes via
  DirectWrite / offscreen D2D / a CPU Gaussian shadow / WIC, and keeps its
  native widget layer — EDIT overlay, Win32 picker/webview children) and
  Linux (GLGPUDevice over the host's core-3.3 SDL context; SDL2_ttf / CPU /
  stb rasters; the C renderer keeps its mini GL pipeline solely for the
  drawn control cards + popups) are migrated too — all five
  reimplementation platforms render through the one SwiftGPURenderer.
  Backend pixel checks: swift_gpu's directx_backend_check (Windows) /
  gl_backend_check (Linux, EGL pbuffer; under WSL run with the swift.org
  runtime on LD_LIBRARY_PATH).

## Toolchain (MODULE.bazel is heavily commented; read it)

- **Bazel 9.1.1** (`.bazelversion`). Required: rules_swift main uses
  `include()` in MODULE.bazel, which Bazel 8 consumers choke on
  ("include() ... can only be used in the root module"). Upstream will bump
  their minimum eventually; it has not been raised with them.
- **rules_swift 3.6.1** + `git_override` (the commit and its reason are in
  MODULE.bazel; swap for a plain `bazel_dep` at the next release — see above).
- **`apple_support` must be declared BEFORE `rules_cc`** in MODULE.bazel, or
  rules_cc's local darwin toolchain (no `CC_TARGET_TRIPLE`) outranks it and
  Swift compiles fail with "Invalid target triple: local".
- **Android C/C++** comes from `hermetic_android_toolchains` (keith's):
  `@androidndk//:all` supplies the cc toolchains the Swift Android toolchain
  links through (NDK r27c, API 28); `@androidsdk` (SDK 35 / build-tools
  35.0.0) feeds rules_android via `override_repo(rules_android_sdk, androidsdk)`.
  libc++ is linked **statically** (upstream's merged choice); there is no
  `select_android_runtime_lib` anymore and no libc++_shared.so in the APK.
- **Swift toolchain**: swift.org 6.3.2 host toolchain + matching wasm/Android
  Swift SDK bundles, via rules_swift's `swift` extension. Toolchain versions
  must match the SDK bundle versions exactly.
- The wasm/android targets are plain `swift_library`/`swift_binary`
  (`linkshared` for Android) built through platform transitions in
  `//tools/platforms`. The old `//tools/swift_cross` is deleted.

## Repo state

Everything lives on `main` — the android-rules-migration, renderer-parity,
swift-ffi-integration, and adoption-levels workstreams are all merged and
pushed (docs/*_plan.md files record how each landed). Android builds with
rules_android's `android_binary` + rules_kotlin's `kt_android_library`; the
old bespoke kotlinc/d8/aapt2 pipeline is gone from use, but `tools/android`
still hosts the emulator runner (`apk_install_run`) and the Level 4 codegen
templates. iOS device builds need the team's Xcode-managed wildcard
profile ('iOS Team Provisioning Profile: *'); a machine without it fails
them — an environment issue, not code; exclude iOS from wildcard
verification builds. The Playground is com.LoganShire.IsomerPlayground
("Playground", Playground.app; Android the same); the examples' apps share
com.LoganShire.IsomerExamples.

## Build & run (macOS host)

```sh
# Apple
bazel build //examples/apple/storybook_macos_application/...
bazel run //examples/apple/storybook_ios_application:storybook_ios_application_project  # Xcode proj

# Android — builds APK, boots the hermetic emulator, installs, launches.
# Compose is the ONLY supported Android renderer. The Android axis is delivery,
# not renderer: [full|partial] x [compiled|wasm] (SwiftUI linked as native
# Swift, vs shipped as an in-process wasm bundle). SwiftGPU still works as a
# library (--es renderer openGL) but is not an endorsed Android app path.
bazel run //examples/android/storybook_android_application

# Web (wasm) — serves via hermetic Python; ReactRenderer,
# …example_full_webgpu_web_application is the SwiftGPU-drawn twin.
bazel run //examples/web/storybook_web_application
# Electron desktop wrapper (…webgpu_electron… = SwiftGPU-drawn twin)
bazel run //examples/electron/example_full_react_electron_application

# Partial (Level 3 embed) variants exist for android/web/electron:
# android: example_partial_{compiled,wasm}_…; web/electron:
# example_partial_{react,webgpu}_… — see README's tables.

# Linux/Windows: Linux builds in a container here (tools/linux/build.sh) and
# runs on an oss VM, Windows builds and runs on the oss Windows VM (see
# "Platform tiers").
```

## Platform tiers (2026-10-13)

Linux and Windows are T3, wasm and Android T2, iOS and macOS T1. T1 (iOS, macOS): simulators and
the Mac on every change. T2 (wasm: web and Electron; Android): headless
Chrome and the hermetic emulator. T3 (Linux, Windows): built and run on
oss machines (~/Developer/AGENTS.md), never on this Mac's own screen.

- **Linux from a Mac**: `tools/linux/build.sh [targets]` builds in a
  Linux container of Apple's `container` (isomer-linux-build: an Ubuntu
  image with Bazel and the libraries the Linux targets link: SDL2, SDL2_ttf,
  GL/EGL, GTK 3, WebKitGTK; made with `container build` if missing, the
  container kept between builds, `--stop` to remove it; an oss container
  until 0.38, when oss became the GUI machines' alone). The container is arm64: MODULE.bazel registers swift.org's
  ubuntu24.04 toolchains for aarch64 as well as x86_64, wasm SDK included
  (the wasm cell's reactor). tools/proof/proof.py runs what it builds in
  an oss Linux VM.
- **Windows on the oss Windows VM** (`oss machine lease windows
  --config=swift-6.3.2`, the build layer tools/ci/oss/windows-swift.ps1
  makes): Bazel in MSVC's environment (vcvarsall arm64) with
  `BAZEL_SH` Git's bash, Git's usr\bin on PATH (rules_swift_package_manager
  runs find, cp and od), `--output_user_root=C:/b` (short paths) and
  `--repo_env` for SDKROOT, PATH and MSVC's variables (repository rules see
  nothing else). The Playground carries
  tools/patches/rules_swift_package_manager_windows.patch for its SwiftPM
  graph there (and the examples, for the Storybook's). tools/proof/proof.py
  has the whole recipe. No Swift
  toolchain cross-compiles to Windows.
- docs/open_items.md lists what is open, by tier.

## WasmKit and wasi-threads (0.33; the only engine since 0.38)

Since 0.33 Visor Isomer's iPhone app runs on WasmKit with interpreted
wasi-threads Swift; since 0.38 WasmKit runs reactors on every native host
(WAMR, Isomer's engine before it, and WAMR's AOT tier were removed then:
no wamrc, no `.aot`, no `--define wamr_*`). The engine work is in the
WasmKit fork (measured against WAMR on the same reactor); what is here is
how Isomer runs it.

- **WasmKit** (MODULE.bazel's `wasmkit`: AttilaTheFun/WasmKit, the fork,
  pinned by commit; built by tools/wasmkit/BUILD.wasmkit.bazel after its
  Package.swift, default traits, optimized in every build, for macOS, iOS,
  Android, Linux and Windows) is behind `WasmKitRuntime`
  (//shared/wasm_host:wasmkit_runtime). Apple's WasmView registers it as
  the default engine (`WasmRuntimeRegistry.registerDefault`; an app may
  register its own first); Android's WasmView runs it as a Swift library of
  its own (android/libraries/wasm_view: engine/WasmKitEngine.swift, reached
  from the Kotlin `WasmKitRuntime` through generated bindings; a process
  runs reactors or an app's compiled Swift, not both); the Linux and Windows hosts drive
  `WasmFeatureRuntime` over it. It lays out WASI as the hosts always have
  (/tmp, /home/app, HOME and XDG_*), binds the six iso_hot callbacks and
  swift_ffi through `SwiftFFIHostRuntime` (the dependencies' register
  exports called at launch), and drains jobs on the main queue, held while
  a tree is undrawn. Nothing of Isomer's goes into the fork. iOS 18 and
  macOS 15 (WasmKit's Synchronization): so, since WAMR went, WasmView and
  every app that hosts reactors (the examples' wasm cells raised with it). `ISO_WASMKIT_TRACE=1` prints each guest
  thread's instance and each swift_ffi import with the thread it came on.
  The engine tests (examples //tests/wasm_engines) run it beside JSC and
  WasmEdge.
- **WASI commands**: //tools/wasm/wasi_run runs a command module under
  WasmKit with `iwasm`'s options (`--dir=`, `--map-dir=<guest>::<host>`,
  `--env=`; also `--stack-size=`), the guest's stdout, stderr and exit
  code, and WASI Threads for a module that imports a shared memory. The
  checks built for wasm run under it (//foundation/tests, the Metal
  translator's, the examples' //tests/sqlite_wasi).
- **The threads SDK beside the stock one.** rules_swift takes one
  `swift.wasm_sdk`; tools/patches/rules_swift_wasm_threads_beside.patch
  (in the registry's rules_swift 3.6.1.isomer.1 since 0.36) takes two, the
  threads one's toolchains requiring
  `@rules_swift//swift/toolchains/wasm:threaded`. A reactor transitioned to
  `@isomer//swift_ffi/rules:wasm32-wasip1-threads` builds with
  AttilaTheFun/swift's threads-sdk-6.3.2-1 (#92018 and the
  platform-executors thread pool); everything else stays single-threaded.
  A threaded reactor links its memory imported, exported and shared with a
  maximum (`--import-memory --export-memory --shared-memory
  --max-memory=…`); examples' tap_counter_threads_release.wasm and
  example_full_threads.wasm are the test cells.
- **The guest's threads.** In a threaded reactor swift_ffi's executor is
  the main actor's only: the platform's default executor, the SDK's pool of
  guest threads, runs everything else (`SwiftFFIExecutorFactory` under
  `_runtime(_multithreaded)`), and `SwiftFFILock` is a pthread mutex. A
  host import called on a guest thread runs on the host's main thread
  (posted when it answers nothing, waited for when it does). Foundation's
  `Thread.isMainThread` there is foundation/wasi_thread_identity's: the
  thread that ran the constructors. WasmKit's WASI Threads is
  process-scoped: a threaded instance is kept for the life of the process
  (no teardown, no hot reload), and a trap on a guest thread ends the app.
- **No ICU in the threads SDK** (it carries the standard library only, and
  the stock SDK's lib_FoundationICU.a has no atomics): a threaded reactor
  is built without FoundationInternationalization (visor_isomer's
  `threads_wasm_resource`). Visor formats its dates and numbers itself;
  its screens match the ICU build's.
- **Shared memory needs WasmKit's guard pages**: a 4 GiB reservation per
  memory and signal-trapped bounds checks, on macOS, Linux and (since the
  fork's 285def1) iOS. Android and Windows check bounds in software and
  run no threaded reactor (on Android by
  tools/patches/wasmkit_android_software_bounds.patch: WasmKit's C takes
  Android for Linux). `WasmKitRuntime.canRunThreads` tries one; a host
  with both builds of its reactor picks the threaded one only then (an
  iPhone's address space may refuse it; nothing here has run on a device).

## Apple apps compiled against Isomer (0.32)

An Apple app's Swift can be compiled natively against Isomer's frameworks
instead of Apple's (2026-10-13: an A/B of the two on one source, and
Isomer's frameworks where Apple's are too new for an older iOS; the blue
Visor, com.LoganShire.VisorIsomer, is built this way, the red one with
Apple's). `isomer_compiled_feature` (apple/compiled/defs.bzl) builds a
feature's libraries in a configuration of their own: //apple/compiled:feature
on (`@isomer//:swift_ui` is then //apple/libraries/compiled_swift_ui, the core
named `SwiftUI`), rules_swift's module mapping //apple/compiled:mapping (every
module that is Apple's name or that the host builds too is compiled under a
name of its own, IsomerCompiledSwiftUI and so on, so the two sides link into
one binary with nothing in common), and the app's `main` renamed
`iso_feature_main`. The feature links
//apple/libraries/compiled_swift_ui:hot_bridge, the reactor's HotBridge.swift
compiled natively (its imports are the host's callbacks,
apple/libraries/native_runtime/iso_hot_native.h); the host app registers
`NativeFeatureRuntime` (the wasm engine seam over the C exports) and shows
`WasmView(provider: CompiledFeatureProvider())`, so WasmView runs it as it
runs a reactor. examples/apple/tap_counter_compiled_isomer_ios_application is
the example (simulator: `--ios_multi_cpus=sim_arm64`); visor_isomer's
applications/visor_isomer_compiled_ios is Visor's whole client so. The
features are iOS 16: SwiftUI, Observation and Synchronization are Isomer's
there, Foundation still Apple's. (An app that shows one through WasmView is
iOS 18 since 0.38, WasmView linking WasmKit: the example is.) What the feature's configuration has and what bit:

- **Observation and Synchronization are Isomer's** (since 2026-10-14),
  so a feature runs below Apple's iOS 17 and 18: //apple/libraries/
  compiled_observation is the toolchain's own open-source Observation
  (swift-6.3.2-RELEASE sources; its README says what differs: a pthread
  thread-local, no `Observations`), compiled_synchronization a `Mutex` of
  Isomer's (all the feature libraries use of it). The mapping renames both,
  so `import Observation` and Apple's Foundation's `@_exported import
  Observation` name Isomer's; the binary weak-links Apple's (the host's
  SwiftUI side reads it behind `#available`). `@isomer//:foundation` there
  is a group of the two, so every library that depends on Foundation finds
  them. `@Observable` expands with the toolchain's ObservationMacros plugin.
- **ISOMER_COMPILED_FEATURE** (the compiled SwiftUI's copt): the core
  calls its own Observation's tracking scope (as on wasm and Android), and
  what is Isomer's own carries no iOS 17 or 18 marks (`#if
  !ISOMER_COMPILED_FEATURE` around the `@available`). `TextSelection`'s
  ranges are //apple/libraries/compiled_backports' `RangeSet` there (the
  standard library's needs iOS 18).
- **CoreTransferable is Isomer's** there too (compiled_swift_ui:
  core_transferable, //frameworks/core_transferable's `Transferable` with
  Data, URL, String and Never; Apple's needs iOS 16): the mapping renames
  it, so SwiftUICore's import of it names Isomer's, and ShareLink,
  SharePreview, `dropDestination` and PhotosUI's `loadTransferable` stand on
  it.
- **iOS 16 is the floor** (2026-10-14: stay at 16 rather than
  override the standard library): below it a feature would need the
  standard library's iOS 16 types (`Duration`, `Clock`, `Regex`) of Isomer's
  own. The host side is iOS 18 / macOS 15 since 0.38: WasmView runs
  reactors on WasmKit, which stands on Swift's Synchronization (Mutex,
  Atomic), so the examples' wasm apps (example_full_wasm_ios_application,
  iOS 15 until then) were raised to 18. visor_isomer's wasm blue Visor
  (visor_isomer_ios, iOS 15) needs the same raise when it moves to isomer
  0.38. The tree renderer itself still keeps newer APIs behind availability
  checks from its iOS 15 days.
- RSPM refuses a package to an app below the package's own minimum:
  visor_isomer lowers AgentUI's (iOS 18 → 16) with a `patch_cmds` on its
  configure_package.

- `@isomer//:swift_ui` there is a group (compiled_swift_ui:sdk): SwiftUI,
  PhotosUI, QuickLook (Isomer's `quickLookPreview`, frameworks/quick_look,
  which the host answers with the system's preview: a request layer, as the
  pickers are) and the Isomer module (`@isomer//:isomer` too). Apple's
  PhotosUI and QuickLook would bring Apple's SwiftUI with them, so the
  mapping renames those too. CoreTransferable and UniformTypeIdentifiers
  stay Apple's.
- `canImport(UIKit)` is true there, so a library's Apple branches compile
  against Isomer: that is the A/B. Isomer's SwiftUI imports UIKit on iOS, as
  Apple's does (`keyboardType(_:)` takes UIKit's type), and UIKit loads
  Apple's SwiftUICore, whose `AttributeScopes.SwiftUIAttributes` extends
  Foundation's type in every module that sees it. So in a compiled feature
  Isomer declares no scope of its own: `Text(AttributedString)` reads Apple's
  through `attributes.swiftUI` (SwiftUICore can't be imported by name) and
  matches its colours and fonts with the system's named ones
  (shared/swift_ui_core/AttributedText.swift; those symbols are
  SwiftUI.framework's, which the compiled SwiftUI links). Every other build
  declares Isomer's scope, named `AttributeScopes.SwiftUI::SwiftUIAttributes`
  (a module selector) inside the core, as the cores hosted beside Apple's
  SwiftUI see SwiftUICore's too. A module named SwiftUI on a Mac (the
  terminal host, the wasm libraries a `//...` build compiles for the host)
  must not load Apple's: it crashes the compiler.
- `Image(_ cgImage:…)` there takes Apple's CGImage (PNG-encoded once and
  handed to the host like a guest's picture).
- A/B: launch it with visor's fixture (`-visor.fixture snapshot
  -visor.fixture.screen <screen>`) on the harness's simulator and compare
  with tests/snapshots/ios/<screen>.png, which are red Visor's
  (tools/snapshots/pngdiff.py; the status bar overridden as the harness
  does). It found link colours, and `Image(systemName:)` drawn as text
  (a list row's separator started at the symbol); fixed, two screens are
  pixel-identical and the rest differ in an animation's phase.

## Apple's frameworks off Apple (0.31)

An app that imports only Swift, SwiftUI, Metal, Foundation, Observation and
Synchronization builds for every platform: Apple's frameworks on Apple
platforms, Isomer's modules of the same names elsewhere
(docs/isomer_031_plan.md). docs/parity/<Module>.md says what of each
interface is there, what is not, why, and whether it is planned
(tools/parity/parity.py; reasons in tools/parity/reasons/; regenerate
when a public interface changes, and keep "not yet classified" at 0).
tools/parity/stubs.py then writes SwiftUI's planned gaps as unavailable
stubs (shared/swift_ui_core/NotYet.swift, generated: the compiler says "Not
yet in Isomer: <group>"); implementing one means running it again (or
deleting the stub); tools/parity/stubs_skip.txt keeps one out.

- **Foundation** (//foundation, `@isomer//:foundation`): built from Isomer's
  fork of swift-foundation (AttilaTheFun/swift-foundation, branch `isomer`;
  the registry's 6.3.2.isomer.1 is its commit; develop against a
  checkout with `common --override_module=swift-foundation=<path>` in an
  untracked .bazelrc.user). FoundationEssentials, plus what corelibs has
  that apps reach for, written in Swift here: NSRange, NSRegularExpression
  (over Swift's Regex, UTF-16 ranges), NSLock/NSRecursiveLock/NSCondition,
  Thread (pthreads; one thread in wasm), FileHandle, NSNumber (Swift's
  numbers bridge to it as on Apple's platforms: `json["n"] as? Int` is an
  exact cast, through `_ObjectiveCBridgeable`, which Swift's runtime honours
  off Objective-C too), JSONSerialization, ISO8601DateFormatter,
  FileWrapper, `String(format:)`, Bundle, streams. UserDefaults has Apple's
  argument domain: `-key value` among the program's arguments, or, where a
  host starts no program with arguments (Android), in ISO_ARGUMENTS
  (`am start -e ISO_ARGUMENTS '-reviews.fixture YES'`: the generated
  activity sets each ISO_ extra in the environment). `--@isomer//foundation:internationalization`
  adds FoundationInternationalization over the Swift SDK's prebuilt ICU
  (lib_FoundationICU.a); `isomer_web_app(icu_locales = [...])` keeps only
  those languages' ICU data (34 MB → 6-7 MB). Linux and Windows still use
  the toolchain's corelibs Foundation; servers too.
  - Every library that imports Foundation must depend on
    `@isomer//:foundation` (SwiftPM packages through `configure_package(
    target_deps = ...)`), or it finds the Swift SDK's Foundation, which
    then links beside Isomer's (duplicate `Foundation` symbols).
    `tools/foundation/check_link.py [<bazel flags>] <targets>` names the
    leak; give it the flags the targets were built with (it refuses to pass
    on autolink files that are not on disk).
  - On Android the Swift SDK's FoundationNetworking and
    FoundationInternationalization stay importable beside Isomer's
    Foundation (`canImport` is true), so `#if canImport(FoundationNetworking)
    import FoundationNetworking` links the SDK's, corelibs Foundation with
    it. A library Isomer builds must not take that branch there (an app's
    protocol library skips it on Android and goes through its host for HTTP);
    since Isomer's Foundation has URLSession, the two would also make
    `URLSession` ambiguous. rules_swift_package_manager keeps the LAST
    configure_package per package and visits the root module first: a
    dependency's tag beats the root's (visor_isomer patched visor's
    MODULE.bazel for that, while AgentUI had SwiftTerm).
  - The `:foundation` aliases are `one_configuration` wrappers
    (foundation/defs.bzl): RSPM's per-package minimum-OS transitions would
    otherwise build Foundation twice (every Apple platform's option is
    cleared: a web site bundled into an iOS app builds under `ios`).
  - A module renamed away (SwiftUIExtensions before 0.31) can survive as a
    stale .swiftmodule in Bazel's output directory, beside the module that
    replaced it, and shadow it: import the new name and depend on its target.
  - **App files on the web** (wasm/libraries/swift_ui/runtime/file_system.js):
    the guest's WASI file system is one tree, "/" preopened as fd 3, laid
    out as an iOS container: HOME=/home/app, Documents, Library/Application
    Support (XDG_DATA_HOME), Library/Caches (XDG_CACHE_HOME), all told to
    the guest through environ_get (swift-foundation resolves them from
    HOME and XDG_* on WASI); /tmp in memory, /tmp/iso-import the picked
    files (read-only); nothing writable elsewhere (EACCES). Everything
    under HOME persists in the origin's IndexedDB (`isomer-files`, a record
    per file and directory keyed by [app key, path under HOME], a file's
    bytes in 64 KiB block records keyed [app key, path, number] beside it,
    so a write puts only the blocks it touched), read before the reactor
    starts, written within 300 ms of a change and when the page is hidden
    or left; a leaving page's IndexedDB write can be aborted with the page,
    so the blocks unwritten then also go to a localStorage journal
    (`isomer-files:<key>`, up to 1 MB) the next load lays over IndexedDB's
    (rewritten whenever a write completes, so it is never older than
    IndexedDB). Files kept whole before blocks still read, and move into
    blocks at their next write. tests/web_files:blocks_test checks it in
    Node with an IndexedDB of its own. The
    app key is `boot({ bundleIdentifier })` (also the guest's
    `Bundle.main.bundleIdentifier`), else the reactor URL's path: apps on
    one dev server's :8080 share a home unless their pages name
    themselves. No IndexedDB: memory, one warning. `URL.documentsDirectory`
    and its siblings are foundation/Paths.swift's (swift-foundation declares
    them for Apple's framework only).
  - **App files on Android** (android/libraries/swift_ui/kotlin/…/
    AppDirectories.kt, from `IsomerRuntime.prepare(context)`, which every
    surface and the generated MainActivity call before any Swift runs): HOME
    and CFFIXED_USER_HOME (swift-foundation reads it first there) are the
    app's filesDir, with Documents and Library/Application Support
    (XDG_DATA_HOME); Caches are Android's cacheDir/Caches (XDG_CACHE_HOME,
    linked from Library/Caches: not backed up, cleared by the system, as
    iOS's), TMPDIR the cacheDir, ISOMER_BUNDLE_IDENTIFIER the package.
  - **App files under WasmKit** (shared/wasm_host/WasmKitRuntime.swift's
    `makeWASI`): the guest's /tmp is the host's temporary directory's
    `isomer-guest`; a host that sets `WasmKitRuntime.homeDirectory` gives
    the guest that directory as /home/app, with Documents, Library/
    Application Support and Library/Caches made in it and
    HOME/XDG_DATA_HOME/XDG_CACHE_HOME naming them; `bundleIdentifier`
    becomes ISOMER_BUNDLE_IDENTIFIER. Apple's WasmView passes the app's own
    container (`homeDirectory = NSHomeDirectory()`), so a guest's files are
    the app's; Android's Kotlin `WasmKitRuntime` takes a `homeDirectory` and
    `bundleIdentifier` too. Hosts that pass none (the tests, the
    Linux/Windows hosts, Android's WasmView for now) give the guest no home:
    its directories are not writable, and swift-foundation (fork commit
    e8b0c06) answers `createDirectory(withIntermediateDirectories:)` there
    with an error rather than recursing past "/".
  - **SQLite** (swift_sql, a Swift package: `@swiftpkg_swift_sql//:SwiftSQL`
    over `//:CSwiftSQL` there): the system SQLite on Apple platforms, SQLite's
    amalgamation with FTS5 elsewhere (options in its Sources/CSwiftSQL/cswiftsql.c). On WASI it uses the "unix-none" VFS (no
    locks: SQLite's WASI default, "unix-dotfile", would leave a lock
    directory in the web's IndexedDB if a page closed mid-transaction) and
    no WAL or mmap, and is thread-safe in a threaded reactor. A database in
    Application Support persists on every host: the web's files above, the
    app container under WasmKit, the files directory on Android.
    The examples' //tests/sqlite_wasi:sqlite_file_test runs it under
    WasmKit (//tools/wasm/wasi_run), and :sqlite_file_threads_test the
    threaded build with WASI Threads (it compiles SQLite with THREADSAFE=1,
    the single-threaded one with 0);
    examples/web/files_probe_web_application checks it in Chrome across
    reloads (tools/testing/run_files_check.js, whose window is tall enough
    for the probe's whole report: its list draws only the rows on screen).
  - **PlatformServices** (shared/platform_services) keeps the keychain,
    OAuth, timers, analytics, configuration, the image picker and device
    motion. Its network, file and preferences services are gone since
    0.31: apps use URLSession, FileManager and UserDefaults, and the hosts'
    storage plumbing (WebHost's storageGet/storageSet, AndroidHost's
    fileRead/fileWrite, Windows' iso_read_file) went with them.
  - **Networking** (phase 11): `URLRequest`, `URLResponse`,
    `HTTPURLResponse`, `URLError` (and `Error.localizedDescription`),
    `URLSession` with `URLSessionConfiguration`, data, upload, download and
    WebSocket tasks, completion-handler and async forms, as Apple's
    interface has them, without delegates (foundation/URLSession.swift says
    where each kind of URL goes). file: and data: URLs are read in Swift;
    http(s) and ws(s) go through transports a host installs in
    **IsomerFoundation** (//foundation/isomer_foundation,
    `@isomer//:isomer_foundation`): `IsomerNetwork.http` (an
    `HTTPTransport`: one exchange, whole bodies, `NetworkTransportError`
    for no response) and `IsomerNetwork.webSocket` (a
    `WebSocketTransport` whose connections send text or data and receive
    messages or `.closed`). With none installed, tasks fail with
    `URLError.notConnectedToInternet`. IsomerFoundation also has
    `IsomerUserDefaults.store`, which the SwiftUI runtime fills from its
    host (Runtime.swift). Foundation reads it all through `internal import`:
    nothing of it reaches an app through `import Foundation`, by the
    rule that the Apple-named modules expose Apple's API only. A host
    implements the swift_ffi interfaces of IsomerNetworkHost
    (shared/isomer_network_host: `HTTPHost`, `WebSocketHost`; a failure
    throws a message led by a `NetworkTransportError.Reason`, "timedOut: …")
    and injects them under `isomerHTTP`/`isomerWebSocket`, which the
    runtime installs at start. The web's are runtime/network.js (fetch, an
    idle timeout restarted by each part of the body; WebSocket, no headers,
    close codes 1000 and 3000-4999 only), injected by boot.js and
    hot_host.js beneath a page's own entries; a page that must reach an
    API through its own server (no CORS headers: a third party's cloud API)
    gives boot()/mountIsomer()/`<Isomer>`/runHotBundle a `fetch` (and a
    `WebSocket` constructor) to use instead of the browser's, or injects
    its own `isomerHTTP`. Apple's WasmView and the Linux and Windows wasm
    hosts inject URLSession and URLSessionWebSocketTask
    (//shared/isomer_network_host/urlsession, over the generated
    //shared/isomer_network_host:wasm_host; FoundationNetworking on Linux
    and Windows) beneath their dependencies at each load; on Apple an
    http: server needs the host app's ATS to allow it. Android's runtime installs its own (`IsomerRuntime.
    prepare` → `installIsomerNetworkHosts`): HTTP over HttpURLConnection
    off the runtime's thread (IsomerHTTP.kt: redirects followed across
    http→https too, error bodies, gzip undone) and an RFC 6455 client of its
    own (IsomerWebSockets.kt: subprotocols, handshake fields, fragments,
    pings, closes); its WasmView injects the same into a reactor
    (WasmNetworkHosts.kt). isomer_android_app's manifest asks for INTERNET
    (`uses_cleartext_traffic` for plain http). The probes:
    `bazel run //android/network_probe_android_application:network_check
    -- --serial emulator-5554` (and `:network_check_wasm`) in the examples,
    two launches each (files and `@AppStorage` kept between them). //foundation/tests:
    foundation_test runs URLSession over fake transports under WasmKit;
    //tests/web_network:network_test the web's hosts in the hermetic Node.
- **CoreGraphics** (//core_graphics): geometry and CGFloat (a Double on
  every architecture), CGAffineTransform, CGColor/CGColorSpace, CGPath, line
  caps and joins, blend modes. Foundation re-exports it, as Apple's does.
  On Linux and Windows, whose Foundation is still the toolchain's
  (swift-corelibs-foundation, which declares CGFloat, CGPoint, CGSize and
  CGRect with their initializers and most members), it is built with
  `ISOMER_CORELIBS_FOUNDATION` as the rest over corelibs': a declaration
  added to one of those four types must go under `#if
  !ISOMER_CORELIBS_FOUNDATION` when corelibs has it, or `tools/linux/build.sh`
  fails on an ambiguous use.
- **Metal** (//metal/metal, module `Metal`, incompatible with Apple
  platforms): the classic API (no Metal 4, ray tracing, ML, IO, residency).
  `makeLibrary(source:)` parses the Metal Shading Language and translates
  each entry point to WGSL in Swift (metal/isomer_metal/translator: one WGSL
  module per entry point; group 0 a vertex or kernel function's resources,
  group 1 a fragment function's or a kernel's grid size; buffer(n) at
  binding n, texture(n) at 32+n, sampler(n) at 64+n, constexpr samplers at
  96+i). A device records what it is asked into one binary command stream
  per command buffer (metal/isomer_metal/backend/MetalCommands.swift, Metal's
  raw values) for a backend; IsomerMetalWeb's sends it over swift_ffi to the
  page's executor (metal/runtime/isomer_metal_webgpu.js, which makes
  pipeline variants for Metal's dynamic state, bind groups per draw, and
  reads back what the CPU must see).
  - `waitUntilCompleted()` can't block in a browser; completed handlers run
    after readback. A non-private buffer's bytes go to the GPU with every
    command buffer once `contents()` was asked for; GPU writes to it come
    back. Textures come back only after a blit's `synchronize(resource:)`.
    Shader buffer offsets must be multiples of 256 (WebGPU).
  - `MetalView` (Isomer module): an MTKView on Apple; on the web a "metal"
    host view, its own canvas under the React renderer (a surface of the
    page's one executor, a frame per animation frame through
    `isoMetalViewFrame`), composited into the frame under the GPU renderer
    (`SwiftGPURenderer.metalViewFrame`). examples/{shared,web,apple}/
    metal_triangle_* is the example.
  - Tests: `//metal/isomer_metal/tests:translator_test` (under WasmKit);
    `tools/metal/validate_wgsl.js` compiles the translator's output with
    Chrome's WebGPU; metal/tests/web + `tools/metal/run_metal_check.js` run
    13 end-to-end checks (compute readback, render readback, textures,
    SwiftGPU's shaders, a canvas frame) in headless Chrome, no server (an
    empty file:// page is a secure context). Chrome's test profile
    (/tmp/iso-cdp-profile) can keep a service worker from another site
    served on the same port: delete it when a page looks like the wrong app.
- **The Apple-named modules are strict subsets of Apple's** (2026-10-12:
  "the swift interface should be a strict subset of the real
  one, and internally the implementation can depend on any of the Isomer*
  libraries"; then "SwiftUI, CoreGraphics, Foundation and Metal should not
  have any public-facing Isomer-specific APIs but they can depend on
  IsomerCoreGraphics, IsomerFoundation, IsomerMetal, IsomerSwiftUI and
  IsomerFFI (all re-exported throught the Isomer umbrella module, though
  that's intended for external consumption)"). Every public declaration of
  SwiftUI, Foundation, CoreGraphics, Metal (and CoreTransferable,
  UniformTypeIdentifiers, PhotosUI) matches one of Apple's (iOS's or
  macOS's) by name, kind and instance-or-static: Apple's full signatures
  (their defaulted parameters too), style protocols with a type per style,
  protocols that require only what Apple's do (Isomer's built-ins adopt
  internal ones: `PaintStyle`, `PrimitiveShape`, `NamedStyle`,
  `PrimitiveGesture`, `_PrimitiveScene`), a primitive's `body` kept out of
  the interface. `@_spi` counts as public; so does a public underscored name
  Apple's interfaces lack; so does a conformance Apple's same type lacks
  (`Hashable` on Metal's C structs, `View` on toolbar items; the marker
  protocols such as Sendable aside, whose graphs differ by tool), and so
  do swift-foundation's own declarations (the fork makes them internal).
  `python3 tools/parity/parity.py --check` fails
  when an Apple-named module has anything of Isomer's own; `--check
  --strict` also when a declaration's types are not one of Apple's
  signatures (the subset is of the .swiftinterface: `init<S:
  StringProtocol>(_ title: S)`, not `init(_ title: String)`; generic
  parameters compared by their constraints, a `some P` parameter being
  one). Run it after any change to a public interface. Missing API is
  fine; extra or differently typed API is not.
  - Isomer's plumbing between its own modules is `package`: every isomer
    Swift target (and the two examples that compile the core) is built
    with `package_name = "isomer"`, which no application has. A new isomer
    target that uses the runtime's plumbing needs it; code an app compiles
    must not (HotBridge.swift is a library, `hot_bridge`, for that reason).
  - What a host or an app uses of Isomer's own is public in an Isomer*
    module beneath the Apple-named one, which reads it: IsomerSwiftUI
    (`HostBridge` with `HostColor` and `ImageStatus`; `RuntimeConnection`
    at `IsomerRuntime.connection`; the IsoFlat tree types), IsomerFoundation
    (the URL transports, UserDefaults' store), IsomerMetal. The Isomer
    umbrella re-exports them with IsomerFFI and IsomerNetworkHost.
  - The cores built on Apple platforms under other module names
    (IsomerCore, IsomerGPUTreeView, the Metal examples') alias `SwiftUI` to
    themselves (`-module-alias SwiftUI=<name>`): the shared source spells
    `SwiftUI.Label<Text, Image>` where a generic parameter shadows the type,
    as Apple's interface does.
  - What Apple's SwiftUI brings along from other frameworks comes from
    //frameworks: CoreTransferable (re-exported, as Apple's is);
    UniformTypeIdentifiers and PhotosUI are imported by name, as on Apple
    platforms. **No Combine, UIKit or Dispatch** (2026-10-12: "I
    really don't want any of the Combine or UIKit apis if we can avoid
    them for the same reason I don't want any Objective-C stuff: these
    exist primarily for backwards compatibility and the future is Swift,
    SwiftUI and SwiftConcurrency"). Models are `@Observable` (Observation)
    held in `@State`, passed down with `.environment(_:)` and read with
    `@Environment(Model.self)` or `@Bindable`; no `ObservableObject`,
    `@StateObject`, `@ObservedObject`, `@EnvironmentObject` or `onReceive`.
    Delays and the main actor are Swift Concurrency (`Task`,
    `Task.sleep(for:)`, `@MainActor`), not `DispatchQueue.main`. The
    pasteboard is the Isomer module's `Clipboard.string` (UIPasteboard/
    NSPasteboard on Apple platforms, the host's elsewhere); `Color(uiColor:)`
    and `keyboardType(_:)` exist only where UIKit does (`#if
    canImport(UIKit)` in an app; off Apple nothing sets a field's keyboard
    type now, though the nodes and hosts still carry one). Dispatch
    itself: none on wasm; on
    Android the toolchain's libdispatch, whose main queue the host's
    Looper drains (`_dispatch_get_main_queue_handle_4CF`, an eventfd,
    NativeBridge.watchDispatchMainQueue), so a library's
    `DispatchQueue.main.async` still runs there.
  - `@isomer//:swift_ui` is, on wasm and Android, a group
    (`//<platform>/libraries/swift_ui:sdk`): SwiftUI, PhotosUI (built per
    platform over that SwiftUI), UniformTypeIdentifiers and the Isomer
    module, what an app may import there.
  - On a Mac (the core's host tests) Observation cannot set aside the
    tracking scope a view's body runs in, so an `@Observable`'s change
    marks the views above the reader too (coarser frames there, the mock
    tests say so); wasm and Android track per view.
- **The Isomer module** holds what Isomer adds (WebView, MetalView, Map,
  PlatformViewRepresentable and its per-platform refinements, BridgedView,
  `Color.dynamic(light:dark:)`, `swipeGesture`, `cameraCapture`,
  `VideoPlayer(url:)`, Platform, platform modifiers, JSON, the platform
  bridge) and is the umbrella over the Isomer* modules (shared/isomer/
  Exports.swift). SwiftUIExtensions and IsomerBridge are one-line
  re-exports of it. On the reimplementation those are
  shared/swift_ui_extensions, over SwiftUI's `package` plumbing:
  `PlatformViewRepresentable` is the Isomer module's own protocol, whose
  body is SwiftUI's `HostViewPrimitive`. The runtime's plumbing (Runtime,
  the renderers, RenderNode, the web/Android host interfaces) is
  `package`; an `@ExportedInterface` protocol declared `package` (or
  `@_spi(X)`) gets its peers declared so too.

## Hard-won gotchas

- **wasm stack size**: the wasm app needs a 16 MiB stack linkopt or it goes
  out-of-bounds in Swift's generic-metadata code. The old `-c opt` crash is
  fixed upstream (rules_swift `--table-base=4096`).
- **JNI entry points in Swift**: `@_cdecl` JNI symbols compiled into a static
  archive get stripped by `--exclude-libs,ALL`. swift_ffi avoids this by
  compiling the generated JNI glue directly as the
  `swift_binary(linkshared)`'s own srcs (the old `jni_exports.lds` version
  script is gone).
- **Kotlin `internal` visibility mangles JVM names** (`fooRaw$module`), which
  silently breaks `Java_*` JNI symbol matching at runtime
  (UnsatisfiedLinkError). Externals bound to JNI must be effectively public.
- **Emulator cold boot**: `apk_install_run` waits for `sys.boot_completed`
  AND `cmd package path android`, but the very first install can still hit
  "Broken pipe" when the system server restarts mid-boot. Retrying the
  install (rerun the target) succeeds.
- **A C function from Swift on wasm: `@_extern(c, "name")`, not
  `@_silgen_name`.** The latter calls it with Swift's convention; wasm-ld
  turns the mismatched call into a stub that traps ("unreachable" at the
  guest's first call). `@_extern` needs the `Extern` feature
  (`#if hasFeature(Extern)`; the wasm and Android SwiftUI libraries have it).
- **Reactors ship dead-stripped** (since 2026-10-11). A swift_ffi reactor
  linked in its development shape (`--export-all --no-gc-sections`) keeps
  every function in the program: Visor's was 83 MB. `isomer_web_app` and
  visor_isomer link twice: once exporting everything, to read the entries
  hosts call (`swift_ffi_*`, `iso_hot_*`, `_initialize`, what the engines
  read: `wasm_export_list`, `swift_wasm_reactor(exports = "host")`), then the
  shipped module exporting just those, without function names in `-c opt`.
  An app with the full Foundation also gets ICU's data less `ICU_DROP`
  (legacy converters, CJK/Southeast Asian word dictionaries:
  `icu_data_library`). A host that looks up a new kind of export by name
  must add it to the entries, or the shipped module drops it.
- **Don't read outputs via `find -L bazel-bin`** — you'll hit stale
  other-config outputs. Use `bazel cquery --output=files <target>`.
- Android license acceptance + `--android_platforms=@rules_android//:arm64-v8a`
  + hermetic remotejdk_17 flags live in `.bazelrc`.

## Working conventions

- Hermeticity is the point: no ANDROID_HOME, no host JDK, no Gradle, no npm.
  Every tool comes from a pinned repository. Keep it that way.
- Apple builds are the sole exception (local Xcode, as all Bazel Apple builds).
- MODULE.bazel and the `.bzl` files carry deliberate explanatory comments —
  maintain that density when editing.

## swift_ffi integration (on main)

The wasm + Android host bridges ride swift_ffi's generated bindings:

- `wasm/libraries/swift_ui/WebBridge.swift` / `android/libraries/swift_ui/
  AndroidBridge.swift` declare the surfaces (`@ExportedInterface
  WebHost`/`AndroidHost` implemented by boot.js / NativeBridge.kt;
  `@ExportedFunction` exports; `@ExportedStruct` TextMetrics/ImageInfoValue
  replace packed-jlong returns and buffer plumbing).
  `jni_exports.lds` and `wasi_shim.js` are gone.
- The app `@main` runs via an `@_extern(c, ...)` trampoline: symbol `main` on
  Android, `__main_argc_argv` on wasm32; the app swift_library must be
  `alwayslink` (the only reference comes from an archive linked after it).
- `.bazelrc` carries `--strategy=SwiftCompile=local` (swift_ffi macro plugin
  sandbox issue).
- On web the generated TS bindings compile via swift_ffi's `ts_swift_library`
  (target must be named `app_bridge`; its .js outputs land at the site root
  next to `swift_ffi_runtime.js`); boot.js and the rest of the runtime are
  served as raw ES modules, NOT bundled — aspect esbuild's sandbox plugin
  rejects cross-package staged entry points, don't try.
- On Android the Kotlin runtime (`dev.isomer.runtime`) compiles against
  the generated `SwiftUIBridge`, so `isomer_android_library` fixes the
  bindings' `java_package` to that package. Any kt library holding
  `setContent {}` composables MUST carry the `compose_compiler_plugin` or it
  throws NoSuchMethodError (Function0 vs Function2) at runtime.

## Each platform's look (2026-10-11)

The targets: the Mac and iOS apps are the reference. The web one column
wide is iOS (26), two columns wide (`isDesktop()`, ≥ 700px) the Mac;
Android leans into Material 3; the GPU renderer keeps one look everywhere.
What carries that, beyond the renderers' own chrome:

- **Hosts translate, the guest stays SwiftUI.** iOS 26 moves a split
  column's `.bottomBar` search field under the navigation bar at regular
  width (`_bottomBarAtTop`) and keeps its buttons at the bottom (an iPad's);
  the desktop web lifts those buttons into the column's top bar
  (`liftedBarButtons`), Android draws the field as a Material search bar
  under the title and the button as a floating action button
  (`MaterialBottomBar`). No idiom flag in the guest.
- **Named grounds.** `groupedBackground`, `secondaryBackground`, the
  elevated pair and `barBackground` travel by name (`fillName`/`bgName`):
  the desktop web paints the Mac's dark greys, Android Material 3 roles
  (`MaterialGrounds`), a floating iOS sheet its glass.
- **Android's scheme** is Material 3 tonal, seeded from SwiftUI's accent
  (the system blue), not dynamic colour: the app's own tinted views are that
  blue, and a wallpaper primary beside them would clash.
- **List rows' traits** (`listRowInsets`, `listRowBackground` with a view)
  are found from the row's content however deep they were applied, as
  SwiftUI's rise (`_ListRowTrait`); a row with its own background gets no
  selection or cell fill from the host (param `rowOwnBg`). A row's
  `.tag` is found through an app's `.modifier(_:)` too.
- **Size classes rebuild.** `Runtime.resize` across 700pt builds the tree
  again (`horizontalSizeClass` comes from the width); hosts that start the
  guest before they know their size depended on it.
- **Parity reports**: docs/parity/ says, per module (SwiftUI, Foundation,
  CoreGraphics, Metal, Observation, Synchronization), what of
  Apple's interface Isomer implements and why the rest is missing
  (tools/parity/parity.py, reasons in tools/parity/reasons/). Regenerate them
  when a module's public API changes. docs/parity/missing/<Module>.md lists
  every missing declaration with Apple's signature, by area and type, with
  the conformances, Sendable and overloads Isomer's types lack: what to pick
  the next work from. docs/parity/superset.md is the other direction: what
  `--check` keeps out (per module, all 0), Sendable where Apple's type is
  not, the Android and CLI builds compared too (parity.py builds their
  graphs), and what the Isomer* modules add. ImageIO (shared/image_io) is
  marked `known_gap` there: reported, not failed, until it is a subset.
- The SwiftUI API audit is `docs/swiftui_api_audit.md` (scripts in
  `tools/swiftui_audit/`); `tests/renderer/APITests.swift` checks what it
  led to.

## Headless verification

**A person's own phone is not a test device.** Install a build there when
asked, read the version back, and stop: no launching, tapping or
screenshots unless they explicitly ask. Everything below is simulator,
emulator or desktop browser.

- **iOS simulator**: `example_full_native_ios_sim_application` (build with
  `--ios_multi_cpus=sim_arm64`) has no provisioning-profile requirement —
  the main iOS target needs the Xcode-managed profile this machine lacks.
  Launch hooks (read via `getenv`, NOT ProcessInfo):
  `SIMCTL_CHILD_ISO_OPEN_APP=map` opens a catalog screen directly;
  `SIMCTL_CHILD_ISO_MAP_CAMERA="lat,lon,zoom,bearing,tilt"` sets the Map
  Explorer camera.

- **Web**: two ways, both real browsers.
  - `tools/testing/cdp.py` — stdlib-only headless-Chrome CDP driver (navigate /
    trusted clicks / type / eval / screenshot). Use it instead of synthetic-event
    or `--virtual-time-budget` harnesses, which are unreliable against React 18.
    The React renderer exposes committed smoke hooks: `data-tap` ids on tappables,
    `window.__isoSendEvent`, `window.__isoLastTree`. Serve the site first
    (`bazel run //examples/web/<app> -- --no-open`, defaults to :8080), then
    point cdp.py at `http://localhost:8080/`.
  - **App files** (FileManager on the web, kept in IndexedDB):
    `bazel test //tests/web_files:file_system_test` drives the WASI layer in
    the hermetic Node; `node tools/testing/run_files_check.js <site dir>`
    runs examples/web/files_probe_web_application across reloads in
    headless Chrome (its own server and profile, both stopped at the end;
    see the probe's BUILD.bazel).
  - **Networking** (URLSession over fetch and WebSocket):
    `bazel test //tests/web_network:network_test` drives runtime/network.js
    in the hermetic Node; `node tools/testing/run_network_check.js <site
    dir>` serves examples/web/network_probe_web_application from
    tools/testing/network_server.js (HTTP and WebSocket endpoints, Node's
    standard library only) and runs the probe's URLSession checks in
    headless Chrome, then one offline.
  - **Electron** — the same wasm build in Electron's Chromium, screenshotted
    headlessly via a `ISO_SCREENSHOT` hook in `examples/electron/main.js`:
    `ISO_SCREENSHOT=/abs/out.png [ISO_SCREENSHOT_DELAY=7000] [ISO_RENDERER=react]
    bazel run //examples/electron/<app>` loads the site in a hidden window,
    waits for the wasm to render, writes the PNG, and quits. Good for a true
    end-to-end visual check of the packaged site (main.js serves it from the
    `isomer://app/` scheme, a stable origin, so IndexedDB and localStorage
    last across launches, exactly like the shipped desktop app).
  - **iOS Safari** (safe areas, the soft keyboard, Home Screen web apps):
    `examples/tests/safari_probe` is an XCUITest that drives Safari in the
    booted simulator from a command file (open/tap/type/shot; see
    SafariDriver.swift). Serve the site with no-store caching — a Home
    Screen web app holds on to old modules otherwise. Stop it with `quit`:
    while it runs it holds the examples workspace's Bazel server.
- **Android**: on-device verification IS available in this environment —
  there is a **hermetic emulator** (MODULE.bazel's `rules_android_sdk`
  extension: `android_emulator` + `android_system_image`, AOSP
  `android-34/default`, arm64). Never claim Android is unverifiable. Boot it
  standalone with `bazel run //tools/android/emulator` (`-- -no-window`
  headless); or just `bazel run` an app target — `apk_install_run`
  auto-boots it when no device is connected. Any Swift-compiled-to-wasm
  feature (the Compose `WasmView`, //android/libraries/wasm_view) is
  runnable the same way once wrapped in an `android_binary` + `apk_install_run`.
  `bazel run` on an app target boots the hermetic emulator,
  installs, launches, then **tails logcat (it doesn't exit — that's by
  design)**. If you boot your own `-no-window` emulator for screenshots,
  kill it afterward: a headless instance holding emulator-5554 makes the
  user's windowed `bazel run` appear to "not open". ATD emulator screencap
  doesn't composite overlay Views (EditText/Spinner look empty) — verify
  those via state changes or on web. adb screencaps come back ~2x
  downscaled: compute `input tap` coords from device px (1080×1920).
