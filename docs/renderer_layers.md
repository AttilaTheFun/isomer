# Pluggable renderers

A renderer takes the resolved `RenderNode` tree and figures out how to
visualize it. Every renderer implements the same API, defined in
`shared/swift_ui_core/Renderer.swift`:

```swift
public protocol TreeRenderer: AnyObject {
    /// Visualize the resolved view tree (called on every rendered frame).
    func render(tree: RenderNode)
}
```

That is the whole API: the core builds ONE canonical tree (chrome as
semantic host-view nodes) per frame and hands it over — it neither knows nor
can ask what kind of renderer is bound. The platform bridge constructs a
concrete renderer and installs it with `Renderer.bind(_:)` before
`Runtime.start`; the concrete renderers live in `shared/renderers/`
(pluggable — outside the core), and `tests/renderer` exercises the contract
with a `MockRenderer`.

On the self-drawing path, `Runtime.drawTree` expands the semantic chrome
nodes into their drawn implementations before layout
(`shared/swift_ui_core/ChromeExpansion.swift`): nav/tab bars, search
fields, toggles, pickers, menus, date pickers, media placeholders, and
SVG/GIF images all round-trip through the same specs the component systems
consume. Every host pumps frames (`scheduleRender` →
requestAnimationFrame / Choreographer / GL continuation), so transitions
and implicit animations run identically under every renderer.

## The renderers

**Component-system renderers** serialize the logical tree (stacks, text,
buttons, images, lists — with modifiers, before layout) to JSON and hand it
to a native counterpart, which owns layout and drawing with its component
library. Events (taps, edits) come back by node id through the existing
event exports; state changes produce a new tree. They all subclass
`ComponentSystemRenderer`, which takes the `send` closure that delivers the
JSON:

```swift
Renderer.bind(ReactRenderer { webHost?.renderTree(treeJSON: $0) })          // web
Renderer.bind(JetpackComposeRenderer { androidHost?.renderTree(treeJSON: $0) }) // android
// SwiftUIRenderer (real SwiftUI on Apple platforms, e.g. driven from wasm)
// is the same shape.
```

**`SwiftGPURenderer`** renders everything in Swift through SwiftGPU: it asks
the runtime for the layout+draw walk (`Runtime.drawTree`), implements the
drawing half of `HostBridge` itself (SDF rects, host-rasterized text/
gradients/shadows/images as textures, scissor clips), and forwards the
services half (measurement, rasterization, IME, files, host views) to the
platform bridge it wraps. The pluggable *GPU backends* (Metal, WebGPU,
OpenGL ES, …) live one layer down, in swift_gpu — isomer only picks
the surface:

```swift
let renderer = SwiftGPURenderer(services: WasmHostBridge(), surface: surface)
Renderer.bind(renderer)
Runtime.shared.start(host: renderer, ...)
```

`SwiftGPURenderer` is the **only** self-drawing renderer. The former
`HostDrawnRenderer` (a host-rasterizer fallback that ran the same
layout+draw walk but emitted the draw list through the platform
`HostBridge`) has been removed — every self-drawing platform links
swift_gpu. The initial/default binding is the core-private `NullRenderer`
(logs once), so a platform that forgets to bind is loud, not a crash.

Custom renderers: conform to `TreeRenderer` directly (self-drawing), or
subclass `ComponentSystemRenderer` with your own `send`, and `Renderer.bind`
it. Isomer itself keeps at most two per platform (2026-10-15): SwiftUI
and Metal on Apple, Compose and OpenGL on Android, React and WebGPU on the
web, DirectX on Windows and OpenGL on Linux.

## Mechanics

- `shared/swift_ui_core/Renderer.swift`: the `TreeRenderer` protocol,
  `ComponentSystemRenderer` + the concrete subclasses,
  `Renderer.bind`/`current`/`usesNativeComponents`/`usesDrawnChrome`, and
  `TreeSerializer` (RenderNode → JSON: kind, props, children, stable node
  ids derived from structural paths; `tapAction`/`onChange` registered in an
  id→closure table the event exports dispatch into).
- `Runtime.renderFrame()` resolves views into the `RenderNode` tree and
  calls `Renderer.current.render(tree:)`. Component-system renderers
  serialize via `Runtime.serializedTree(root:)` (then
  `fireTreeAppearances()`); self-drawing renderers call
  `Runtime.drawTree(root:)` for the layout + draw walk.
- Platform wiring: the host bridges have a `renderTree(treeJSON: String)`
  method on their swift_ffi host interfaces; each consumer implements it
  (React interpreter in boot.js, Compose interpreter in Kotlin). The
  renderer is chosen by the consumer at start (the `renderer: String`
  parameter of `isoStart`/`nativeStart`).
- `Renderer.usesDrawnChrome` (= `!usesNativeComponents`): self-drawing
  renderers draw *all* chrome (nav/tab bars, search fields, pickers, press
  feedback) into the display list so every GPU backend looks and feels the
  same; component-system renderers get the chrome as tree nodes and build
  it from their platform's native components instead.

## Run targets (macOS)

Component-system renderers are the default run targets; each has a
SwiftGPU-drawn twin:

```sh
bazel run //examples/web/example_full_react_web_application            # React (browser)
bazel run //examples/web/example_full_webgpu_web_application           # SwiftGPU/WebGPU (browser)
bazel run //examples/electron/example_full_react_electron_application  # React (Electron)
bazel run //examples/electron/example_full_webgpu_electron_application # SwiftGPU/WebGPU (Electron)
bazel run //examples/android/example_full_compiled_android_application # Jetpack Compose (emulator)
```

On Android, Compose is the only supported app renderer. The self-drawing
SwiftGPU/OpenGL-ES renderer still builds and runs as a library (launch any
Android app with `--es renderer openGL`), but it is deliberately not wired as
an example run target — see [adoption_levels.md](adoption_levels.md).

## Status / verification

| Renderer | Platform | Status |
| --- | --- | --- |
| SwiftGPURenderer (WebGPU backend) | web | verified headless via CDP |
| SwiftGPURenderer (OpenGL ES backend) | android | verified on emulator |
| SwiftGPURenderer (OpenGL backend, SDL2 window) | linux | verified on a Linux host (WSL/Mesa): catalog + real SwiftMap tiles |
| SwiftGPURenderer (D3D11 backend) | windows | verified on a Windows host: catalog + real SwiftMap tiles; SwiftGPU is required (no host-drawn fallback) |
| ReactRenderer | web | web-native components (inputs/selects/modals), verified headless via CDP |
| JetpackComposeRenderer | android | Material 3 (TopAppBar/NavigationBar/Switch/DropdownMenu/ModalBottomSheet), verified on the emulator |
| SwiftUIRenderer | apple | real SwiftUI (`IsomerTreeView`, //apple/libraries/swift_ui_tree); verified via the wasm hot-reload host (below) |

### Wasm hot-reload example (SwiftUIRenderer)

`//examples/apple/example_partial_wasm_macos_application` is a macOS host,
built once, that runs a demo app compiled to a wasm reactor under WasmKit
(vendored, macOS-only). The wasm binds `SwiftUIRenderer`, which serializes the
built tree to the tree.fbs FlatBuffer and ships the bytes to the host through a
slim `iso_hot` import ABI; the host decodes them with `IsomerTreeView` and
renders REAL SwiftUI. A file watcher rebuilds *only* the wasm when you edit
`//examples/wasm/hot_demo_feature/HotDemo.swift` and re-instantiates it live — the host process is
never rebuilt or relaunched.

```
bazel run //examples/apple/example_partial_wasm_macos_application
# then edit //examples/wasm/hot_demo_feature/HotDemo.swift and save — the window re-renders
```

An `example_partial_wasm_ios_application` runs the identical demo in the iOS
Simulator (WasmKit + IsomerTreeView build for iOS too). Because the iOS
sandbox can't spawn a compiler, it doesn't build — it fetches the wasm over
the network instead.

**Two-process hot reload.** A `hot_reload_server` (macOS CLI, run in its own
shell) watches `HotDemo.swift`, runs `bazel build …:hot_demo.wasm` on each
edit, and serves the bytes over localhost HTTP (`/version` + `/wasm`, a version
counter). Any app with `ISO_HOT_RELOAD_SERVER` set starts a `HotReloadClient`
that polls the version and re-`load(bytes:)`s the runner when it bumps. The
same server drives the macOS host, the iOS Simulator, and real devices (point
the env var at the Mac's LAN address) — none of them run a compiler, and there
is no filesystem-sharing assumption. The macOS host also has a built-in
watcher for a zero-config single-process run.

The React/Compose interpreters cover the node kinds the serializer emits
(box/text/stack/spacer/divider/scroll/image/textField/slider/gradient/
progress/shape) plus the semantic chrome host views (navbar/tabbar/search/
picker/menu/datepicker/toggle) and presentation layers (sheet/alert), so the
component-system apps match the drawn paths feature-for-feature while
feeling native to their platform (Material on Android, web-idiomatic on the
web). The self-drawing renderers draw all of that chrome themselves (docs/
renderer_parity_plan.md) — the only native bridges left are app-authored
representables and the invisible IME-capture text input.
