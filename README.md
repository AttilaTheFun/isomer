# Isomer

> [!WARNING]
> **Very experimental, in early development.** Isomer is a work in progress:
> its APIs and behaviour will change without notice, much of SwiftUI is not
> there yet, and nothing here is supported. Use it at your own risk.

Isomer (Isomer Swift) is Swift across every platform an application runs
on: one SwiftUI source for iOS, macOS, the web (WebAssembly), Android, Linux
and Windows, with the data on the device and the wire in Swift too.

```
SwiftUI  →  SQLite  →  gRPC Swift 2  →  a Swift server
one source, on iOS, macOS, the web (WebAssembly), Android, Linux and Windows
```

It is a set of pieces, and none of them requires the others:

| Piece | What it is | Where |
| --- | --- | --- |
| SwiftUI everywhere | One SwiftUI source: Apple's SwiftUI on Apple platforms, Isomer's implementation on the web (React or WebGPU), Android (Jetpack Compose), Linux (OpenGL) and Windows (Direct3D) | this module (`isomer`) |
| SQLite everywhere | SQLite's C API and a thin, strict-concurrency-safe Swift layer over it, the same SQLite on every platform (WebAssembly included) | [swift_sql](https://github.com/AttilaTheFun/swift_sql) |
| Swift on every platform | Cross-compilation to WebAssembly, Android and Windows in Bazel | [rules_swift](https://github.com/bazelbuild/rules_swift) (upstream) |
| Bridges to each platform's own language | Generated Kotlin, TypeScript and C bindings | [`swift_ffi/`](swift_ffi/) |
| Apple's frameworks off Apple | `Foundation`, `CoreGraphics` and `Metal` with Apple's interfaces, written in Swift, for the web and Android (Metal: the web, on WebGPU, with Metal Shading Language translated to WGSL) | [`foundation/`](foundation/), [`core_graphics/`](core_graphics/), [`metal/`](metal/), [docs/parity](docs/parity/) |
| Graphics and maps | One GPU abstraction (Metal, WebGPU, OpenGL, Direct3D); an OpenStreetMap renderer on it | [`swift_gpu/`](swift_gpu/), [`swift_map/`](swift_map/) |

Why Swift: it rules out whole kinds of bugs when the program is compiled
(reference counting, optionals, checked concurrency) and it reads plainly.
Both matter more when much of the code is written by agents and reviewed by
people.

This repository was `universal_ui` until September 2026.

## One source, six targets

One SwiftUI application source file. Six runnable targets. One `bazel run`
each — no external setup: the browser opens itself, the simulators and
emulator boot themselves. Or launch everything at once:

```sh
bazel run //examples/shared/example_application:run_all
```

opens five windows side by side: the macOS app, the iOS simulator, the
Android emulator, the Electron shell, and a basic web browser (URL bar,
back/forward/reload — the same hermetic Electron binary acting as a plain
Chromium) loading the web build over HTTP.

## Platforms

iOS, macOS, Android, Web, Electron, Windows, and Linux — the
[Full SwiftUI applications](#full-swiftui-applications) table below lists
every platform/renderer pair with its run target. Each platform directory has
its own README with the complete target/config table:
[android](android/README.md) · [apple](apple/README.md) ·
[web](web/README.md) · [linux](linux/README.md) ·
[windows](windows/README.md).

On Apple the example links against the real SwiftUI, so everything in the
subset behaves exactly as Apple ships it. Android, Web, Windows, and Linux run
the shared SwiftUI **reimplementation** (`shared/swift_ui_core`) and aim to match
that behavior as closely as each renderer can — native components under the
component-system renderers (Compose, React), everything drawn through
SwiftGPU under the self-drawing `SwiftGPURenderer`. See
[docs/renderer_layers.md](docs/renderer_layers.md).

Windows has two ways to run: the **native** target (built on a Windows
host, drawn with Direct2D — see [Native Windows target](#native-windows-target)),
or the **wasm** build packaged from any host: `bazel build
//examples/electron/example_full_react_electron_application:example_windows_package` zips it
with the Windows x64 Electron runtime — copy the zip to a 64-bit Windows machine,
unzip, and run `Isomer.exe`.


### Modules: `SwiftUI`, `SwiftUIExtensions`, `IsomerBridge`

The reimplementation's `SwiftUI` module carries **only Apple's SwiftUI API
surface**, so a SwiftPM package written for Apple compiles unchanged on
wasm, Android, Linux and Windows. What Isomer adds beyond it lives in
`SwiftUIExtensions` (`Platform.current`, the platform-command modifiers,
`WebView`, the JSON helpers) — import it explicitly; `IsomerBridge`
re-exports it, so app code that already imports the bridge needs no change.
`@isomer//:swift_ui` is one label that resolves to the platform's
`SwiftUI` library (nothing on Apple, where the system SwiftUI is implicit)
for a package's generated target (rules_swift_package_manager `target_deps`).
Gotcha: rules_swift_package_manager wraps each package target in a
minimum-OS transition keyed on `--apple_platform_type`, which defaults to
`macos` even for wasm/Android builds, so a package declaring `platforms:`
forks a second configuration (the reimplementation and swift_ffi built
twice → "redefinition of module 'SwiftABI'"). Pin the flags to the
package's values in `.bazelrc` (`build --minimum_os_version=14.0` next to
`--macos_minimum_os=14.0`) and the transition is a no-op.

**The Playground** (write SwiftUI on the device, build it there, run it on
Isomer: an iOS app, a web site and an Android app) lives in `playground/`, a
Bazel module of its own that consumes isomer from this checkout
(`local_path_override`) as `examples/` does (`cd playground && bazel build
//...`; its README and AGENTS.md say more).
It was `examples/*/playground_*` here until 0.15, then a repository of its
own until 0.35.

**Foundation and CoreGraphics.** On wasm and Android, `import Foundation`
is Isomer's: swift-foundation's FoundationEssentials built from Isomer's fork
([AttilaTheFun/swift-foundation](https://github.com/AttilaTheFun/swift-foundation),
branch `isomer`), with no swift-corelibs-foundation layer (no CoreFoundation;
of corelibs' `NS` classes only what apps reach for, written in Swift:
`NSRange`, `NSRegularExpression`, the locks, `Thread`, `FileHandle`,
`NSNumber`) and no ICU unless an app asks for
`--@isomer//foundation:internationalization` (FoundationInternationalization
over the Swift SDK's ICU; `isomer_web_app(icu_locales = ["en"])` trims its
data to the languages named). `import CoreGraphics` is
Isomer's too (`//core_graphics`): geometry, `CGFloat` (a `Double` on every
architecture), `CGAffineTransform`, `CGColor`, `CGPath`. `SwiftUI` re-exports
both, as Apple's does. Any library built for those platforms that imports
Foundation depends on `@isomer//:foundation` (a SwiftPM package through
rules_swift_package_manager's `target_deps`); `tools/foundation/check_link.py`
finds an app that links the Swift SDK's Foundation instead. Linux and
Windows still use the toolchain's Foundation. docs/isomer_031_plan.md has the
plan and docs/parity/ what each module covers.

**Metal.** On the web, `import Metal` is Isomer's (`//metal/metal`): the
classic Metal API, with libraries made from Metal Shading Language source,
which IsomerMetal translates to WGSL in Swift, and every command buffer run
on the browser's WebGPU by `metal/runtime/isomer_metal_webgpu.js`. The
self-drawing renderer and SwiftMap draw through it there, from the same
SwiftGPU source that runs on Apple's Metal. `MetalView` (the Isomer module)
is a view to draw into with Metal: an MTKView on Apple platforms, a canvas
on the web (`examples/web/metal_triangle_web_application` and its iOS twin
draw the same triangle from one source).

## Running the example app

The examples live in [`examples/`](examples/), a STANDALONE Bazel module that
consumes isomer the way any application does (`bazel_dep` + an override
— see [Consuming isomer](#consuming-isomer)). The one application
source
([`examples/shared/example_application/ExampleApp.swift`](examples/shared/example_application/ExampleApp.swift))
ships as a `bazel run` target on every platform. Each command builds what it
needs and brings up the runtime end-to-end — no device wrangling, no
`ANDROID_HOME`, no manual server: the browser opens itself, and the
simulators and emulator boot themselves.

```sh
cd examples
# All targets at once (four windows side by side):
bazel run //shared/example_application:run_all
```

### Full SwiftUI applications

A **full** application is entirely SwiftUI: one `@main App`, with the
platform entry points generated around it. It runs under a **component-system
renderer** (native components: real SwiftUI on Apple, Jetpack Compose on
Android, React on web) or the self-drawing **`SwiftGPURenderer`** (everything
drawn at the GPU layer — identical across backends). See
[docs/renderer_layers.md](docs/renderer_layers.md) and
[docs/adoption_levels.md](docs/adoption_levels.md).

Every app follows one naming scheme —
`//<platform>/applications/example_{full|partial}_{renderer}_{platform}_application`.
Web and Electron are separate platforms (they share the wasm build under
`wasm/libraries`).
| Platform | Renderer | Target |
| --- | --- | --- |
| macos | native | `//examples/apple/example_full_compiled_macos_application` |
| ios | native | `//examples/apple/example_full_compiled_ios_application` |
| android | compiled | `//examples/android/example_full_compiled_android_application` |
| android | wasm | `//examples/android/example_full_wasm_android_application` \*\* |
| web | react | `//examples/web/example_full_react_web_application` |
| web | webgpu | `//examples/web/example_full_webgpu_web_application` |
| electron | react | `//examples/electron/example_full_react_electron_application` |
| electron | webgpu | `//examples/electron/example_full_webgpu_electron_application` |
| windows | directx | `//examples/windows/example_full_directx_compiled_windows_application` \* |
| linux | opengl | `//examples/linux/example_full_opengl_compiled_linux_application` \* |

\* Built natively **on** that OS with its own Swift toolchain — no
cross-compile from macOS exists for these targets (see
[Native Windows target](#native-windows-target) /
[Native Linux target](#native-linux-target)).

\*\* On Android the axis is **how the SwiftUI is delivered**, not which
renderer draws it (Compose is the only supported Android renderer): `compiled`
links the SwiftUI in as native `-c opt` Swift; `wasm` ships it as a wasm bundle
run in-process — trading some runtime performance for runtime-updatable code
and smaller app size. The two are mutually exclusive per app (mixing compiled +
wasm Swift is only free on Apple, where the Swift runtime ships in the OS). Both
the **partial** (`example_partial_wasm_android_application`) and **full**
(`example_full_wasm_android_application`) cells ship today: the full cell runs
the entire shared `@main App` as one wasm bundle under the WAMR interpreter,
drawn by the same Swift-free Compose interpreter — the host APK's only native
library is the ~344 KB WAMR C engine (no compiled Swift .so).

### Hot reload

The demo app is compiled to a **wasm reactor** and run under an embedded
[WasmKit](https://github.com/swiftwasm/WasmKit) interpreter; the host renders
the tree it emits with real SwiftUI and swaps in a freshly compiled wasm on
every edit — the host process is never rebuilt or relaunched.

**Two-process model.** Both the macOS and iOS packages have the same three
targets: the app, a `:hot_reload_server` (watches `HotDemo.swift`, rebuilds the
wasm, serves it over localhost HTTP), and a `:run` launcher (starts the app
connected to the server). Run the server in one shell and `:run` in another:

```sh
# macOS
bazel run //examples/apple/example_partial_wasm_macos_application:hot_reload_server  # shell 1
bazel run //examples/apple/example_partial_wasm_macos_application:run                # shell 2

# iOS Simulator (:run boots a sim, installs, and launches wired to the server)
bazel run //examples/apple/example_partial_wasm_ios_application:hot_reload_server    # shell 1
bazel run //examples/apple/example_partial_wasm_ios_application:run                  # shell 2
```

Now edit `…///examples/wasm/hot_demo_feature/HotDemo.swift`: the server recompiles just the wasm (≈1s)
and every connected app re-renders. Because it's plain localhost HTTP, the app
never runs a compiler itself — the same server drives a real device too (point
`ISO_HOT_RELOAD_SERVER` at your Mac's LAN address). Run an app without a server
and it renders its bundled wasm (static). See
[docs/renderer_layers.md](docs/renderer_layers.md#wasm-hot-reload-example-swiftuirenderer).

Switching renderers without switching targets: any served web instance takes
`?renderer=react` / `?renderer=webGPU` in the URL. On Android, Compose is the
only supported renderer (the self-drawing SwiftGPU renderer still works as a
library — `--es renderer openGL` — but is not an endorsed app path).

Full applications also wire the platform's app surface into SwiftUI — try
the deep link (`.onOpenURL`) and scene phases (`@Environment(\.scenePhase)`, logged by
the example) while the Android app is running:

```sh
adb shell am start -a android.intent.action.VIEW -d "iso://orders/42"   # -> "Opened URL" alert
adb shell input keyevent KEYCODE_HOME                                   # -> scenePhase background
```

### Partial SwiftUI applications

A **partial** application embeds one SwiftUI feature
([`examples/shared/embedded_example`](examples/shared/embedded_example/OrderStatusCard.swift))
inside an app that is otherwise plain Kotlin/Compose or HTML/React — the
`UIHostingController` analogue, for adopting SwiftUI incrementally:

| Platform | Renderer | Target |
| --- | --- | --- |
| android | compiled | `//examples/android/example_partial_compiled_android_application` |
| android | wasm | `//examples/android/example_partial_wasm_android_application` |
| web | react | `//examples/web/example_partial_react_web_application` |
| web | webgpu | `//examples/web/example_partial_webgpu_web_application` |
| electron | react | `//examples/electron/example_partial_react_electron_application` |
| electron | webgpu | `//examples/electron/example_partial_webgpu_electron_application` |

The embed surfaces per host: the `Isomer()` composable (Compose),
`IsomerFragment` in a classic Views app (GL-drawn), the
`<Isomer/>` React component, and `mountIsomer` into a WebGPU
canvas on a plain HTML page — see
[docs/adoption_levels.md](docs/adoption_levels.md).

Every embedded example puts native chrome around the SwiftUI card ("Acme
Store"); everything inside the card — state, taps, the toggle — is Swift.
The Electron targets open the same two host pages in a desktop window.

### The layers underneath

The rungs below the framework (docs/adoption_levels.md calls them Levels 1
and 2) have no example apps here:
[rules_swift](https://github.com/bazelbuild/rules_swift) (raw Swift on the
platform) is exercised by every target above, and
[swift_ffi](swift_ffi/) (idiomatic bindings)
carries this repo's entire host boundary — `swift_ffi/examples` has
standalone greeter apps per platform.

What to expect once a window is up — a two-tab app that adapts its shell to the
available width: a **`NavigationSplitView`** (sidebar · list · detail) when the
canvas is **wide** (desktop, tablet, a wide window) and a **`TabView`** with
bundled icon assets when it's **narrow** (a phone, or any window dragged narrow).
The choice is made live by width — drag a desktop window across the threshold and
the shell switches — so the same build adapts on every platform rather than being
fixed per-OS. One tab lists the bundled **example apps**; the other is the
component **Gallery**. Together they exercise most of the
[supported surface](#swiftui-api-support):

* **Wikipedia** — a live reader. A `.searchable` field drives the Wikipedia API
  (`URLSession` → the bundled JSON parser); results render as a list of
  articles with async-loaded, fill-and-clipped thumbnail `AsyncImage`s (two-line
  `.lineLimit` summaries). Selecting one shows a detail screen that fetches and
  renders the article's full text, with an "Open full page" link into an in-app
  `WebView`.
* **Pokédex** — a mini-app over [pokeapi.co](https://pokeapi.co): list + search,
  a detail page (artwork, types, height/weight) and the games each Pokémon
  appears in. Each game is a tap-to-catch toggle; the "caught" record is
  **persisted** as a JSON file in the app's Application Support (`FileManager`,
  which persists on every platform: IndexedDB on the web) and reloaded on startup.
* **Meme Creator** — our own take on Apple's sample-app tutorial: a draggable,
  rotatable, styled caption over an `AsyncImage`, with live `TextField` / `Slider`
  / color / background controls (`DragGesture` + `.rotationEffect`).
* **2048** — a swipe-to-merge tile game: axis-locked interactive swipes (the
  movable tiles follow the finger, blocked ones stretch a little), animated
  merges and edge spawns (`GeometryReader`, `DragGesture`, `withAnimation`
  with animated `.offset`/`.scaleEffect`, `.ignoresSafeArea()`).
* **Counter** — the smallest example: a button that counts taps.
* **Date Planner** — an original events app: events grouped by day, created and
  edited through a `sheet` (`Form` + `TextField` + `DatePicker` + `Picker`s,
  dismissed via `@Environment(\.dismiss)`), **persisted** with `FileManager`.
  Day/time labels come from `IsomerBridge`'s calendar helpers (UTC epoch math
  on the reimplementation, a UTC `Foundation.Calendar` on Apple) so the same
  source formats dates identically everywhere.
* **Gallery** — a showcase of the implemented components: counter/`Toggle`/
  `Slider`/`Stepper`/`Picker`, `ProgressView` (determinate + indeterminate),
  `Menu` (native pop-up), `GeometryReader`, gradients with `shadow`, a
  `WebView`, a `Form`/`Section`/`OutlineGroup` screen and a selectable `List`,
  the animated `sheet`/`alert`, an `@Environment`/`@EnvironmentObject` demo, the
  `IsomerBridge` logging hook, and the live platform/renderer details at the
  bottom.

Everything is interactive on every target.

**Per-platform notes & knobs**

* **iOS / macOS** — needs Xcode (its simulator runtimes drive the iOS
  target). The macOS app opens directly; iOS installs into a booted
  simulator. To work in Xcode instead, generate a project with
  `bazel run //examples/apple/example_full_compiled_macos_application:example_full_compiled_macos_application_project`
  (or `…/example_full_compiled_ios_application:example_full_compiled_ios_application_project`), which writes
  a gitignored `.xcodeproj` next to the app's `BUILD.bazel`.
* **Android** — if no device/emulator is attached, the runner boots the
  hermetic emulator (downloaded on first build), waits for it, installs the
  APK, launches it, and tails logcat.
* **Web** — `example_full_react_web_application` serves on `http://127.0.0.1:8080` and
  opens your default browser (`-- --no-open` to skip); the Electron targets
  open the same site in a hermetic desktop window instead. The SwiftGPU
  renderer needs a WebGPU-capable browser
  (Chrome, Safari 18+). To run the same build on Windows, `bazel build
  …:example_windows_package`, copy the zip to a 64-bit Windows machine,
  unzip, and run `Isomer.exe`.
* **Windows (native)** — `bazel run //examples/windows/example_full_directx_compiled_windows_application`
  on a Windows host (needs the Swift Windows toolchain + Visual Studio Build
  Tools / Windows SDK). Builds a native Direct2D `.exe`; a per-monitor-DPI-aware
  Win32 window comes up with the same three-pane shell as macOS/web. See
  [Native Windows target](#native-windows-target).
* **Linux (native)** — `bazel run //examples/linux/example_full_opengl_compiled_linux_application`
  on a Linux host (needs the system C toolchain + SDL2 / SDL2_ttf / Mesa GL /
  libcurl dev packages; the swift.org toolchain is fetched by Bazel). Builds a
  native x86_64 ELF; an SDL2 window comes up, drawn on the GPU with OpenGL, with
  the same shell as macOS/web. See [Native Linux target](#native-linux-target).

The application code itself —
[`examples/shared/example_application/ExampleApp.swift`](examples/shared/example_application/ExampleApp.swift) —
is the modern `@main struct ... : App` kind and is compiled **unchanged** for
every target, including:

* **State**: `@State`, `Binding`, and the classic data-model layer —
  `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject`
  (with `$model.property` bindings)
* **Navigation**: `NavigationStack`, `NavigationLink`, `.navigationTitle`
  (drawn nav bar with back button on the reimplementations)
* **Layout**: `VStack`/`HStack`/`ZStack`, `LazyVStack`/`LazyHStack`,
  `Spacer`, `frame`/`padding`
* **Containers**: `ScrollView` (wheel + drag scrolling with clipping and
  indicators), `List` (rows, insets, separators)
* **Controls**: `Button`, `Toggle`, `TextField` (real native text input:
  DOM overlay on web, EditText + IME on Android), `Slider` (drag),
  `Stepper`, `Picker` / `DatePicker` / `Menu` (real native widgets —
  `<select>` / `<input type=date>` on web, `Spinner` / dialog on Android),
  `ProgressView`
* **Containers & layout helpers**: `TabView` (`.tabItem`), `GeometryReader`,
  `.searchable`
* **State & data**: `@State`, `@Published`, `@StateObject`/`@ObservedObject`,
  `@Environment` / `@EnvironmentObject`, `.onChange(of:)`
* **Presentations**: `sheet`, `popover`, `alert` (eased present animation)
* **Content**: `Text`, `ForEach`, shapes, `Image` (bundled assets),
  `AsyncImage` (fetched with each platform's networking stack),
  `LinearGradient` / `RadialGradient` / `AngularGradient`
* **Networking**: `URLSession` (Apple's on Apple platforms, Isomer's
  Foundation over the host elsewhere) + a dependency-free `JSONValue` parser
* **Modifiers**: `background`, `cornerRadius`, `shadow`, `font`,
  `foregroundColor`, `opacity`, `disabled`, `resizable`/`scaledToFit`,
  `onTapGesture`, `onAppear`/`onDisappear`, ...
* **Bridging** (the `Isomer` module's): `PlatformViewRepresentable` (embed a
  native widget), conditionally-compiled `WasmViewRepresentable` /
  `AndroidViewRepresentable`, `BridgedView`, and compile-time `#if os(...)` /
  runtime `Platform.current` (see [Platform-specific code](#platform-specific-code))

## SwiftUI API support

Legend: ✅ full · ◐ partial / reduced fidelity · ❌ not in the
reimplementation. The **Notes** column describes how the reimplementation
backs an API (which native widget it bridges to, what's approximated) or why
something is partial.

**Apple** = iOS + macOS (real SwiftUI). **Android**, **Web**, **Windows**, and
**Linux** run the shared reimplementation and share its API surface. **Web** =
browser, Electron, and the wasm Windows package — all the same wasm. **Windows**
and **Linux** are the separate *native* targets: the same `shared/swift_ui_core`
reimplementation compiled to a native binary and drawn with **Direct2D /
DirectWrite / WIC** (Windows) or an **OpenGL** SDF renderer (Linux), so they
track the Web/Android column except where a host-bridged native widget isn't
wired yet (called out in **Notes**). **Linux** draws its own controls on the GL
surface — `Picker` / `Menu` open a host-drawn drop-down list and `DatePicker` a
host-drawn month calendar — and embeds a real **WebKitGTK** browser as an X11
child window for `WebView` (falling back to a system-browser card on Wayland).
A ❌ for Android/Web/Windows/Linux means the type exists in
real SwiftUI (so it works in a native Apple app) but isn't in the
reimplementation (or that host's bridging) yet — and since the example must
compile **unchanged** for every target, only APIs supported everywhere are usable
in portable shared code.

| API | Apple | Android | Web | Windows | Linux | Notes |
|---|:---:|:---:|:---:|:---:|:---:|---|
| `App` / `Scene` / `WindowGroup`, `@main` | ✅ | ✅ | ✅ | ✅ | ✅ | On **Windows**/**Linux** the app owns `main` and runs its own window + render loop |
| `View` / `ViewBuilder` / `Group` / `AnyView` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `@State`, `Binding` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` | ✅ | ✅ | ✅ | ✅ | ✅ | Mirror-based reflection wires the wrappers before `body` runs |
| `@Environment` / `@EnvironmentObject` | ✅ | ✅ | ✅ | ✅ | ✅ | Custom `EnvironmentKey`s supported |
| `@Environment(\.dismiss)` | ✅ | ✅ | ✅ | ✅ | ✅ | Injected into a presentation's content; closes the enclosing `sheet`/`popover`/`alert` |
| `NavigationStack` / `NavigationLink` / `.navigationTitle` | ✅ | ✅ | ✅ | ✅ | ✅ | **Nav bar is a native host widget** on Android/Web (HTML bar / `LinearLayout`), positioned per-frame so it works per-column in a split view; on **Windows**/**Linux** the bar (back button + title) is drawn into the display list |
| `NavigationSplitView` (3-column) | ✅ | ✅ | ✅ | ✅ | ✅ | The example shows it on a **wide** canvas and `TabView` on a **narrow** one, chosen responsively by width (see below) rather than per-OS |
| `TabView` (modern `Tab`/`TabSection`) | ✅ | ✅ | ✅ | ✅ | ✅ | The iOS 18-style declaration (selectionless subset: `Tab(_:systemImage:)`, `TabSection`, helpers typed `some TabContent<Never>`). With `.tabViewStyle(.sidebarAdaptable)` the web renderer shows a **sidebar on wide canvases** (sections as groups) and a bottom bar on narrow ones; other hosts keep the bottom bar |
| `TabViewCustomization` + `.tabViewCustomization($c)` | ✅ | ✅ | ✅ | ✅ | ✅ | User-reorderable sidebar for `.sidebarAdaptable`: `.customizationID` on `Tab`/`TabSection`, `.customizationBehavior(.disabled, for: .sidebar)` pins an item. **Web** drag-reorders sections and the tabs within them and, when the binding is an `@AppStorage`, persists the arrangement in `localStorage` under the storage key; other hosts honor the arrangement (no drag UI yet). Raw form `":root,ids;sectionID:tab,ids"` |
| `@AppStorage` | ✅ | ✅ | ✅ | ✅ | ✅ | String/Int/Double/Bool + `RawRepresentable<String>`; values are shared by key across views. Persistence is the host's (`Runtime.appStoragePersist` / `setAppStorageValue`) — unwired hosts keep values for the session |
| `Picker` + `.pickerStyle(.segmented)` | ✅ | ✅ | ✅ | ✅ | ✅ | Web renders a **segmented control** (inline, and as a toolbar item — a Picker inside `ToolbarItem(placement: .principal)` becomes the centered segment switcher of a macOS Calendar-style shell); other hosts keep their pop-up list, and a bar-hosted Picker shows as its title there. `.labelsHidden()` is a no-op |
| `Button` styles + roles | ✅ | ✅ | ✅ | ✅ | ✅ | `.bordered`/`.borderedProminent`/`.glass`/`.glassProminent` draw a tinted fill in the tree (identical on every renderer); `.plain`/`.borderless`/`.automatic` are the bare label. `.controlSize` (mini…extraLarge) scales padding + font, `.buttonBorderShape` (capsule/circle/roundedRectangle(radius:)) sets corners. `ButtonRole` `.destructive` (red) / `.cancel` / `.confirm` (bold when it is a `.confirmationAction` bar item); `Button(_:systemImage:[role:]action:)` |
| `Form` / `LabeledContent` | ✅ | ✅ | ✅ | ✅ | ✅ | `Form` renders the inset-grouped look (`.formStyle(.grouped)`; `.automatic`/`.columns` map to it); `Section` with string / header / footer / header+footer inits; `LabeledContent("Label", value:)` and `LabeledContent("Label") { … }` (label leading, content trailing) |
| `.navigationSubtitle` / `.bottomBar` / `.safeAreaInset` | ✅ | ✅ | ✅ | ✅ | ✅ | Subtitle renders under the large title (small secondary; two-line inline bar) on web, rides the `subtitle` navstack param elsewhere. `ToolbarItem(placement: .bottomBar)` (and `.keyboard`) puts the item's VIEW in a bar under the content (hairline + grouped background, in the tree). `.safeAreaInset(edge:)` / `.safeAreaBar(edge:)` pin content at the top/bottom edge and shrink the body to the rest |
| `.sheet` sizing (web) | | | | ✅ | | Regular width: centered modal card (560pt, content scrolls inside); compact: full-height bottom sheet. Root views keep their intrinsic size centered in the canvas (a root `.background` wraps the content, as on Apple) |
| `Label(_:systemImage:)` | ✅ | ✅ | ✅ | ✅ | ✅ | Icon (SF-name text glyph) + title. **Prefer this over bare `Text("⚙")` glyphs in `.toolbar` items** — bar-label extraction picks the glyph, and it stays well-formed when the same source compiles against real SwiftUI on Apple |
| `TabView` (`.tabItem`) | ✅ | ✅ | ✅ | ✅ | ✅ | `selection:` is generic over Hashable (tabs select by `.tag`, index for untagged tabs; `.tabItem{}.tag()` in either order). `.tabViewStyle(.tabBarOnly)` renders the tabs as a centered segmented pill in a strip at the TOP on web, with the selected tab's own navigation bar below (iPad / macOS 15 shape); other hosts keep the bottom bar. **Bottom tab bar is a native host widget** on Android/Web (HTML bar / bottom `LinearLayout`) with bundled-asset icons; on **Windows**/**Linux** it's drawn into the display list (icon + label, accent-tinted selection) |
| `VStack` / `HStack` / `ZStack`, `Spacer`, `Divider` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `LazyVStack` / `LazyHStack` | ✅ | ✅ | ✅ | ✅ | ✅ | Lazy API; eager layout in the reimplementation |
| `ScrollView` | ✅ | ✅ | ✅ | ✅ | ✅ | Wheel + drag, clipping, scroll indicators |
| `List` | ✅ | ✅ | ✅ | ✅ | ✅ | Plain style: insets, separators, `id`/`Identifiable` |
| `List(selection:)` (single) | ✅ | ✅ | ✅ | ✅ | ✅ | Rows carry their value via `.tag(_:)`; the selected row is highlighted |
| `Form` / `Section` | ✅ | ✅ | ✅ | ✅ | ✅ | Grouped, inset-rounded sections (the iOS grouped-list look) with optional headers/footers |
| `DisclosureGroup` / `OutlineGroup` | ✅ | ✅ | ✅ | ✅ | ✅ | Expandable rows and a recursive tree (children via a `KeyPath`) |
| `ForEach` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `Button` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `Toggle` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `Slider`, `Stepper` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `TextField` | ✅ | ✅ | ✅ | ✅ | ✅ | Real native text entry: `EditText` + IME (Android), DOM `<input>` overlay (Web), Win32 keyboard capture (**Windows**), SDL2 text-input + IME (**Linux**) |
| `.searchable` (search field) | ✅ | ✅ | ✅ | ✅ | ✅ | Uses the native text input; the field container is canvas-drawn on Android/Web; on **Windows**/**Linux** it's drawn directly below the large title |
| `Text` | ✅ | ✅ | ✅ | ✅ | ✅ | `font`/`fontWeight`/`bold`/`foregroundColor`; **Linux** rasterizes with SDL2_ttf (DejaVu Sans) into cached textures |
| `.lineLimit` | ✅ | ◐ | ◐ | ◐ | ◐ | Apple truncates with an ellipsis; the reimplementation clips to N lines (no ellipsis) |
| `Color`, `Font` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| Shapes: `Rectangle` / `RoundedRectangle` / `Circle` / `Capsule` | ✅ | ✅ | ✅ | ✅ | ✅ | `fill` / `stroke` |
| `Image` (bundled assets) | ✅ | ✅ | ✅ | ✅ | ✅ | WIC decode on **Windows**; stb_image decode on **Linux** (assets resolved via the Bazel runfiles tree) |
| `AsyncImage` (remote URL) | ✅ | ✅ | ✅ | ✅ | ✅ | Incl. the content/placeholder closure (`.resizable()`/`.scaledToFill()`); fill + rounded clip via a host-composited texture; **Linux** fetches on background threads (libcurl) and uploads a GL texture |
| Layout: `frame`, `padding` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| Decoration: `background`, `overlay`, `cornerRadius`, `border` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `clipShape` | ✅ | ◐ | ◐ | ◐ | ◐ | Android/Web/Windows/Linux map it to `cornerRadius` (rounded-rect clips only) |
| `shadow` | ✅ | ✅ | ✅ | ✅ | ✅ | Shadows the frame silhouette (Canvas2D/Bitmap → texture); **Windows** renders a true Gaussian blur via the Direct2D shadow effect; **Linux** via the SDF shader |
| Gradients: `LinearGradient` / `RadialGradient` / `AngularGradient` | ✅ | ✅ | ✅ | ✅ | ✅ | Rendered to a texture (Canvas2D on Web, Bitmap on Android); Direct2D gradient brushes on **Windows**; evaluated directly in the SDF fragment shader on **Linux** |
| Environment modifiers: `foregroundColor`, `font`, `bold`, `opacity`, `disabled` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `onTapGesture` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `onAppear` / `onDisappear` | ✅ | ✅ | ✅ | ✅ | ✅ | Diffed by structural identity each frame |
| `.onChange(of:)` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `Picker` | ✅ | ✅ | ✅ | ✅ | ✅ | Native widget: `Spinner` (Android), `<select>` (Web), a Win32 drop-down `COMBOBOX` (**Windows**); **Linux** opens a host-drawn drop-down list (scrolls long lists, opens at the selection) |
| `DatePicker` | ✅ | ✅ | ✅ | ✅ | ✅ | Native widget: dialog (Android), `<input type=date>` (Web), `SysDateTimePick32` (**Windows**); **Linux** opens a host-drawn month calendar (prev/next month, tap a day) |
| `Menu` | ✅ | ✅ | ✅ | ✅ | ✅ | Native pop-up: `Spinner` (Android), `<select>` (Web), a Win32 `COMBOBOX` (**Windows**); **Linux** opens a host-drawn drop-down list |
| `ProgressView` | ✅ | ✅ | ✅ | ✅ | ✅ | Determinate bar + indeterminate spinner |
| `GeometryReader` | ✅ | ✅ | ✅ | ✅ | ✅ | Container-relative everywhere: component-system renderers (React, Compose, SwiftUI) measure the reader's box and report it back, so `proxy.size` is the CONTAINER's size, not the canvas. Until the first measurement lands the content builds against the canvas size |
| `WebView` | ✅ | ✅ | ✅ | ✅ | ✅¹ | `WKWebView` (Apple), `android.webkit.WebView` (Android), `<iframe>` (Web), embedded WebBrowser (Trident) control via OLE (**Windows**); **Linux** embeds a real **WebKitGTK** browser as an X11 child window over the GL surface — ¹**X11 only**: on Wayland (or if `webkit2gtk` isn't installed) it falls back to an inline card that opens the page in the system browser (`xdg-open`) |
| `PlatformViewRepresentable` (bridge a native widget) | ✅¹ | ✅ | ✅ | ✅ | ✅ | Reimplementation's portable analogue of `UIViewRepresentable`; on **Windows** each built-in kind maps to a native child window (`COMBOBOX`/`SysDateTimePick32`/WebBrowser); on **Linux** the built-in kinds are host-drawn (drop-down / calendar) and `LinuxViewRepresentable` kinds are drawn over the GL surface |
| `WasmViewRepresentable` / `AndroidViewRepresentable` / `WindowsViewRepresentable` / `LinuxViewRepresentable` | n/a² | ✅ | ✅ | ✅ | ✅ | Conditionally compiled (each its own platform); refine `PlatformViewRepresentable`. `WindowsViewRepresentable` maps to a native Win32 control (`NativeSlider` → `msctls_trackbar32`); `LinuxViewRepresentable` maps to a host-drawn control (`NativeSlider` → a drawn `linux:trackbar` slider) |
| Presentations: `sheet` / `alert` / `popover` | ✅ | ✅ | ✅ | ✅ | ✅ | Drawn screen overlays; the sheet animates in (eased) |
| `withAnimation` / `.animation` (implicit) | ✅ | ✅ | ✅ | ✅ | ✅ | Reimplementation interpolates per-view values on a continuous render loop (`Animator`); eased + spring curves |
| Transitions (insertion/removal) | ✅ | ◐ | ◐ | ◐ | ◐ | Reimplementation animates the sheet presentation + spinner; no general view transitions yet |
| `.rotationEffect` / `.scaleEffect` | ✅ | ✅ | ✅ | ✅ | ✅ | Reimplementation emits a per-primitive 2D affine matrix applied in the renderer (vertex shaders on WebGPU / GLES, Direct2D transforms on **Windows**, a per-vertex affine in the GL shader on **Linux**); animatable |
| `.offset` | ✅ | ✅ | ✅ | ✅ | ✅ | |
| `DragGesture` (`.gesture`) | ✅ | ✅ | ✅ | ✅ | ✅ | `onChanged`/`onEnded` with translation + predicted end; hit-tested against drag regions |
| Native press feedback (ripple / highlight) | ✅ | ✅ | ✅ | ◐ | ◐ | Bridged to native: Android `RippleDrawable` radiating from the touch point (buttons/links), a flat row highlight; web mirrors with a CSS ripple/overlay. Apple is real SwiftUI. **Windows**/**Linux** draw a flat highlight (no ripple). Hit regions are clipped to their scroll viewport |
| Materials (blur) | ✅ | ❌ | ❌ | ❌ | ❌ | |
| Dark mode / `colorScheme` | ✅ | ✅ | ✅ | ✅ | ✅ | Reimplementation resolves light/dark color variants against the system scheme; all draw calls adapt |

¹ On Apple use the real `UIViewRepresentable` / `NSViewRepresentable`;
`PlatformViewRepresentable` is the reimplementation's portable analogue (see
[Platform-specific code](#platform-specific-code)).

² The conditionally-compiled `WasmViewRepresentable` /
`AndroidViewRepresentable` exist only in the reimplementation; on Apple use the
real `UIViewRepresentable` / `NSViewRepresentable` inside an `#if os(...)`
branch (see [Platform-specific code](#platform-specific-code)).

### Styling notes for apps that ALSO build against real SwiftUI

Apps drawing their own control chrome (padded rounded-rect button labels,
custom text-field backgrounds — the natural style here, since this
framework's controls are unbezeled) hit two traps when the same source
compiles against real SwiftUI on Apple:

1. On native builds those controls ALSO carry the system bezel, so custom
   chrome double-borders (every tappable list row becomes a giant bordered
   button). Fix with `.buttonStyle(.plain)` / `.textFieldStyle(.plain)` —
   applied **per control**, not at the root. Both are advisory no-ops in
   this framework, so shared source compiles unchanged.
2. Never apply `.buttonStyle(.plain)` globally: it propagates through the
   environment into `.toolbar` items and strips their native macOS styling —
   combined with bare text-glyph labels (`Text("⚙")`) the items render as
   cramped characters in one misshapen capsule on macOS 15+. Use
   `Label("Refresh", systemImage: "arrow.clockwise")` in toolbars instead.

### Cross-platform services (not SwiftUI)

Networking, files and settings are Foundation's, as on Apple platforms:
`URLSession` (data, upload and download tasks, `URLSessionWebSocketTask`),
`FileManager` in the app's own directories (`URL.documentsDirectory`,
`.applicationSupportDirectory`, `.cachesDirectory`), `UserDefaults` and
`@AppStorage`. Off Apple, Isomer's Foundation sends `URLSession`'s work
through the host (the browser's `fetch` and `WebSocket`, Android's
HttpURLConnection and its own WebSocket client, Apple's `URLSession` in a
WasmView), and the app's directories persist (IndexedDB on the web, the app's
files on Android). A web page that must reach an API through its own server
gives `boot()` a `fetch` of its own.

| Service | Apple | Android | Web | Notes |
|---|:---:|:---:|:---:|---|
| `JSONValue` / `parseJSON` / `.encoded()` | ✅ | ✅ | ✅ | Dependency-free parser/encoder; one source shared between the reimplementation and the Apple shim |
| `Bridge` (`platformName`/`rendererName`/`log`/`openURL`/`epochMilliseconds`) | ✅ | ✅ | ✅ | Foundation/AppKit/UIKit (Apple), JNI (Android), JS imports (Web) |

#### Platform services (host-injected dependencies)

What Foundation doesn't cover, the example apps reach through swift_ffi
interfaces in `shared/platform_services` — `KeychainService`,
`AnalyticsService`, `ConfigurationService`, `ImagePickerService`,
`DeviceMotionService`, `TimerService`, `OAuthService` — plus
`installPlatformDependencies(...)`, which every host calls before start. App
code asks `PlatformDependencies.keychain` (etc.) and awaits the answer:

```swift
let token = try await PlatformDependencies.keychain!.get(key: "token")
```

Interface methods may be `async` and `throws`; the host answers a call id
through the fixed `swift_ffi_async_resume` entry (Apple `URLSession`, Kotlin
`suspend` functions, JS `Promise`s, C vtables with an out-writer — see the
swift_ffi docs). The **same** Swift runs compiled (Apple, Android, Linux,
Windows) and as a wasm reactor under every engine; only the host-side
implementation differs (`examples/apple/platform_services_host`, the Android
`AppServices.kt` / `PlatformServicesWasm.kt`, the web `index.html`
`Dependencies` builders, the desktop hosts' blob dispatchers).

Concurrency gotcha the framework handles for you: neither a wasm reactor nor a
compiled Android process drains Swift's default main executor (WASI's
cooperative executor only runs inside its own loop; Android's main thread is a
Looper, not Dispatch's main queue), so `Task { @MainActor in }`, `.task {}`
and awaited-service continuations would silently never run. swift_ffi installs
an executor factory in reactors (jobs cross to the host's `task_enqueue` and
come back through `swift_ffi_task_run`), and `AndroidBridge.swift` installs one
in compiled Android apps (jobs queue up and the host drains them on its
runtime thread via `nativeRunMainJobs`). Hosts pump those queues from their
frame loops (`iso_wamr_run_jobs`, `WasmRuntime.pumpGuestJobs`).

## Platform-specific code

**Compile-time branching** — the same source can take different paths per
platform with Swift's `#if os(...)`, which works directly inside a
`@ViewBuilder` body. Only the matching branch is compiled, so each branch may
use types/APIs that exist only on that platform:

```swift
var body: some View {
    #if os(iOS) || os(macOS)
    MyAppleView()          // may use UIKit/AppKit here
    #elseif os(Android)
    MyAndroidView()
    #elseif os(WASI)       // the WebAssembly target
    MyWasmView()
    #else
    EmptyView()
    #endif
}
```

**Runtime branching** — when every branch compiles everywhere (choosing a
value or layout, not a type), use the `Platform` enum:

```swift
Text("Running on \(Platform.current.name)")
let columns = Platform.current == .iOS ? 1 : 2
```

**Bridging a native widget** — `PlatformViewRepresentable` (`import Isomer`;
it is Isomer's, so the `SwiftUI` module does not declare it) is the portable
analogue of `UIViewRepresentable`: declare *which* native widget you want (a
`kind` the host understands) plus parameters and a value, and receive a
callback when the user changes it. The host materializes a real DOM element
(web) or Android `View` over the canvas, keyed by structural identity. The
built-in `Picker` and `DatePicker` are implemented this way; on Apple, use
the real `UIViewRepresentable` / `NSViewRepresentable`.

```swift
struct ColorWell: PlatformViewRepresentable {
    let value: String
    let onChange: (String) -> Void

    var kind: String { "html:color" }          // <input type=color> on web
    func onValueChanged(_ newValue: String) { onChange(newValue) }
}
```

**Platform-specific representables** — for code that already lives in an
`#if os(...)` branch, `WasmViewRepresentable` and `AndroidViewRepresentable`
refine `PlatformViewRepresentable` with a platform-flavored vocabulary and
fulfill its requirements (`kind`, `value`, `onValueChanged`) through protocol
extensions, so a conformer only declares what is specific to that platform.
They are conditionally compiled, so they pair naturally with `#if os(...)`:

```swift
#if os(WASI)
// Only `inputType` + `htmlValue` are needed; `kind` becomes "html:range".
struct WebRangeSlider: WasmViewRepresentable {
    let htmlValue: String
    let onChange: (String) -> Void
    var inputType: String { "range" }
    func valueChanged(_ newValue: String) { onChange(newValue) }
}
#elseif os(Android)
// `kind` becomes "android:ratingbar"; the host inflates that widget.
struct StarRating: AndroidViewRepresentable {
    let widgetValue: String
    let onChange: (String) -> Void
    var widget: String { "ratingbar" }
    func valueChanged(_ newValue: String) { onChange(newValue) }
}
#endif

var body: some View {
    #if os(WASI)
    WebRangeSlider(htmlValue: "0.5") { print("range:", $0) }
    #elseif os(Android)
    StarRating(widgetValue: "3") { print("stars:", $0) }
    #else
    EmptyView()
    #endif
}
```

### Incremental adoption (hosting a view inside an existing app)

The framework embeds into an existing host app — the analogue of dropping a
`UIHostingController`'s view into a UIKit screen — rather than only running as a
whole-screen `@main` app. These are the **partial** SwiftUI applications of
the four adoption levels (**docs/adoption_levels.md**: rules_swift →
swift_ffi → partial → full):

* **Apple** — use the real `UIHostingController` / `NSHostingController`.
* **Web** — the `<Isomer wasmURL renderer />` React component
  (`runtime/react_embed.js`) for React host apps, or
  `mountIsomer(container, { renderer })` for any DOM element ("react"
  builds real components inside it; "webGPU" draws into a canvas). See
  `examples/web/example_partial_react_web_application` for a plain host page with
  one SwiftUI card, and `examples/web/example_partial_webgpu_web_application` for the canvas mount.
* **Android** — the `Isomer(modifier)` composable for Compose host apps,
  `IsomerFragment`/`IsomerView` for classic Views; package your
  Swift with `isomer_android_library`. See
  `examples/android/example_partial_compiled_android_application` for a normal Compose
  app embedding one SwiftUI card.

The Swift side chooses the hosted root via its `@main` `App` or a
`IsomerHostingController(rootView:)`. The runtime is a single global
instance, so one embedded surface is active at a time. Embedded surfaces
forward the host lifecycle to `@Environment(\.scenePhase)` but never
reconfigure the host's window or page title.

For full-application adoption, `isomer_android_app` and
`isomer_web_app` generate the platform entry points around your
`@main App` — lifecycle → `scenePhase`, `VIEW` intents/launch URLs →
`.onOpenURL`, `WindowGroup` titles → window/document/task titles, and
platform-specific modifiers (`.androidStatusBarStyle`, `.webDocumentTitle`,
…) over a generic `platformCommand` channel.

## Consuming isomer

Add isomer as a `bazel_dep` with a `git_override`. Because bzlmod
honours `git_override` / `single_version_override` **only from the root
module**, your MODULE.bazel must also repeat isomer's overrides — the
pinned rules_swift fork, the flatbuffers patches (vendored: bzlmod applies
override patches only from the root repo), and the toolchain registrations.
That is the whole list: the bridge generator, the GPU layer and the map
renderer are all part of this one module (`@isomer//swift_ffi/...`,
`@isomer//swift_gpu/...`, `@isomer//swift_map/...`), so one commit pins all of
them. SQLite (swift_sql, a Swift package: list it in the Package.swift
your rules_swift_package_manager graph reads) left this module at 0.34; the
examples use it. C compiled for wasm, swift_sql's included, needs the
rules_swift patch `tools/patches/rules_swift_wasm_clang_resource_dir.patch`
in your rules_swift override, as the examples carry it.

**The complete, always-current reference is
[`examples/MODULE.bazel`](examples/MODULE.bazel)** — the examples are
themselves an external consumer (a standalone module over
`local_path_override`), so that file is exactly the block to copy, with
`local_path_override` swapped for your `git_override`, plus
[`examples/.bazelrc`](examples/.bazelrc) for the required flags (Android
license acceptance, `--strategy=SwiftCompile=local`, …) and
`.bazelversion` for the Bazel release.

Apple-only consumers can skip the Android blocks' *registrations* but not the
`android.sdk`/`android.ndk` tags (the extension requires them from the root
module), and never fetch what they don't build — extensions and SDK downloads
are lazy.

A web-consumer note: guest
code doing cryptography depends on the WASI shim's `random_get`, which is the
platform CSPRNG (`crypto.getRandomValues`) — available in every browser and
Node ≥ 19; environments without it fail loudly rather than degrade. The shim
is also overridable per call: `boot({ wasi: { clock_time_get, ... } })`.

## Requirements

* macOS with **Xcode** (the only system dependency — required by any Bazel
  apple build; its iOS simulator runtimes are used for the iOS target) and
  **Bazel / bazelisk**. The wasm/Android/iOS/macOS targets all build from this
  one macOS host.
* The two **native-host** targets build on their own OS instead: **Windows**
  needs the Swift Windows toolchain + VS Build Tools (see [Native Windows
  target](#native-windows-target)); **Linux** needs a C toolchain (clang) plus
  the SDL2 / SDL2_ttf / Mesa GL / libcurl dev packages (see [Native Linux
  target](#native-linux-target)) — the swift.org toolchain itself is fetched by
  Bazel.
* Everything else is hermetic and pinned by sha256, fetched on first build:
  * swift.org **Swift 6.3.2** toolchain (`.pkg`, extracted with `pkgutil`)
  * official **WebAssembly** and **Android** Swift SDK artifact bundles
  * Android **NDK r27c**, **build-tools 35**, platform **android-35** jar,
    **platform-tools** (adb), **emulator** + ATD arm64 system image
  * **Temurin JDK 21**, **Kotlin 2.1.20** compiler, **Electron v42**
  * hermetic **Python** (rules_python) for the dev web server

The first build downloads several GB; later builds are incremental.

## Testing

```sh
bazel test //...            # framework: snapshot + renderer unit tests
cd examples && bazel test //...   # integration: WAMR DI smokes, engine conformance, networking DI
```

Golden **draw-list snapshot tests**: the platform-agnostic core is compiled for
the host and a view is rendered through the real build → layout → draw pipeline
against a `RecordingHost` (a `HostBridge` with synthetic, deterministic text
metrics). The emitted draw list — every `fillRect` / `drawText` / `pushClip` /
… with rounded coordinates and hex colors — is compared to an inline golden, so
layout and rendering regressions fail fast with a readable diff, no GPU or
browser involved. Regenerate goldens after an intentional change with
`bazel test //tests/snapshot:snapshot_test --test_env=ISO_RECORD=1 --test_output=all`
and paste the printed blocks.

## Repository layout

```
swift_ffi/            Swift <-> Kotlin/TypeScript/C bindings: macros, analyzer,
                      generator, Bazel rules, runtimes (and its own examples)
core_graphics/        Isomer's CoreGraphics (wasm, Android)
foundation/           Isomer's Foundation, from the swift-foundation fork
metal/                Isomer's Metal: the API, the MSL→WGSL translator, the
                      WebGPU backend and its JS executor
swift_gpu/            the GPU abstraction: Metal (Apple's and Isomer's),
                      OpenGL (ES), Direct3D
swift_map/            the OpenStreetMap renderer behind `Map`
examples/             the example applications: the one other Bazel module,
                      consuming this one as an outside application does
shared/
  swift_ui_core/      SwiftUI reimplementation (platform-agnostic): views,
                      ViewBuilder, @State via Mirror reflection, layout
                      engine, draw-list runtime, HostBridge protocol
  example_application/   the full SwiftUI app source used by all targets
  embedded_example/      the SwiftUI card the partial examples embed
wasm/
  libraries/swift_ui/ module `SwiftUI` for wasm (core + wasm host bridge),
                      module `IsomerBridge`, JS runtime (WASI shim,
                      WebGPU + React renderers, embed APIs, boot glue)
web/
  applications/example_{full|partial}_{react|webgpu}_web_application/
                      per-app wasm binary + static site + dev server
electron/
  applications/       the shared shell (main.js/package.json) + the same
                      four sites in hermetic Electron desktop windows
apple/
  libraries/swift_ui/ re-export of system SwiftUI + IsomerBridge (native)
  applications/example_full_compiled_macos_application/  (rules_apple)
  applications/example_full_compiled_ios_application/    -> iOS simulator
android/
  libraries/swift_ui/ module `SwiftUI` for Android (core + JNI host bridge,
                      written in Swift against jni.h), IsomerBridge, and
                      the Kotlin runtime (dev.isomer.runtime: GL view,
                      Compose interpreter, embed surfaces)
  applications/example_{full|partial}_{compiled|wasm}_android_application/
windows/
  libraries/swift_ui/ module `SwiftUI` for Windows (core + Direct2D host
                      bridge), IsomerBridge, C++ renderer (renderer.cpp)
  applications/example_full_directx_compiled_windows_application/  (built on Windows)
linux/
  libraries/swift_ui/ module `SwiftUI` for Linux (core + SDL2/OpenGL host
                      bridge), IsomerBridge, C renderer (renderer.c) +
                      vendored stb_image + embedded WebKitGTK (webview_linux.c)
  applications/example_full_opengl_compiled_linux_application/  (built on Linux)
tools/
  swift_cross/        hermetic toolchain repos + swift_{wasm,android}_*
                      build rules (drive swiftc directly)
  android/            hermetic APK pipeline (kotlinc/d8/aapt2/apksigner),
                      auto-booting adb install/run wrapper, emulator runner
  wasm/               static_site rule, dev server, Electron wrapper
```

## How it works

1. **One Swift engine.** `shared/swift_ui_core` resolves the view tree into
   render nodes, runs a SwiftUI-style propose/respond layout pass, and emits
   a flat draw list (rounded rects, strokes, text runs) plus tap regions.
   `@State` survives re-renders through structural-identity keyed storage,
   wired up with `Mirror` before each `body` evaluation.
2. **Thin hosts.** Each platform implements `HostBridge`: measure text, draw
   the list, schedule frames, deliver pointer events.
   * Web/Electron: wasm imports/exports + a WebGPU renderer (instanced SDF
     rects; text rasterized via OffscreenCanvas into textures).
   * Android: JNI entry points written in Swift; the draw list crosses as a
     single byte array per frame; Kotlin renders with GLES2 shaders that
     mirror the WebGPU ones; text via `Paint` -> `Bitmap` -> texture.
   * Apple: not needed — the real SwiftUI takes over.
3. **Custom Bazel rules.** rules_swift can't target wasm/Android, so
   `tools/swift_cross` drives the pinned swift.org `swiftc` directly
   (`swift_wasm_library/_binary`, `swift_android_aarch64_library/_binary`),
   including a repository rule that merges the NDK sysroot with the Swift
   SDK's `swiftrt.o` the same way the official setup script does.
   [`SPEC.md`](SPEC.md) describes how to upstream this into a `rules_swift`
   fork so plain `swift_library` works for these platforms too.

## Native interop (bridging)

The same SwiftUI code runs on very different hosts, so each platform defines
one explicit seam where Swift talks to the outside world. There are two
bridges: **`HostBridge`** (the rendering/input contract the framework needs
from a host) and **`IsomerBridge`** (the app-facing utility API). Both
follow the same shape:

```
shared Swift code  ──calls──▶  platform-agnostic Swift API (protocol / enum)
                                      │
                              platform Swift glue
                                      │
                     platform boundary (wasm import / JNI / nothing)
                                      │
                       host implementation (JS / Kotlin / Foundation)
```

* The **shared code** only ever sees ordinary Swift (`Bridge.log(...)`,
  `HostBridge.fillRect(...)`).
* The **platform glue** lives in `[platform]/libraries/swift_ui` and adapts
  that Swift API to the platform boundary.
* Strings cross every boundary as UTF-8 `(pointer, length)` pairs or
  platform string types; geometry crosses as plain doubles/floats in
  *logical points* (the host applies display scale).

### How each platform crosses the boundary

**Web (WebAssembly)** — Swift → JS calls are **wasm imports** declared with
`@_extern(wasm, module:, name:)` (enabled via
`-enable-experimental-feature Extern`, which `swift_wasm_library` passes by
default); JS supplies them at instantiation in `runtime/boot.js`. JS → Swift
calls are **wasm exports**: `@_cdecl` functions kept alive with `--export=…`
at link time (the `exports` attribute of `swift_wasm_binary`). A minimal
WASI shim (`runtime/wasi_shim.js`) covers the Swift runtime's startup needs
(clock, random, stdout).

```swift
@_extern(wasm, module: "ubridge", name: "epoch_millis")
func _ubridge_epoch_millis() -> Float64
```
```js
const ubridge = { epoch_millis() { return Date.now(); } };
WebAssembly.instantiateStreaming(fetch(wasmURL), { ubridge, /* … */ });
```

**Android** — the whole JNI surface is Swift, no C shim: `jni.h` (from the
hermetic NDK sysroot) comes in through a bridging header
(`android/libraries/swift_ui/jni_bridge.h`) and the JNI function table is
called through its imported function pointers. Two gotchas baked into
`AndroidHost.swift`:

* JNI entry points must be `public` (internal Swift functions get hidden ELF
  visibility and the loader can't resolve them), so their signatures use
  only raw pointers / primitives — bridging-header types are module-internal.
  Convert with `rawEnv.assumingMemoryBound(to: JNIEnv?.self)`.
* Swift → Kotlin calls use cached `jclass` / `jmethodID` (looked up once in
  `nativeStart`) plus the `CallStatic*MethodA` (jvalue-array) variants — the
  variadic JNI functions aren't callable from Swift.

The draw list crosses as one `ByteArray` per frame (a little-endian op
stream; see `DrawBuffer` and the `UIRenderer.kt` decoder) to keep JNI
chatter to a single call. The app's `@main`-synthesized `main` is invoked
explicitly from `nativeStart` (via `@_extern(c, "main")`) — nothing runs at
library-load time on Android, so the bridge installs the App itself.

**Apple** — no boundary: `apple/libraries/swift_ui/IsomerBridge.swift`
implements the API directly on Foundation/AppKit/UIKit, and the `swift_ui`
target re-exports the system SwiftUI so the dependency shape matches the
other platforms.

### Bridge #1: `HostBridge` (framework-internal)

`shared/swift_ui_core/Runtime.swift` defines the rendering/input contract:

| Member | Direction | Purpose |
|---|---|---|
| `measureText` | Swift → host | text metrics (wrap-aware), logical points |
| `imageInfo` | Swift → host | image status/size; kicks off an async load (asset or URL) on first query, host re-renders on completion |
| `beginFrame` / `fillRect` / `strokeRect` / `drawText` / `drawImage` / `pushClip` / `popClip` / `endFrame` | Swift → host | the draw list (clips map to scissor rects) |
| `beginTextInput` / `endTextInput` | Swift → host | open/close the native text editor over a focused `TextField` |
| `syncHostViews` | Swift → host | reconcile native widgets over the canvas, keyed by id: `Picker`/`DatePicker`/`Menu`/`WebView`/representables, plus the bridged navigation bar and tab bar |
| `scheduleRender` | Swift → host | request a frame after a `@State`/`@Published` change |
| `now` | Swift → host | monotonic seconds, drives animations (eased presentation, spinner) |
| `log` | Swift → host | diagnostics |

Hosts drive the runtime back: `iso_start/iso_render/iso_pointer_event/
iso_wheel_event/iso_resize` on wasm; `nativeStart/nativeRender/nativePointer/
nativeWheel/nativeResize` over JNI. Pointer events
carry down/move/up so the runtime can disambiguate taps from drag-scrolls
and slider drags (taps fire on up within a 6 pt slop; sliders capture the
pointer from down).

*Text input* — `TextField` never fakes a keyboard: on focus the runtime
calls `beginTextInput`, and the host overlays its native editor (a DOM
`<input>` on web/Electron, an `EditText` + soft keyboard on Android, nothing
on Apple). Edits stream back via `Runtime.textChanged(_:)`, Enter triggers
`textSubmitted`, and focus loss ends the session from either side.

*Image loading* — the runtime never touches the network: `Image("name")` /
`AsyncImage(url:)` resolve to an opaque source string and each host loads +
decodes with its native stack (Web: `fetch` + `createImageBitmap`; Android:
`AssetManager`/`HttpURLConnection` + `BitmapFactory`; Apple: real SwiftUI).

### Bridge #2: `IsomerBridge` (app-facing)

The worked example of the pattern, imported directly by app code
(`import IsomerBridge`):

| API | Web | Android | Apple |
|---|---|---|---|
| `Bridge.platformName` / `rendererName` | constants | constants | constants |
| `Bridge.log(_:)` | `console.log` | logcat | `print` |
| `Bridge.epochMilliseconds()` | `Date.now()` | `clock_gettime` | `Date()` |
| `Bridge.openURL(_:)` | `window.open` | `Intent.ACTION_VIEW` (JNI) | `NSWorkspace`/`UIApplication` |

Implementations live in each `…/libraries/swift_ui/IsomerBridge.swift`.

### Adding a new bridged API

1. **Define the Swift surface** in every `IsomerBridge.swift` with an
   identical signature.
2. **Web** — declare a `@_extern(wasm, module: "ubridge", name: …)` import
   and implement it in the `ubridge` object in `runtime/boot.js`. Pass
   strings as `(ptr, len)`; return scalars as `Float64`/`Int32`; for larger
   results write into out-pointers in wasm memory.
3. **Android** — add a `@JvmStatic fun` to `NativeBridge.kt`, cache its
   `jmethodID` in `nativeStart`, and call it with `CallStatic*MethodA`. For
   Kotlin → Swift, add an `external fun` and a matching public
   `@_cdecl("Java_dev_isomer_example_NativeBridge_<name>")`.
4. **Apple** — implement directly with Foundation/AppKit/UIKit.
5. Keep semantics identical — shared application code must never need `#if`s.

## Known limitations

* The reimplementation covers a common subset of SwiftUI (see the support
  table above for exactly what, and what isn't there yet). Apple gets the
  full framework since it links the real SwiftUI.
* On the reimplementation platforms: `.cornerRadius` rounds backgrounds rather
  than true-clipping content (scroll clipping is rectangular scissoring).
* `ScrollView`/`List` scrolling: **Android** backs each widget-free vertical
  scroll region with a real native `ScrollView` overlay (true fling,
  deceleration, and edge-overscroll glow) that drives the GL content's offset;
  regions containing native widgets (a `Picker`/`DatePicker` inside a `Form`)
  and the **web** renderer fall back to the reimplementation's own inertial
  physics on the continuous render loop.
* The native Windows target must be **built on a Windows host** (the Swift
  Windows toolchain and the MSVC/Windows SDK link libraries aren't hermetically
  redistributable, so it can't be cross-compiled from macOS/Linux) — see
  [Native Windows target](#native-windows-target).
* Android APK ships arm64 only (an x86_64 rule exists; add a second
  `swift_android_x86_64_binary` and ABI entry to extend).
* The web dev server is plain HTTP on localhost:8080.

## FAQ

### Native Windows target

`//examples/windows/example_full_directx_compiled_windows_application` is a **native** Windows app: the
same `shared/swift_ui_core` SwiftUI reimplementation compiled to a real x64
`.exe` with the Swift Windows toolchain, hosted in a Win32 window and drawn with
**Direct2D / DirectWrite / WIC** (see `windows/libraries/swift_ui/renderer.cpp`).
The renderer is per-monitor-DPI aware, draws true Gaussian shadows via the
Direct2D shadow effect, and bridges the host-view widgets to real native child
windows: `Picker`/`Menu` to a `COMBOBOX`, `DatePicker` to `SysDateTimePick32`,
`WebView` to the in-process WebBrowser control (via OLE), and any
`WindowsViewRepresentable` to its named control (e.g. `NativeSlider` →
`msctls_trackbar32`). The nav bar, the `.searchable` field, and the `TabView`
tab bar are drawn into the display list. The example shell is responsive — the
three-pane split for a wide window, the tab bar for a narrow one — and switches
live as the window is resized.

It must be **built on a Windows host**: Swift runs great *on* Windows (thanks in
large part to The Browser Company's contributions) but can't be cross-compiled
*to* Windows from macOS/Linux — there's no redistributable Swift SDK artifact
bundle for the Windows target (the toolchain ships as a Windows installer), and
the MSVC / Windows SDK link libraries it needs aren't hermetically
redistributable.

If you'd rather build from any host, `//examples/electron/example_full_react_electron_application:example_windows_package`
is the macOS/Linux-built alternative: the identical wasm application bundled with
the Windows x64 Electron runtime — unzip on any 64-bit Windows machine and run
`Isomer.exe`.

Windows also has a native **wasm** cell — the same shell drawn through
Direct3D 11, running an `example_full.wasm` reactor under the WAMR interpreter
instead of compiled-in Swift — plus cross-platform hot reload. See
[windows/README.md](windows/README.md) for how to run both cells.

### Native Linux target

`//examples/linux/example_full_opengl_compiled_linux_application` is a **native** Linux app: the same
`shared/swift_ui_core` SwiftUI reimplementation compiled to a real x86_64 ELF
with the swift.org toolchain, hosted in an **SDL2** window and drawn on the GPU
with **OpenGL** (see `linux/libraries/swift_ui/renderer.c`). Like the Windows
host, it exposes a flat C API (`renderer.h`) that the Swift host bridge
(`LinuxHost.swift`) calls, and the app owns `main` — creating the window and
running the event/render loop itself (`App.main()` → `LinuxApp.run()`).

Every UI primitive is GPU-rendered through a single signed-distance-field
fragment shader — rounded-rect fills, borders, multi-stop linear/radial/angular
gradients, and soft drop shadows — the same idea the WebGPU/GLES hosts use. Text
is rasterized with **SDL2_ttf** (DejaVu Sans) into cached textures, images decode
with a vendored **stb_image** and upload as GL textures (bundled assets resolved
through the Bazel runfiles tree; remote `AsyncImage` fetched on background
threads), and `URLSession` (the toolchain's Foundation) runs on **libcurl**. The render loop is on
demand — it idles at ~0% CPU and only redraws on input, an animation, or an async
load. The nav bar (with a working back button), the bottom tab bar, and the
`.searchable` field (a native-style search box below the large title) are drawn
into the display list, the same as the Windows host. `Picker` / `Menu` open a
host-drawn drop-down list (scrolls long lists, opens at the current selection),
`DatePicker` a host-drawn month calendar, and a `LinuxViewRepresentable` lets app
code add its own host-drawn control (the example bridges a `linux:trackbar`
slider). The example shell is responsive (three-pane split when wide, tab bar
when narrow) and switches live as the window is resized.

`WebView` embeds a **real WebKitGTK browser**: a `WebKitWebView` in an
undecorated GTK window whose X11 window is reparented (XEmbed-style) as a child
of the SDL window — the same "native child window" model the Windows host uses
for its embedded browser (see `webview_linux.c`). The X server composites the
page over the GL surface; clicks/scrolls over it go straight to WebKit. This is
**X11 only** — on Wayland (or when `webkit2gtk` isn't installed) `WebView` falls
back to a card that opens the page in the system browser (`xdg-open`).

These host-drawn controls float above the GL surface and aren't clipped/rounded
by the renderer (like the Windows native child windows). Still to wire up: press
feedback is a flat highlight (no ripple).

It is **built on a Linux host** with rules_swift's host Swift toolchain (the
swift.org `ubuntu24.04` standalone toolchain, fetched by Bazel), the same way the
Windows target is built on a Windows host. The C renderer links the system
**SDL2**, **SDL2_ttf**, **libGL** (libglvnd / Mesa), and **libcurl** — the dev
packages for these plus a C toolchain are the only host prerequisites:

```sh
# Debian/Ubuntu
sudo apt install build-essential clang libsdl2-dev libsdl2-ttf-dev libgl1-mesa-dev \
    libcurl4-openssl-dev libwebkit2gtk-4.1-dev   # webkit is optional (embedded WebView)

# Arch / SteamOS
sudo pacman -S base-devel clang sdl2 sdl2_ttf mesa libglvnd curl \
    webkit2gtk-4.1   # webkit is optional (embedded WebView; otherwise opens externally)
```

rules_swift's Linux toolchain requires the configured Bazel CC toolchain to be
**clang** (it rejects gcc); the workspace's `.bazelrc` sets `CC=clang` on Linux
hosts automatically. On Arch-based systems (including SteamOS), also symlink the
non-wide ncurses soname the swift.org toolchain's `swiftc` is linked against:
`sudo ln -sf libncursesw.so.6 /usr/lib/libncurses.so.6`.

Linux also has a native **wasm** cell — the same shell drawn through OpenGL,
running an `example_full.wasm` reactor under the WAMR interpreter instead of
compiled-in Swift — plus cross-platform hot reload. See
[linux/README.md](linux/README.md) for how to run both cells.
