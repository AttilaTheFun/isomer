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
| SwiftUI everywhere | One SwiftUI source: Apple's SwiftUI on Apple platforms, Isomer's implementation on the web (DOM or WebGPU), Android (Jetpack Compose), Linux (OpenGL) and Windows (Direct3D) | this module (`isomer`) |
| SQLite everywhere | SQLite's C API and a thin, strict-concurrency-safe Swift layer over it, the same SQLite on every platform (WebAssembly included) | [swift_sql](https://github.com/AttilaTheFun/swift_sql) |
| Swift on every platform | Cross-compilation to WebAssembly, Android and Windows in Bazel | [rules_swift](https://github.com/bazelbuild/rules_swift) (upstream) |
| Bridges to each platform's own language | Generated Kotlin, TypeScript and C bindings | [`swift_ffi/`](swift_ffi/) |
| Apple's frameworks off Apple | `Foundation`, `CoreGraphics` and `Metal` with Apple's interfaces, written in Swift, for the web and Android (Foundation in Isomer's Swift SDKs; Metal: the web, on WebGPU, with Metal Shading Language translated to WGSL) | [isomer_hermetic_toolchains](https://github.com/AttilaTheFun/isomer_hermetic_toolchains), [`core_graphics/`](core_graphics/), [`metal/`](metal/), [docs/parity](docs/parity/) |
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
component-system renderers (Compose, DOM), everything drawn through
SwiftGPU under the self-drawing `SwiftGPURenderer`. See
[docs/renderer_layers.md](docs/renderer_layers.md).

Windows has two ways to run: the **native** target (built on a Windows
host, drawn with Direct2D — see [Native Windows target](#native-windows-target)),
or the **wasm** build packaged from any host: `bazel build
//examples/electron/example_full_react_electron_application:example_windows_package` zips it
with the Windows x64 Electron runtime — copy the zip to a 64-bit Windows machine,
unzip, and run `Isomer.exe`.

Isomer's target platforms have public labels in `@isomer//platforms`, for
an app's `--platforms` (or a transition of its own):
`@isomer//platforms:android_arm64`, `:android_x86_64`, `:wasm32`,
`:linux_x86_64`, `:windows_arm64` and `:windows_x86_64`. They are aliases
of the platforms declared in `@isomer//tools/platforms`, whose labels keep
working: the two name one platform.


### Modules: `SwiftUI` and `Isomer`

The reimplementation's `SwiftUI` module carries **only Apple's SwiftUI API
surface**, so a SwiftPM package written for Apple compiles unchanged on
wasm, Android, Linux and Windows. What Isomer adds beyond it lives in the
`Isomer` module (`Platform.current`, the platform-command modifiers,
`WebView`, `Map`, the JSON helpers): `import Isomer`, on every platform.
(Its names before 0.31, `SwiftUIExtensions` and `IsomerBridge`, were
re-exports of it until 0.40.)
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
Isomer: an iOS app, a web site and an Android app) is
[AttilaTheFun/playground](https://github.com/AttilaTheFun/playground) since
0.47, an application on Isomer that depends on it by version. It was here,
in `examples/playground/`, until then.

**Foundation and CoreGraphics.** On wasm and Android, `import Foundation`
is Isomer's, and it comes with the Swift SDK (since 0.56): Isomer's Swift
SDKs ([AttilaTheFun/isomer_hermetic_toolchains](https://github.com/AttilaTheFun/isomer_hermetic_toolchains),
[docs/hermetic_toolchains.md](docs/hermetic_toolchains.md)) are swift.org's
with corelibs Foundation taken out and Isomer's put in, so every `import
Foundation` built with them, your code's, a Swift package's or a Bazel
module's, is Isomer's with no dependency declared. It is swift-foundation's
FoundationEssentials at swift-6.4.2-RELEASE with a few patches, with no
swift-corelibs-foundation layer (no CoreFoundation; of what corelibs gives
Swift code only what apps reach for, written in Swift: `CharacterSet`,
`NSString`'s string API, `String(format:)`, `NSRange`, `NSRegularExpression`, the locks, `Thread`, `FileHandle`,
`NSNumber`), and no ICU in the plain SDKs: an app that formats dates,
numbers or lists registers the -i18n ones, whose Foundation has
FoundationInternationalization over the SDK's ICU
(`isomer_web_app(icu_locales = ["en"])` trims its data to the languages
named). `import CoreGraphics` and `import Combine` are Isomer's too, from the
same SDKs: geometry, `CGFloat` (a `Double` on every architecture),
`CGAffineTransform`, `CGColor`, `CGPath`. `SwiftUI` re-exports Foundation
and CoreGraphics, as Apple's does. Linux and Windows still use the
toolchain's corelibs Foundation, with Isomer's CoreGraphics and Combine
(`//core_graphics`, `//frameworks/combine`) beside it. docs/isomer_031_plan.md
has the plan and docs/parity/ what each module covers.

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
Android, DOM on web) or the self-drawing **`SwiftGPURenderer`** (everything
drawn at the GPU layer — identical across backends). See
[docs/renderer_layers.md](docs/renderer_layers.md) and
[docs/adoption_levels.md](docs/adoption_levels.md).

Every app follows one naming scheme —
`//<platform>/applications/example_{full|partial}_{renderer}_{platform}_application`.
Web and Electron are separate platforms (they share the wasm build under
`wasm/libraries`).
| Platform | Renderer | Target |
| --- | --- | --- |
| macos | native | `//examples/apple/storybook_macos_application` |
| ios | native | `//examples/apple/storybook_ios_application` |
| android | compiled | `//examples/android/storybook_android_application` |
| android | wasm | `//examples/android/example_full_wasm_android_application` \*\* |
| web | dom | `//examples/web/storybook_web_application` |
| web | webgpu | `//examples/web/example_full_webgpu_web_application` |
| electron | dom | `//examples/electron/example_full_react_electron_application` |
| electron | webgpu | `//examples/electron/example_full_webgpu_electron_application` |
| windows | directx | `//examples/windows/storybook_windows_application` \* |
| linux | opengl | `//examples/linux/storybook_linux_application` \* |

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
the entire shared `@main App` as one wasm bundle under the WasmKit
interpreter, drawn by the same Compose interpreter — the host APK's native
code is the engine library (WasmKit and the shared feature runtime, compiled
Swift: `//android/libraries/wasm_view:engine_native`), none of the app's own
Swift.

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
`?renderer=dom` (`react`, its name until 0.51, still works) / `?renderer=webGPU` in the URL. On Android, Compose is the
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

What to expect once a window is up: the **Storybook**
([examples/storybook/](examples/storybook/)), every SwiftUI API Isomer implements, a story
each, in fifteen areas (text, images, buttons, controls, text input, lists
and forms, layout, scrolling, navigation, presentation, shapes and color,
animation, gestures, state and data, and the Isomer module's own views). A
story's page shows its code, what the API does, and the code running on the
platform, drawn by the platform's renderer: Apple's SwiftUI on iOS and the
Mac, DOM on the web, Compose on Android, OpenGL on Linux, DirectX on
Windows. The shell is a `NavigationSplitView`: the stories beside the page
on a wide window, one column at a time on a phone. Each Storybook app
(com.LoganShire.IsomerStorybook) is released with Isomer, and its proof is
a screenshot of every story's page on every platform. A story's view is
written once, between `// story: <id>` and `// end story` lines, and the
build copies that source into the page, so the code shown is the code that
runs; `ISO_STORYBOOK_STORY=<id>` in the launch environment (the web page's
query) opens one.

The mini apps (Pokédex, 2048, Date Planner, Map Explorer and the rest) are
the [Playground](playground/)'s canned projects.

Everything is interactive on every target.

**Per-platform notes & knobs**

* **iOS / macOS** — needs Xcode (its simulator runtimes drive the iOS
  target). The macOS app opens directly; iOS installs into a booted
  simulator. To work in Xcode instead, generate a project with
  `bazel run //examples/apple/storybook_macos_application:storybook_macos_application_project`
  (or `…/storybook_ios_application:storybook_ios_application_project`), which writes
  a gitignored `.xcodeproj` next to the app's `BUILD.bazel`.
* **Android** — if no device/emulator is attached, the runner boots the
  hermetic emulator (downloaded on first build), waits for it, installs the
  APK, launches it, and tails logcat.
* **Web** — `storybook_web_application` serves on `http://127.0.0.1:8080` and
  opens your default browser (`-- --no-open` to skip); the Electron targets
  open the same site in a hermetic desktop window instead. The SwiftGPU
  renderer needs a WebGPU-capable browser
  (Chrome, Safari 18+). To run the same build on Windows, `bazel build
  …:example_windows_package`, copy the zip to a 64-bit Windows machine,
  unzip, and run `Isomer.exe`.
* **Windows (native)** — `bazel run //examples/windows/storybook_windows_application`
  on a Windows host (needs the Swift Windows toolchain + Visual Studio Build
  Tools / Windows SDK). Builds a native Direct2D `.exe`; a per-monitor-DPI-aware
  Win32 window comes up with the same three-pane shell as macOS/web. See
  [Native Windows target](#native-windows-target).
* **Linux (native)** — `bazel run //examples/linux/storybook_linux_application`
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
| `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject` / `onReceive` | ✅ | ✅ | ✅ | ✅ | ✅ | Since 0.42. Off Apple, Combine is Isomer's own (`frameworks/combine`). `ObservableObject` and `Published` are named from Foundation, as on Apple platforms. On Linux and Windows, whose Foundation is the toolchain's, code imports `Combine` for them. The wrappers subscribe to `objectWillChange` before `body` runs. |
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
| `GeometryReader` | ✅ | ✅ | ✅ | ✅ | ✅ | Container-relative everywhere: component-system renderers (DOM, Compose, SwiftUI) measure the reader's box and report it back, so `proxy.size` is the CONTAINER's size, not the canvas. Until the first measurement lands the content builds against the canvas size |
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
frame loops (`WasmRuntime.pumpGuestJobs`).

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
  `mountIsomer(container, { renderer })` for any DOM element ("dom"
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

`isomer_application` declares one app's targets on every platform from one
Swift library: `<name>_ios`, `<name>_macos`, `<name>_android` (and `_apk`)
and `<name>_web`, built in the mode `--@isomer//:mode` names
(docs/modes.md). It is isomer's (`@isomer//tools/application:defs.bzl`),
and an app names its platforms by values their modules export (since 0.59,
docs/platform_modules.md): `WEB` isomer's, `IOS` and `MACOS` isomer_apple's,
`ANDROID` isomer_android's. An app resolves only the rules of the platforms
it names: rules_apple's graph with isomer_apple, rules_android's and
rules_kotlin's with isomer_android. The modes:

- `compiled` (the default): the app's Swift in each platform's app
  (rules_apple's applications, `isomer_android_app`, `isomer_web_app`);
- `webview`: the app's Swift as wasm in a web view the iPhone, Mac or
  Android app keeps out of sight, drawn by Isomer's tree renderer (Apple)
  or Compose renderer (Android) over the session protocol;
- `remote`: the app served headless elsewhere (`<name>_server`, built with
  `--@isomer//headless`), the apps only heads drawing its session.

The web is wasm in every mode. Each mode's app is also there by name
(`<name>_ios_webview`, `<name>_android_remote`, …).

```starlark
load("@isomer//tools/application:defs.bzl", "WEB", "isomer_application")
load("@isomer_android//:defs.bzl", "ANDROID")
load("@isomer_apple//:defs.bzl", "IOS", "MACOS")

isomer_application(
    name = "notes",
    bundle_id = "com.example.Notes",
    display_name = "Notes",
    platforms = [IOS, MACOS, ANDROID, WEB],
    swift_library = ":notes_lib",  # alwayslink, -parse-as-library, on @isomer//:swift_ui
)
```

## Consuming isomer

List the project's registry before the Bazel Central Registry in your
`.bazelrc`:

```
common --registry=https://raw.githubusercontent.com/AttilaTheFun/bazel_registry/main
common --registry=https://bcr.bazel.build
```

and add isomer as a `bazel_dep` by its release's version (0.36.0 on; a
`git_override` of a commit between releases):

```starlark
bazel_dep(name = "isomer", version = "0.36.1")
```
 The patched
rules_swift isomer needs comes from that registry by version, patches and
all.

**Android: Isomer's AndroidX, or your own** (since 0.54;
[docs/android_maven.md](docs/android_maven.md)). Isomer's Android runtime
builds against the AndroidX set `@isomer//android/maven:androidx` names
(with the Compose compiler `:compose_compiler` names). isomer declares no
Maven of its own for you: an app with no AndroidX of its own adds Isomer's
set, a module released with each isomer, at the same version,

```starlark
bazel_dep(name = "isomer_android_maven", version = "0.54.1")
```

and an app with AndroidX of its own leaves the module out and points both
flags at its own set in its `.bazelrc`. With neither, an Android build
fails saying which to do. An app's own set must carry what ProfileInstaller
loads after launch, Guava's `ListenableFuture` among it: in a graph with
Guava, `listenablefuture` is an empty jar, so export Guava itself
(docs/android_maven.md says what to export, and the crash otherwise).

**The iPhone and the Mac: isomer_apple** (since 0.58;
[docs/platform_modules.md](docs/platform_modules.md)). isomer asks for no
Apple rules: an app on Android and the web alone resolves rules_apple only
at the version rules_swift_package_manager asks for, and none of
rules_applecross's graph. An app whose iPhone and Mac apps come from
`isomer_application` adds the module released with each isomer, at the same
version, and loads the macro from it (`@isomer_apple//:defs.bzl`):

```starlark
bazel_dep(name = "isomer_apple", version = "0.58.1")
```

It brings rules_apple 5.3.1.applecross.6 (as `build_bazel_rules_apple`),
rules_applecross and apple_support 2.11.0; the root still registers the
bundling toolchains ("Upgrading isomer", 0.40). An app that declares its
Apple applications with rules_apple itself needs no isomer_apple.

**Android: isomer_android** (since 0.59;
[docs/platform_modules.md](docs/platform_modules.md)). isomer asks for no
Android or Kotlin rules: an app on the web, the iPhone and the Mac alone
resolves rules_android, rules_kotlin and rules_java only at the versions its
other modules ask for, and no hermetic_android_toolchains. An app with
Android apps adds the module released with each isomer, at the same
version,

```starlark
bazel_dep(name = "isomer_android", version = "0.59.1")
```

and loads Android's macros (`isomer_android_app`, `apk_install_run`,
`ANDROID`, …) from `@isomer_android//:defs.bzl` and `kt_swift_library` from
`@isomer_android//swift_ffi:kt_swift_library.bzl`. Android's Swift
(`@isomer//:swift_ui` and the rest) is still isomer's.

So an Android app has up to two of Isomer's Android modules, for different
reasons: **isomer_android** always (Android's rules and Isomer's macros), and
**isomer_android_maven** only when it uses Isomer's AndroidX rather than its
own (above). They stay apart so that an app with AndroidX of its own never
evaluates Isomer's Maven set, nor has its rules_jvm_external raised by it.
rules_android's own Maven (its tools) is
rules_android's to declare; docs/android_maven.md shows how to pin it with
isomer's lock file, as the examples do.

Isomer's Swift libraries are a Swift package too (since 0.43: SwiftUI and
the frameworks it stands on, from isomer's root Package.swift), built
through rules_swift_package_manager in your own SwiftPM graph, so
SwiftProtobuf and swift-syntax resolve once for your packages and Isomer's.
List isomer in the Package.swift your graph reads, at the same release, by
its tag (or a commit between releases; isomer takes swift-syntax by branch,
which SwiftPM allows only beneath a revision pin):

```swift
.package(url: "https://github.com/AttilaTheFun/isomer.git", revision: "v0.43.1"),
```

use rules_swift_package_manager's own `swift_deps` extension (not a
re-export of your own: isomer adds its wire protos' modules to it), and let
the generated package repositories see `@isomer`, which those additions
name:

```starlark
swift_deps = use_extension("@rules_swift_package_manager//:extensions.bzl", "swift_deps")
swift_deps.from_package(
    resolved = "//third_party/swift_packages:Package.resolved",
    swift = "//third_party/swift_packages:Package.swift",
)
inject_repo(swift_deps, "isomer")
```

**Only the root module's take effect.** `inject_repo` and `override_repo`
are ignored in any module that is not the root (as dev dependencies are),
and so are the `dev_dependency = True` extension tags and registrations the
examples use (hermetic_android_toolchains reads its `android.sdk` and
`android.ndk` tags from the root alone). A module of yours that builds an
Isomer app and is itself a dependency (a feature module a larger app's
repository depends on, not the root) has its own lines ignored there: the
root repeats them, depending on isomer itself so that it can name it:

```starlark
# The root's MODULE.bazel, when an Isomer app comes from a module beneath it.
bazel_dep(name = "isomer", version = "0.53.0")  # the version the module uses

swift_deps = use_extension("@rules_swift_package_manager//:extensions.bzl", "swift_deps")
swift_deps.from_package(
    resolved = "//third_party/swift_packages:Package.resolved",
    swift = "//third_party/swift_packages:Package.swift",  # lists isomer, as above
)
inject_repo(swift_deps, "isomer")

# Android: the NDK and SDK, and rules_android pointed at that SDK.
bazel_dep(name = "hermetic_android_toolchains", version = "0.5.0.isomer.2")
android = use_extension("@hermetic_android_toolchains//:extensions.bzl", "android")
android.sdk(build_tools_version = "35.0.0", version = "35")
android.ndk(api_level = 28, version = "r30")
use_repo(android, "androidndk", "androidsdk")
rules_android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
override_repo(rules_android_sdk, "androidsdk")
register_toolchains("@androidndk//:all", "@androidsdk//:all")
```

The isomer the root depends on and the one its Package.swift lists are the
module's release: one isomer in the build.

Nothing of isomer's needs an override in your MODULE.bazel since 0.40 (its
rules_swift, 4.3.0.isomer.2, sorts above the version rules_applecross asks
for); you still register the toolchains, and only those of the platforms
you build: an app for iOS, the Mac and Android declares the host toolchain
and Isomer's Android SDK (below) and registers the Android Swift toolchains, with
no wasm SDK, wasm toolchains, Windows SDK or rules_swift_package_manager
Windows patch (0.40: isomer's targets for those platforms are only
analyzed when built). That is the whole list: the bridge generator, the GPU layer and the map
renderer are all part of this one module (`@isomer//swift_ffi/...`,
`@isomer//swift_gpu/...`, `@isomer//swift_map/...`), so one commit pins all of
them. SQLite (swift_sql, a Swift package: list it in the Package.swift
your rules_swift_package_manager graph reads) left this module at 0.34; the
examples use it. C compiled for wasm, swift_sql's included, needs
rules_swift#1989, which rules_swift has since 4.3.0.

**Isomer's Swift SDKs.** On Android and the web Foundation is the Swift
SDK's, so an app registers Isomer's SDKs (since 0.56) in the `swift` block
it already has, in place of `swift.android_sdk()` and `swift.wasm_sdk()`.
One snippet a platform, each standing alone: an app that builds for
Android alone takes the first and registers no wasm SDK.

If you build for Android:

```starlark
swift.android_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.2/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz",
    sha256 = "19094e58e92669d26a4ce31e5a05f85963eeb5af9cafa35475f2a55e4d69451c",
)
```

If you build for the web:

```starlark
swift.wasm_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.2/swift-6.4.2-RELEASE_wasm.artifactbundle.tar.gz",
    sha256 = "9bd7e1808fc9fb5027b89becbf2559946e19e9a365aac6876eedf834cceb68cf",
)
```

If your app formats dates, numbers or lists with Foundation (`formatted()`,
`Date.FormatStyle`, locales and calendars beyond English and the Gregorian),
take the -i18n SDK instead, whose Foundation has FoundationInternationalization
and ICU (tens of megabytes of data, which `icu_locales` trims on the web):

```starlark
# Android, formatting:
swift.android_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.2/swift-6.4.2-RELEASE_android-i18n.artifactbundle.tar.gz",
    sha256 = "ab250666b10586a507abf4b80b55bf453ddeae1a7d499c788c4d347d5b55ce93",
)
# The web, formatting:
swift.wasm_sdk(
    url = "https://github.com/AttilaTheFun/isomer_hermetic_toolchains/releases/download/isomer-6.4.2.2/swift-6.4.2-RELEASE_wasm-i18n.artifactbundle.tar.gz",
    sha256 = "86cb53c7af7808fd0b07e2f37b7a66a7a64f379b18348aedaaff7ddab24fb36b",
)
```

The SDKs move on their own cadence (isomer_hermetic_toolchains' releases,
whose notes carry these lines); each is the Swift release isomer's toolchain
is (6.4.2), which `swift.toolchain`'s `swift_version` must match.

**Protocol buffers.** Isomer's wire protos are compiled as you build
(`swift_proto_library`, shared/wire), against your graph's SwiftProtobuf
(the swift-protobuf package your Package.swift resolves). Isomer asks for
protobuf 27.0 or newer, the oldest with the `proto_library` it loads;
rules_swift itself asks for 34.0.bcr.1, so that is what an app on
rules_swift resolves. Your own `swift_proto_library` targets should use the
same SwiftProtobuf, or the app links two: rules_swift's default compiler
brings its own, swift-protobuf 1.20.2 (a repository of rules_swift's own,
which no override reaches). Name isomer's compiler, whose runtime is your
graph's:

```starlark
swift_proto_library(
    name = "messages",
    compilers = ["@isomer//shared/wire:swift_proto"],
    protos = [":messages_proto"],
)
```

(or a `swift_proto_compiler` of your own over
`@swiftpkg_swift_protobuf//:protoc-gen-swift` and `:SwiftProtobuf`, as
shared/wire/BUILD.bazel's is, for other plugin options). Take
SwiftProtobuf from that graph rather than as a module of your own: Isomer's
SwiftUI depends on it, and `--@isomer//:library_evolution` builds it
resilient too, for generated modules built with library evolution.
docs/compatibility.md lists every Bazel module isomer asks for, at what
version and why.

**The complete, always-current reference is
[`examples/MODULE.bazel`](examples/MODULE.bazel)** — the examples are
themselves an external consumer (a standalone module over
`local_path_override`), so that file is exactly the block to copy, with
`local_path_override` dropped (isomer by version) or swapped for your
`git_override`, plus
[`examples/.bazelrc`](examples/.bazelrc) for the required flags (Android
license acceptance, `--strategy=SwiftCompile=local`, …) and
`.bazelversion` for the Bazel release.

**Bazel 8.** isomer builds with 9.1.1; a consumer may build with 8.5.0 or
later (MODULE.bazel's `bazel_compatibility`). One issue seen there: a Mac
host that builds Isomer's build-time Swift tools (the bridge generator, the
macros) with apple_support's C toolchain, registered through
`--extra_toolchains`, failed their static archives in the sandbox
(`CppArchive`: "execvp(…/apple_support+/crosstool/apple-support-ar-wrapper):
No such file or directory"), and built them with:

```
build --strategy=CppArchive=local
```

It doesn't happen with the examples on Bazel 8.8.1 and apple_support 2.11.0
(the Android Storybook, the tools built for the Mac, the toolchain given by
`--extra_toolchains` too), so it depends on something else in that build's
flags; the flag is harmless either way. To see whether a build has it, look
at an archive action's inputs: the sandbox can run the wrapper only when it
is among them (a count of 0 here, with the wrapper in the command line, is
the failure).

```sh
bazel aquery 'mnemonic(CppArchive, @isomer//swift_ffi/swift_ffi)' | grep 'Inputs:' | grep -c apple-support-ar-wrapper
```

### Upgrading isomer

Each release's notes have an Upgrading section; these things are easy to miss:

- **Android's rules are isomer_android's (since 0.59,
  docs/platform_modules.md).** isomer no longer asks for rules_android,
  rules_kotlin, rules_java or hermetic_android_toolchains:
  - an app that builds for Android adds
    `bazel_dep(name = "isomer_android", version = …)` at isomer's version
    (beside isomer_android_maven, if it has that already: the two are
    apart, so an app with AndroidX of its own still needs only the first),
    and changes its loads: `@isomer//tools/android:defs.bzl` is
    `@isomer_android//:defs.bzl` (the same macros and rules), and
    `@isomer//swift_ffi/rules:kt_swift_library.bzl` is
    `@isomer_android//swift_ffi:kt_swift_library.bzl`. The old files are
    still there, and fail saying so;
  - labels that moved with them: `@isomer//android/libraries/swift_ui:`
    `compose_compiler_plugin` and `:isomer_platform` are
    `@isomer_android//swift_ui:…`; `@isomer//android/libraries/wasm_view:`
    `wasm_engine_bindings` and `:engine_native` are
    `@isomer_android//wasm_view:…`; `@isomer//swift_ffi/runtime/kotlin` is
    `@isomer_android//swift_ffi:kotlin`. Every other label, the Swift ones
    and the flags (`--@isomer//tools/android:shared_platform`) included, is
    as it was;
  - `isomer_application` is isomer's again, and takes its platforms as
    values: `load("@isomer//tools/application:defs.bzl", "WEB",
    "isomer_application")`, `IOS` and `MACOS` from
    `@isomer_apple//:defs.bzl`, `ANDROID` from `@isomer_android//:defs.bzl`,
    and `platforms = [IOS, MACOS, ANDROID, WEB]` (the arguments and
    targets as before). isomer_apple's `isomer_application` fails saying
    so;
  - an app that relied on isomer for rules_android 0.7.3, rules_kotlin
    2.2.2 or rules_java 9.3.0 without asking for them, and builds no
    Android, asks for them itself.
- **The iPhone's and the Mac's apps are isomer_apple's (since 0.58,
  docs/platform_modules.md).** isomer no longer asks for rules_apple or
  apple_support 2.11.0 (apple_support only at rules_swift's 2.9.1):
  - an app that loads `isomer_application` and builds the iPhone's or the
    Mac's apps adds `bazel_dep(name = "isomer_apple", version = …)` at
    isomer's version and changes its load to
    `load("@isomer_apple//:defs.bzl", "isomer_application")`: the same
    arguments and targets. isomer's own `isomer_application` builds Android
    and the web, and refuses `ios` and `macos`, naming the module;
  - an app that relied on isomer for rules_apple 5.3.1.applecross.6 or
    apple_support 2.11.0 asks for them itself (an app with Apple apps of
    its own already does: nothing changes for it);
  - swift_map's Apple example apps and XCFramework are the examples'
    (`examples/swift_map/…`), not `@isomer//swift_map/apple/applications`
    and `@isomer//swift_map/apple/xcframework`.
- **Isomer's Swift SDKs isomer-6.4.2.2 (since 0.58): Android at API 23.**
  isomer-6.4.2.2's Android SDKs are built at API 23; move to it: both
  `swift.android_sdk` and `swift.wasm_sdk` to its lines ("Isomer's Swift
  SDKs" above, or the release's notes), as isomer's own builds have.
  isomer-6.4.2.1's were compiled for API 28, so an app at minSdk 23 failed
  to link (`getgrgid_r` and `getgrnam_r` undefined in
  libFoundationEssentials.a). From then on every SDK build checks its
  libraries against its minimum API (docs/hermetic_toolchains.md, "The
  SDKs' checks").
- **Upgrading from 0.55 or earlier: `bazel clean` once.** 0.56 took
  Foundation, FoundationNetworking and IsomerFoundation out of isomer's
  Swift package (the SDK's are used instead), but an output base that built
  them keeps their `.swiftmodule`s in the package's output directory, where
  Swift's unsandboxed compiles find them before the SDK's. The link then
  fails with Foundation's stored properties' addressors undefined
  (`$s10Foundation10FileHandleC13standardErrorACvau`,
  `$s10Foundation25NSLocalizedDescriptionKeySSvau`) and
  `NotificationCenter.Publisher`'s Combine witness table, and objects that
  import Foundation autolink no `-lFoundation`. A clean build has neither.

- **`wasm_sdk_bundle` carries Foundation again (since 0.57).** 0.56's bundle
  had no Foundation, CoreGraphics or Combine (they left the package for the
  Swift SDK); 0.57's takes them from the registered wasm SDK
  (`sdk_foundation = False` leaves them out). A rule of your own that added
  them, as the Playground's `wasm_sdk_foundation` did, can go.
- **Web-view mode on Android (since 0.57).** `isomer_application` builds an
  Android app in `--@isomer//:mode=webview` (`isomer_android_webview_app`):
  the app's site in its APK, run in a WebView it keeps out of sight and drawn
  by the Compose renderer (docs/modes.md). Android 6's own WebView runs no
  wasm: such an app needs an updated WebView there.

- **Foundation is the Swift SDK's on Android and the web (since 0.56).**
  - Register Isomer's Swift SDKs ("Isomer's Swift SDKs" above): replace
    `swift.android_sdk()` and `swift.wasm_sdk()` with the snippet of each
    platform you build for, the plain URL, or the -i18n one if the app
    formats dates or numbers. Without them `import Foundation` there is
    swift.org's corelibs Foundation again, and links fail.
  - Drop Foundation's edges: the `configure_package(target_deps = …)`
    entries that gave a package `@isomer//:foundation`, and the
    `@isomer//:foundation` and `@isomer//:isomer_foundation` in your
    BUILD files' deps. Both labels stay, empty, so nothing breaks if you
    leave them; `@isomer//foundation:for_swift_packages` and the
    `@swiftpkg_isomer//:Foundation`, `:FoundationNetworking` and
    `:IsomerFoundation` products are gone.
  - `--@isomer//foundation:internationalization` no longer builds
    FoundationInternationalization into Foundation: the -i18n SDK is what
    has it. The setting stays, and on Android and the web it checks that
    the SDK registered is the -i18n one (a build that sets it with the
    plain SDK fails, saying which to register); keep it if your app sets
    it, or drop it with the -i18n SDK in place.
  - rules_swift is the registry's 4.3.0.isomer.1 (upstream 4.3.0, which
    takes `swift.android_sdk(url = …)`, and four pull requests); your own
    override of rules_swift, if you kept one, has to be that version.
    It asks for **bazel_features 1.54.0** or later: a root that holds
    bazel_features lower with a `single_version_override` fails as
    `@rules_swift//swift` loads, with "'struct' value has no field or
    method 'label_build_setting_has_scope'". Raise that override to 1.54.0
    (or drop it).
  - After changing an SDK's URL, or upgrading Isomer or rules_swift, run
    `bazel clean` once if a build reports a module "defined in both"
    (`module '_Builtin_stddef' is defined in both '…/_swift_module_cache/…'
    and '…'`). Bazel keeps Swift's Clang module cache across builds, and
    the modules cached before the change still name the old build of a
    module the new SDK or rules_swift builds again. A clean build, as CI's
    are, never sees it.
  - `tools/foundation/check_link.py` is gone: there is one Foundation to
    link.

- **Isomer's AndroidX is a module of its own (since 0.54).** isomer no
  longer declares any Maven for its consumers (docs/android_maven.md):
  - an app that used Isomer's AndroidX (left
    `@isomer//android/maven:androidx` at its default) adds
    `bazel_dep(name = "isomer_android_maven", version = …)` at isomer's
    version, or its Android builds fail saying so;
  - an app with its own AndroidX (both flags set) changes nothing, and
    no longer evaluates Isomer's Maven: a rules_jvm_external older than
    isomer's is fine;
  - `@isomer_maven` exists only with the module: an app that named its
    targets directly (`use_repo(maven, "isomer_maven")`) depends on the
    module or on its own artifacts;
  - `@rules_android_maven` is no longer pinned by isomer: an app that
    relied on that pin declares it with isomer's lock file
    (`lock_file = "@isomer//:rules_android_maven_install.json"`,
    docs/android_maven.md) or its own, or lets rules_android resolve it;
  - `rules_xcodeproj` and `rules_jvm_external` are isomer's development
    dependencies only, so isomer no longer raises an app's to 4.1.0 and
    7.1: an app that needs those versions asks for them itself.

- **No Python or TypeScript in an app's build (since 0.54).** isomer no
  longer brings rules_python, aspect_rules_js, aspect_rules_ts,
  rules_nodejs, aspect_rules_esbuild or a TypeScript pin to its consumers
  (they are its development dependencies): an app that relied on isomer for
  any of them, or for their versions, declares them itself. The tools that
  ran in Python (a reactor's export list, ICU's data trimming, the web
  server `bazel run` starts) are Swift now, with the same arguments and
  outputs.
  - `ts_swift_wasm_library` is `js_swift_wasm_library`: the generated
    bindings are an ES module, compiled by nothing, with their TypeScript
    declarations beside it in `:<name>_types`. The old name still works, and
    `:<name>`, `:<name>_js` and `:<name>_runtime_js` are the same files.
  - A page that imported the bindings' `.ts` sources through its own
    TypeScript build imports the `.js` module, typed by the `.d.ts`.
- **WasmKit is upstream's release (since 0.56).** isomer pins
  swiftwasm/WasmKit's 0.5.0 by tag, with the side-modules commits a patch
  on it until upstream takes them (AttilaTheFun/WasmKit at upstream's main
  and those commits in 0.54 and 0.55). Nothing changes for an app.
- **WasmKit without isomer's patches (since 0.54).** 64-bit Android
  reactors use WasmKit's guard pages, as
  macOS, Linux and iOS do, and an out-of-bounds memory access from a host
  (`Memory.withUnsafe(Mutable)BufferPointer(offset:count:)`) throws a trap
  rather than reading past the memory. A host that calls those directly adds
  `try`.

- **Isomer's Swift is a Swift package (since 0.43).** Add isomer to the
  Package.swift your rules_swift_package_manager graph reads (by revision,
  the release's tag: "Consuming isomer" above), use
  `@rules_swift_package_manager//:extensions.bzl`'s `swift_deps` rather
  than a re-export of your own, and add `inject_repo(swift_deps, "isomer")`.
  Drop the `override_repo` of isomer's `swiftpkg_swift_collections`
  (`@isomer//third_party/swift_packages:extensions.bzl` is gone), and any
  `@@isomer+//` canonical labels in your `target_deps`: `@isomer//` resolves
  there now. A `build_bazel_rules_swift` or `rules_license` dependency or
  injection kept only for the generated repositories can go too: they see
  rules_swift_package_manager's own.
- **SwiftUI is in the package too (since 0.44).** Nothing changes in what
  you write, but run `bazel clean` once after upgrading: SwiftUI's module
  moves into the package's output directory, and a stale one left elsewhere
  by an earlier build can shadow it (Swift compiles run unsandboxed).
- **Apple apps bundle through rules_applecross (since 0.40).** The
  registry's rules_apple (5.3.1.applecross.6) bundles through
  `@rules_applecross//toolchain:apple_bundling_toolchain_type`, and
  rules_applecross registers its toolchains only as a dev dependency. A root
  that builds iOS or Mac apps depends on rules_applecross and registers the
  bundling toolchain itself, or every app fails with "No matching toolchains
  found for …apple_bundling_toolchain_type":

  ```starlark
  bazel_dep(name = "rules_applecross", version = "0.0.3.382f8c3")
  register_toolchains("@rules_applecross//toolchain:apple_bundling_on_macos")
  # Building Apple apps on Linux too: also
  # "@rules_applecross//toolchain:apple_bundling_on_linux" (examples/MODULE.bazel).
  ```
- **Your own override of rules_swift wins.** A root's
  `single_version_override` (or `git_override`) of rules_swift is kept
  whatever version isomer asks for: bumping isomer alone silently keeps the
  old fork. Since 0.40 isomer's rules_swift needs no override (it sorts above
  rules_applecross's); delete yours, or move it to the version isomer's
  release names (4.3.0.isomer.1 at 0.56). The same goes for an override of
  one of rules_swift's own dependencies: an override below what rules_swift
  asks for (bazel_features 1.54.0 for 4.3.0) wins too, and fails in
  rules_swift's files.

### Swift features, Java and library evolution

- **Scope Swift features to your own repository.** `build
  --features=swift.enable_v6` (or `swift.upcoming.StrictConcurrency`,
  `swift.treat_warnings_as_errors`, `swift.enable_library_evolution`) in a
  .bazelrc applies to every repository in the build: isomer, and every
  SwiftPM package and module beneath it. Put them in your repository's
  `REPO.bazel` instead (or a `package(features = [...])`), where they reach
  your packages alone:

  ```starlark
  # REPO.bazel, at your workspace's root
  repo(features = ["swift.enable_v6", "swift.treat_warnings_as_errors"])
  ```

  isomer's own REPO.bazel turns the common ones off for its packages (a
  repository's `-feature` wins over the command line's), so its modules
  build as they are tested whatever you set; it can't do so for its
  dependencies or yours.
- **Java 17 for Android's tools.** `--java_language_version=17` and
  `--tool_java_language_version=17` (with the remote JDK 17 runtimes,
  examples/.bazelrc's four lines): rules_android's dexer is Java with
  records, and at a lower language level fails with "records are not
  supported in -source 11".
- **Library evolution is for Apple's binary frameworks, not isomer's
  platforms.** isomer's modules (Foundation, SwiftUI, Isomer and the rest)
  are compiled without `-enable-library-evolution` by default: they are
  linked into each app, and on Android, wasm, Linux and Windows there is no
  binary-stable system framework for resilience to serve. Don't enable it
  for your targets there. If you do (an Apple framework built from the same
  library), each public import of an isomer module reports "module
  'SwiftUI' was not compiled with library evolution support": a warning
  (which Swift 6.4's `-warnings-as-errors` leaves a warning), and an error in
  a library built for distribution (InternalImportsByDefault at
  `-library-level api`), in no diagnostic group either way. Turn library
  evolution off for those platforms with a `select` on the target's
  `features`, e.g.
  `features = select({"@platforms//os:android": ["-swift.enable_library_evolution"], "//conditions:default": []})`,
  import isomer's modules `internal` where your interface doesn't use them,
  or build isomer's modules resilient too with
  `--@isomer//:library_evolution` (docs/library_evolution.md: what it costs,
  measured on the Android Storybook: +2.7% to the app's library, +0.85% to
  the APK, a tenth more build time, no change in frames that the Storybook
  could measure).
  A library shipped prebuilt with a `.swiftinterface` needs library
  evolution for the interface: an `internal import` of each Isomer module
  its interface doesn't name keeps the warning away (below, "Prebuilt
  Swift libraries", docs/prebuilt_swift_libraries.md).

Apple-only consumers can skip the Android blocks' *registrations* but not the
`android.sdk`/`android.ndk` tags (the extension requires them from the root
module), and never fetch what they don't build — extensions and SDK downloads
are lazy.

A web-consumer note: guest
code doing cryptography depends on the WASI shim's `random_get`, which is the
platform CSPRNG (`crypto.getRandomValues`) — available in every browser and
Node ≥ 19; environments without it fail loudly rather than degrade. The shim
is also overridable per call: `boot({ wasi: { clock_time_get, ... } })`.

### Android below API 28

Swift's Android SDK supports API 23 and later since Swift 6.4 (swift.org
builds it at 23, with NDK r30), and so does Isomer since 0.41. Isomer's own
apps stay at 28; an app that must reach older phones sets:

- its NDK at that level: `android.ndk(api_level = 23, ...)` in its
  MODULE.bazel (hermetic_android_toolchains);
- `isomer_android_app(..., min_sdk_version = 23)` (or its own manifest's
  minSdkVersion).

Nothing else: the registry's rules_swift (rules_swift#2000) links Android
libraries below API 28 without RELR relocations, which Android's loader
reads only from 28, and fails an Android target below the Swift SDK's own
minimum; Isomer's Android runtime calls newer APIs only behind version
checks. Swift's C++ interop works there too: with NDK r30 and Swift 6.4.2
it builds and runs at API 23.

To run it on the hermetic emulator at that level, give the emulator
Google's API 23 image in the app's MODULE.bazel (it boots on Apple
silicon; `tools/android/emulator/run_emulator.sh` reads the image's API
level and keeps an AVD per level):

```starlark
android_tools = use_extension("@isomer//tools/android:extensions.bzl", "android_tools")
android_tools.system_image(
    host = "mac",
    url = "https://dl.google.com/android/repository/sys-img/android/arm64-v8a-23_r07.zip",
    sha256 = "74427db25e4b56a424d4f7d874a253bcd43c0db7be2c7b0b5dbb142e860131a4",
)
```

Android 6.0 has no adb shell protocol: `adb shell` copies its standard
input to the device until it closes, so a call left with an open one (a
pipe, a terminal) hangs. Isomer's scripts run adb with standard input
closed, and hand the device files with `adb push`, never through a pipe;
do the same in an app's own tooling.

**A host app below API 23** (an existing app at API 21 embedding an
Isomer app) can't give Swift its own C++ toolchain: the registry's
rules_swift refuses an Android target below the Swift SDK's minimum ("The
Swift SDK for Android supports API 23 and later, but the C++ toolchain
targets aarch64-linux-android21."). Swift needs a second NDK toolchain at
23, ahead of the host's own. hermetic_android_toolchains' NDK, as Isomer's
MODULE.bazel declares it, at API 23 and under a name of its own (the
host's NDK may be `@androidndk` already):

```starlark
bazel_dep(name = "hermetic_android_toolchains", version = "0.5.0.isomer.2")
android = use_extension("@hermetic_android_toolchains//:extensions.bzl", "android")
android.sdk(build_tools_version = "35.0.0", version = "35")
android.ndk(api_level = 23, version = "r30")
use_repo(android, swift_ndk = "androidndk")
```

and in the host's .bazelrc, so that it outranks every registered toolchain:

```
build --extra_toolchains=@swift_ndk//:all
```

(The extension takes one root `android.ndk` tag: a host whose own NDK at
21 is hermetic_android_toolchains' too takes one of the two from another
source, such as rules_android_ndk.) `--extra_toolchains` outranks the
host's registrations for every C and C++ compile of that build, not only
Swift's: the host's own native code built with it targets API 23 too. Code
that must load on Android 5 (API 21 and 22) comes from a build without the
flag (a prebuilt library), and the host opens the Isomer app only from
API 23 (`Build.VERSION.SDK_INT >= 23`); its Swift can't load below that.

### Android release size

An app's Swift is one JNI library (`lib<app>_runtime_bindings.so`): the
Swift runtime, Foundation, SwiftUI and the app, statically linked. It
exports only its JNI entry points (`Java_*`, and `JNI_OnLoad` where a
library has one: swift_ffi/rules/jni_exports.lds), in every build since
0.53: what it links statically, libc++ among it, stays its own, never
meeting another library's copy in the process (a host app's
`libc++_shared.so`, a prebuilt C++ library's). C++ objects passed between
it and another shared library are therefore made and destroyed by
different C++ runtimes, unless the app links the NDK's shared one (see
"One C++ runtime with other libraries"). Built to ship, add
`--config=android_release` (.bazelrc, examples/.bazelrc):

- `-c opt` and `-Osize`;
- `--gc-sections`, which drops the code the JNI entry points don't reach
  (`--@isomer//swift_ffi/rules:jni_exports_only`);
- the symbol tables stripped (`--strip-all`), and no Swift module embedded
  for the debugger (`swift.no_embed_debug_module`, the `.swift_ast`
  section).

To build one of the app's libraries alone for Android (to look at its
archive or its module), name Isomer's platform:
`--platforms=@isomer//platforms:android_arm64` (or `:android_x86_64`).

The Storybook (every story of the SwiftUI API, the Isomer module, the map
engine and FlatBuffers), measured at 0.42: 34.5 MB at `-c opt` (24,116
exported symbols), 16.2 MB with `--config=android_release` (46, all JNI),
in a 15.6 MB APK. Link-time optimization is not part of it yet.

**Dex in debug builds.** Without shrinking, an APK dexes every class of
what it links: Isomer's Android runtime brings Compose (runtime, ui,
foundation, Material 3 and the Material icons Material 3 1.3 depends on),
AndroidX's activity, fragment and lifecycle, and Kotlin's coroutines. The
Storybook's debug APK at 0.57: 22.8 MB of dex in two files, 13,667 classes.
On Android 6 (API 23) the whole dex is compiled to native code when the app
is installed, so a small emulator needs about 0.5 GB free for each such app;
without it dex2oat fails, and ART interprets the app (seconds per keystroke
in a text field). Later Android versions compile in the background, from a
profile. `isomer_android_app(..., minify = True)` runs R8 over the debug
build too: only what the app's Kotlin, the runtime and the libraries' own
consumer rules reach is dexed, Isomer's runtime and the bindings (which JNI
finds by name) kept whole, nothing renamed. The Storybook with it: 3.1 MB
of dex, 3,450 classes, a 16.5 MB APK instead of 23.3 MB, for about 15 s of
R8 per build. An app with its own Proguard rules, or a release build,
gives them to its android_binary's `proguard_specs` as usual (the keep
rules `minify` writes are the three lines in android/module/defs.bzl).

### One C++ runtime with other libraries

An app whose Swift calls C++ in another shared library (a prebuilt `.so`
built with the NDK's `c++_shared`) passes C++ objects across the boundary:
a `std::string` or `std::vector` made on one side and freed on the other,
a `shared_ptr` held by both, an exception thrown in one and caught in the
other, `dynamic_cast` and `typeid` on the other's types. With libc++
linked statically into the app's library, as by default, each side has
its own C++ runtime, and those don't work across it. The NDK's rule is
that every library sharing C++ across `.so` boundaries uses
`libc++_shared.so`, one copy in the process. To link the app's library
that way:

```starlark
isomer_android_app(
    name = "my_app",
    swift_library = ":app_swift",
    package = "com.example.myapp",
    libcxx = "shared",
    extra_binary_deps = [":vendor_cxx"],  # e.g. cc_library(srcs = ["libvendor.so"])
)
```

- The app's library (`lib<app>_runtime_bindings.so`) is linked without
  the NDK toolchain's static libc++ (`libc++_static.a`, `libc++abi.a`,
  its `static_link_cpp_runtimes` feature) and against the NDK's
  `libc++_shared.so`: it needs it (DT_NEEDED) and defines none of it. The
  Swift runtime's C++, the app's own C++ and Swift's C++ interoperability
  (`-lc++`) all take libc++ from it.
- The APK ships that `libc++_shared.so` in lib/<abi>/, from the NDK the
  app was linked with (hermetic_android_toolchains' NDK r30): ship no
  other copy. The prebuilt library must be built with the same NDK and
  `c++_shared` (`-DANDROID_STL=c++_shared` with CMake,
  `APP_STL := c++_shared` with ndk-build).
- `libcxx = "static"` keeps libc++ inside, as by default; without the
  attribute, `--@isomer//swift_ffi/rules:libcxx=shared|static` decides
  for every JNI library in the build (`static` by default), and for the
  shared platform library (`--@isomer//tools/android:shared_platform`,
  below), which follows only the flag. An app's `libcxx = "shared"` with a
  static platform leaves libc++ inside the platform, local to it: fine
  while the platform's code shares no C++ objects with the other library.
- `isomer_android_aar` follows the flag (`--@isomer//swift_ffi/rules:libcxx=shared`)
  and leaves `libc++_shared.so` out of its jni/<abi>/: the host app ships
  it, the one its own C++ libraries use, from the same NDK or a newer one
  (a newer libc++ keeps what an older one exported).
  A host with no C++ of its own adds
  `--@isomer//tools/android:aar_libcxx_shared` to have the AAR carry it.
- A JNI library built with swift_ffi's `kt_swift_library` directly takes
  `libcxx` too; its android_binary then lists
  `@isomer//swift_ffi/rules:cxx_runtime_shared` among its deps (or
  `:cxx_runtime`, which follows the flag) for `libc++_shared.so`.

The JNI exports and `--config=android_release` are as above: the library
still exports only its JNI entry points. The examples'
//tests/android_libcxx_shared checks an app built so (an APK holding
`libc++_shared.so`, the app's library needing it and defining none of the
symbols it exports), with the NDK's llvm-objdump and llvm-nm.

### Native libraries from a feature split

The generated Kotlin bindings load their library through
`swiftffi.NativeLibraries` (swift_ffi's Kotlin runtime): `System.loadLibrary`
by default. When the Swift library ships in an on-demand Play feature
module, which the base ClassLoader's lookup doesn't see, install a loader
(or load it yourself and mark it loaded) before any Isomer class runs:

```kotlin
swiftffi.NativeLibraries.loader = { name -> SplitInstallHelper.loadLibrary(context, name) }
// or, having loaded it:
swiftffi.NativeLibraries.markLoaded("app_runtime_bindings")
```

### One platform library for several apps

By default an app's Swift is one library holding everything: the Swift
runtime, Foundation, Isomer and the app. With
`--@isomer//tools/android:shared_platform` the same sources link in two:

- `libisomer_platform.so` (//android/libraries/swift_ui:isomer_platform):
  the Swift runtime and standard library, Foundation, SwiftUI and the rest
  of Isomer's SDK, linked once and every symbol exported;
- `lib<app>_runtime_bindings.so`: the app's own code, its services and the
  JNI glue, which needs the platform (DT_NEEDED) and holds none of it.

Both go in the APK (or the AAR), and the generated Kotlin loads the platform
first (through `swiftffi.NativeLibraries`, so a feature split's loader is
asked for both, in that order). Several Isomer apps or features in one host
then share one runtime and one copy of Isomer, and changing an app relinks
only its small library. The two libraries must come from one build of
isomer, since the app's library links against that platform exactly.
An app (or `isomer_android_library`, `isomer_android_aar`) whose
`shared_platform = True` links against the platform and ships it whatever
the flag says: one that takes a prebuilt library linked against the
platform needs it (below, "Prebuilt Swift libraries").

The Storybook, measured at 0.42 with `--config=android_release`: the
platform 19.8 MB and the app's library 0.6 MB (16.7 MB APK), against
16.2 MB as one library (15.6 MB APK). A shipped app that is alone in its
process is smallest as one library, where the linker can drop whatever the
app doesn't reach.

Underneath, these are swift_ffi rules: `kt_swift_platform` (a shared
library of Swift libraries, exported whole) and `kt_swift_library(...,
shared_platform = ..., shared_platform_when = ...)` (a JNI library linked
against it, leaving out every archive the platform holds). Swift's Android
toolchain links shared objects with `-Wl,--exclude-libs,ALL`, which no
version script can undo, so the platform is linked without that flag
(swift_ffi/rules/shared_platform.bzl). The runtime reaches the app's `@main`
through a registration made as the app's library loads
(android/libraries/swift_ui/application_main.c), since a platform loaded
first can't find it by name.

### Prebuilt Swift libraries

A Swift library that uses Isomer's Swift (Foundation, SwiftUI, the Isomer
module) and that an app takes prebuilt, as files, rather than from source,
ships one of two ways (docs/prebuilt_swift_libraries.md):

- **over the shared platform**: `lib<name>.so` linked against
  `libisomer_platform.so` (`isomer_android_shared_library`), each module's
  `.swiftmodule` and `.swiftinterface` beside it; the app sets
  `shared_platform = True`, takes the module with a `swift_import` (a
  `cc_import` of the `.so` beneath it)
  and ships the `.so` in `extra_binary_deps`. One runtime and one Isomer
  serve both libraries.
- **as a static archive and a `.swiftinterface`**: the library's
  `swift_library` built with `library_evolution = True`; the app's
  `swift_import(archives = ..., swiftmodule = ..., deps = [Isomer's
  targets])` links the archive into its one library (the `.swiftmodule`:
  rules_swift 4.2.2 compiles a `.swiftinterface` for Android without the
  Swift SDK).

Either way the library is bound to the isomer version, the Swift toolchain
and the Isomer build settings it was built with, which the app must share:
Isomer's modules, and Swift's own ABI off Apple's platforms, have no
binary compatibility across versions, and a mismatch fails the link or
the load at best, and corrupts memory at worst. The examples'
//tests/prebuilt_swift_library builds a library both ways and checks the
apps that take it.

### Embedding an Isomer app in an Android app

`isomer_android_aar` (android/module/defs.bzl) builds the app
`isomer_android_app` would make an APK of as an Android library,
`<name>.aar`, for an app with its own Gradle or Bazel build to embed
(examples' `//android/storybook_android_application:storybook_android_aar`):

```starlark
isomer_android_aar(
    name = "my_app_aar",
    swift_library = ":app_swift",
    package = "com.example.myapp",
    process = ":isomer",              # optional: the entry activity's process
    min_sdk_version = 28,
    services_kt = "AppServices.kt",   # optional, as isomer_android_app's
    services_installer = "com.example.myapp.AppServices.install()",
    services_deps = ["@host//sdk"],   # optional: what the services compile against
    provided_deps = ["@host//sdk"],   # optional: the host's, left out of classes.jar
    assets = [":flat_assets"],        # optional, as isomer_android_app's
    fonts = ["//fonts"],
    resources = glob(["Resources/**"]),
    extra_native_libs = ["@host//native:prebuilt"],  # optional: more of jni/
    tags = ["manual"],                # and testonly, target_compatible_with, …
)
```

- **classes.jar**: the app's classes, Isomer's runtime (`dev.isomer.**`)
  and the generated bindings (`swiftffi.**`), with no R classes (the host's
  build makes its own; Isomer declares no resources) and none of what the
  host supplies: the jars of any repository named for Maven, rules_kotlin
  or rules_android (AndroidX, Compose, Kotlin; `provided_by_name = False`
  turns that off), `provided_deps` and everything beneath them, and
  neverlink libraries (which Bazel never packs).
- **jni/arm64-v8a/**: the app's Swift, one library; build the AAR with
  `--config=android_release` to ship it (see "Android release size").
  Beside it `extra_native_libs`, as `isomer_android_app`'s
  `extra_binary_deps` put them in its APK: .so files, `cc_binary(linkshared
  = True)` targets or `cc_library` targets over prebuilt .so files, built
  for arm64.
- **assets/**: `assets`, `fonts` (in assets/fonts/, for `Font.custom`) and
  `resources` (in assets/bundle/, Bundle.main's), laid out as
  `isomer_android_app`'s APK has them. The host's build merges them into
  its own assets/, so two embedded Isomer apps share one fonts/ and one
  bundle/.
- **AndroidManifest.xml**: the entry activity, `<package>.MainActivity`, not
  exported and with no launcher entry, in `process` when one is given; the
  INTERNET and ACCESS_NETWORK_STATE permissions Foundation's networking
  needs. No `<application>` class: Isomer needs none, each entry prepares
  the runtime itself.
- **proguard.txt**: consumer rules keeping the classes JNI finds by name
  (`dev.isomer.**`, `swiftffi.**`, the app's package).

The host starts the app with an explicit intent
(`startActivity(Intent(context, com.example.myapp.MainActivity::class.java))`),
or hosts it in its own activity: the `Isomer()` composable (in a
`ComposeView` or `setContent`) or `IsomerFragment`, after calling
`IsomerRuntime.prepare(context)` and the services installer, as the
generated activity does. A process of its own (`process = ":isomer"`)
keeps the Swift runtime, its memory and its main-actor work out of the
host's process; the activity's process ends with it.

The host supplies AndroidX, Compose and Kotlin. Isomer's runtime is built
against Compose 1.7.8 (foundation, ui, runtime), Material 3 1.3.2,
activity-compose 1.9.3, fragment 1.8.5, lifecycle 2.8.7 and Kotlin 2.2
(its Compose compiler plugin 2.2.21): those versions or later. Compose
keeps binary compatibility for its stable API across 1.x, so a host on a
later Compose (1.12) resolves to its own; Isomer's CI does not yet run
the AAR inside such a host. The runtime's Kotlin also compiles against a
later Compose (an app's own set, docs/android_maven.md): its use of
`SuspendingPointerInputModifierNode.pointerInputHandler`, which Compose 1.12
deprecates at ERROR level for a replacement 1.7 lacks, is suppressed. The
host also supplies ProfileInstaller's concurrent-futures and Guava's
`ListenableFuture`, and on Material 3 1.4 or later material-icons-core
(docs/android_maven.md).

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
  * swift.org **Swift 6.4.2** toolchain (`.pkg`, extracted with `pkgutil`)
  * official **WebAssembly** and **Android** Swift SDK artifact bundles
  * Android **NDK r30**, **build-tools 35**, platform **android-35** jar,
    **platform-tools** (adb), **emulator** + ATD arm64 system image
  * **Temurin JDK 21**, **Kotlin 2.1.20** compiler, **Electron v42**

The first build downloads several GB; later builds are incremental.

## Testing

```sh
bazel test //...            # framework: snapshot + renderer unit tests
cd examples && bazel test //...   # integration: WASI checks, engine conformance, networking DI
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

### Frames: what each one built and diffed

`ISO_RENDER_LOG` in an app's environment logs a line per frame through the
host (logcat's `Isomer` tag on Android, the console on the web, standard
error elsewhere), with no profiler:

```
[render] frame 7 partial (SecureFieldStory) | written 1 | built 1 | diffed 51 nodes, 2 ops | events text | 3.9 ms
```

the frame built in place (only the views reading what changed:
shared/swift_ui_core/InPlace.swift) or whole (and why), the state written
since the frame before, the composite views built, the nodes the
component-system renderer's encoder compared and the patch operations it
sent, and the host's events that asked for it ("text" a field's edit,
"tap", "geo" a geometry report). A run of frames with nothing written is a
render loop, and its events say what keeps asking. `ISO_FRAME_LOG` adds,
per frame, which views were built and why. On Android they are the launch
intent's extras (`am start … --es ISO_RENDER_LOG 1`), on the web the page's
query (`?ISO_RENDER_LOG=1`); any host whose `hostValue("env:…")` isn't its
own reads the process's environment. Tests read the same counts from
`Runtime.frameStats`, `renderedFrameCount` and `wholeFrameCount`.

A keystroke in a field is one frame, built in place: the Storybook's
TextField story on Android at 0.58 builds no view (the field shows its own
text) and diffs 52 of its nodes, where 0.57 built the page's 107 views and
diffed all of it (a filled shape on the page made every frame whole).

Measure with an optimized build (`-c opt`): a debug build's frames and
start-up are several times slower, and say little about a release's.

**Views built every frame.** `ISO_FRAME_LOG` says why each view built was
not reused. Two reasons are the app's to change:

- `uncomparable`: the view stores a value that can't be compared with
  last frame's, most often a closure (a button's action, a callback passed
  down), or a class instance that isn't an `@Observable` model. Isomer
  compares a view's stored properties as SwiftUI does (Equatable values by
  `==`, other structs field by field) and can't tell whether two closures do
  the same thing, so such a view is built again whenever the view around it
  is. The views inside it can still be reused. Keep closures out of the
  views that are built often, or make them comparable:
  - pass an identifier and take the handler from the environment
    (`@Environment(\.openChat) var openChat`, then `openChat(chat.id)`),
    so the view stores only the identifier;
  - wrap the action in an `Equatable` type whose equality is what it acts
    on: `struct Action: Equatable { let id: Chat.ID; let run: (Chat.ID) ->
    Void; static func == (a: Self, b: Self) -> Bool { a.id == b.id } }`;
  - or keep the state the closure would change in an `@Observable` model
    the view holds, and call its method.
- `volatile`: the view's own build read runtime state (a control reading
  its binding, an `@AppStorage`, a value animating). It is built again
  every frame, alone, the rest of the frame built in place; a large view
  that is volatile costs its whole build each frame, so keep what reads
  runtime state in small views of its own. A transform animating (a
  `.rotationEffect`, `.scaleEffect`, `.offset` or `.position` with an
  animation, a spinner's) builds nothing: its node is moved where it stands.

### Headless, and on a server

An app built with `--@isomer//headless` runs with nothing drawn, its UI read
and used through the runtime: tests drive it in seconds
([docs/headless.md](docs/headless.md)). The same build serves the app to a
client that holds only a renderer (a browser's DOM renderer, an Android phone's
Compose) over a WebSocket or gRPC, its frames as protobuf patches of the
render tree ([docs/remote_sessions.md](docs/remote_sessions.md)). The `isomer`
CLI and the tests drive an app headless or headful, here or on another
machine, over gRPC, WebSockets or a Unix socket
([docs/drive.md](docs/drive.md)):

```sh
cd examples
bazel test --@isomer//headless //headless/... //remote/...
```

## Repository layout

```
swift_ffi/            Swift <-> Kotlin/TypeScript/C bindings: macros, analyzer,
                      generator, Bazel rules, runtimes (and its own examples)
core_graphics/        Isomer's CoreGraphics (Linux, Windows; the Swift SDKs'
                      on wasm and Android)
foundation/           Foundation's build settings and tests (Isomer's
                      Foundation is in Isomer's Swift SDKs:
                      AttilaTheFun/isomer_hermetic_toolchains)
metal/                Isomer's Metal: the API, the MSL→WGSL translator, the
                      WebGPU backend and its JS executor
swift_gpu/            the GPU abstraction: Metal (Apple's and Isomer's),
                      OpenGL (ES), Direct3D
swift_map/            the OpenStreetMap renderer behind `Map`
examples/             the example applications: a Bazel module of their own,
                      consuming this one as an outside application does
apple/module/         isomer_apple, the module of the iPhone's and the Mac's
                      apps (rules_apple; isomer_application's IOS, MACOS)
android/module/       isomer_android, the module of Android's macros and
                      rules (rules_android, rules_kotlin; ANDROID)
android/maven_module/ isomer_android_maven, Isomer's AndroidX
shared/
  swift_ui_core/      SwiftUI reimplementation (platform-agnostic): views,
                      ViewBuilder, @State via Mirror reflection, layout
                      engine, draw-list runtime, HostBridge protocol
  example_application/   the full SwiftUI app source used by all targets
  embedded_example/      the SwiftUI card the partial examples embed
wasm/
  libraries/swift_ui/ module `SwiftUI` for wasm (core + wasm host bridge),
                      module `IsomerBridge`, JS runtime (WASI shim,
                      WebGPU + DOM renderers, embed APIs, boot glue)
web/
  applications/example_{full|partial}_{react|webgpu}_web_application/
                      per-app wasm binary + static site + dev server
electron/
  applications/       the shared shell (main.js/package.json) + the same
                      four sites in hermetic Electron desktop windows
apple/
  libraries/swift_ui/ re-export of system SwiftUI + IsomerBridge (native)
  applications/storybook_macos_application/  (rules_apple)
  applications/storybook_ios_application/    -> iOS simulator
android/
  libraries/swift_ui/ module `SwiftUI` for Android (core + JNI host bridge,
                      written in Swift against jni.h), IsomerBridge, and
                      the Kotlin runtime (dev.isomer.runtime: GL view,
                      Compose interpreter, embed surfaces)
  applications/example_{full|partial}_{compiled|wasm}_android_application/
windows/
  libraries/swift_ui/ module `SwiftUI` for Windows (core + Direct2D host
                      bridge), IsomerBridge, C++ renderer (renderer.cpp)
  applications/storybook_windows_application/  (built on Windows)
linux/
  libraries/swift_ui/ module `SwiftUI` for Linux (core + SDL2/OpenGL host
                      bridge), IsomerBridge, C renderer (renderer.c) +
                      vendored stb_image + embedded WebKitGTK (webview_linux.c)
  applications/storybook_linux_application/  (built on Linux)
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

`//examples/windows/storybook_windows_application` is a **native** Windows app: the
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
Direct3D 11, running an `example_full.wasm` reactor under the WasmKit
interpreter instead of compiled-in Swift — plus cross-platform hot reload. See
[windows/README.md](windows/README.md) for how to run both cells.

### Native Linux target

`//examples/linux/storybook_linux_application` is a **native** Linux app: the same
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
running an `example_full.wasm` reactor under the WasmKit interpreter instead
of compiled-in Swift — plus cross-platform hot reload. See
[linux/README.md](linux/README.md) for how to run both cells.
