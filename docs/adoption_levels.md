# The four adoption levels

Isomer is the top of a stack you can step onto at any rung. Each level
trades control for convenience; each is useful on its own.

## Level 1 — rules_swift: Swift *runs* on your platform

[rules_swift](https://github.com/bazelbuild/rules_swift)'s Swift-SDK
toolchains cross-compile plain `swift_library`/`swift_binary` targets to
wasm32 and Android (see `//tools/platforms`). No interop niceties: you call
Swift through raw JNI, wasm exports, or C functions, and marshal everything
yourself.

Use it when you're building your own abstractions or need maximum control.

## Level 2 — swift_ffi: Swift is *easy* on your platform

[swift_ffi](../swift_ffi/) generates idiomatic
bindings around annotated Swift: `@ExportedFunction`/`@ExportedInterface`
become real Kotlin objects/interfaces (JNI underneath) and TypeScript
modules (wasm underneath), with strings/structs/async/`Result` crossing the
boundary as values. You pay a bit of marshaling overhead to get interfaces
each side would have written by hand.

Use it to share business logic, or to build higher-level systems — Isomer
itself is a swift_ffi consumer (`WebHost`/`AndroidHost` +
`isoStart`/`nativeStart` are its entire FFI surface).

## Level 3 — embedded Isomer: one SwiftUI feature in your app

The platform equivalent of `UIHostingController`: drop a SwiftUI surface
into an app you already have. The Swift side decides what renders (its
`@main App`, or whatever `IsomerHostingController(rootView:)`
installs); the host owns the screen around it.

| Host | Embed with | Example |
| --- | --- | --- |
| Jetpack Compose (compiled Swift) | `Isomer(modifier)` composable | `//examples/android/example_partial_compiled_android_application` |
| Jetpack Compose (wasm bundle) | `WasmView(provider)` composable | `//examples/android/example_partial_wasm_android_application` |
| React | `<Isomer wasmURL renderer />` (`runtime/react_embed.js`) | `//examples/web/example_partial_react_web_application` |
| Any web page | `mountIsomer(container, { renderer })` | `//examples/web/example_partial_webgpu_web_application` |

```kotlin
// Android (Compose host) — the card's contents are SwiftUI:
Card { Isomer(Modifier.height(340.dp)) }
```

```js
// Web (React host):
root.render(React.createElement(Isomer, { wasmURL: "./app.wasm", renderer: "react" }));
```

Build the embeddable pieces with `isomer_android_library`
(tools/android/defs.bzl) or `isomer_web_app` (tools/wasm/defs.bzl)
around a `swift_library` holding your SwiftUI code. Embedded surfaces
forward the host lifecycle to `@Environment(\.scenePhase)` but never
reconfigure the host's window/page (no title changes).

## Level 4 — Isomer app: your whole app is SwiftUI

Port of the SwiftUI `App` protocol: write `@main struct MyApp: App` once and
the platform entry points are *generated* —
`isomer_android_app` emits the `MainActivity` + `AndroidManifest`,
`isomer_web_app` wraps a one-page `index.html`. Platform APIs map to
their SwiftUI analogs:

| Platform event | SwiftUI surface |
| --- | --- |
| Activity onResume/onPause/onStop, page visibility | `@Environment(\.scenePhase)` + `.onChange` |
| `VIEW` intent data (`url_scheme = "iso"`), launch URL, `iso:openurl` event | `.onOpenURL { url in }` |
| Window/document/task title | `WindowGroup("Title") { … }` |
| System back (Android) | navigation pop / sheet dismissal |

Platform-specific behaviors keep a SwiftUI shape — modifiers that no-op
everywhere else, riding a generic `platformCommand(key, value)` host
channel:

```swift
content
    .androidStatusBarStyle(dark: true)
    .androidKeepScreenOn()
    .webDocumentTitle("Dashboard — Acme")
    .platformCommand("myCustomKey", "value", on: .android)  // escape hatch
```

The full example (`example_full_*_application` per platform: compose/opengl
on Android, react/webgpu on web and Electron, native on Apple) is a Level 4 app; both renderers of each platform (Material 3
Compose / React component systems, SwiftGPU-drawn OpenGL / WebGPU,
docs/renderer_layers.md) run the same `@main App`.
