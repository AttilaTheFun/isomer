# Plugging into the stack

Every layer of the stack exposes its variable half behind a protocol (or a
build flag) with a registration point, and the cores depend on none of the
implementations. What ships by default is one choice among peers — a host
app (or a third-party consumer) swaps any of these without forking:

| Seam | Level | Interface | Registration | Default |
| --- | --- | --- | --- | --- |
| wasm AOT compiler | swift_ffi (build) | wamrc-shaped CLI (`[flags] -o out in`) | `--@isomer//swift_ffi:wasm_aot_compiler=<label>` | wamrc |
| Wasm runtime | swift_ffi / isomer | `WasmRuntime` (launch/call/read/write) | `WasmRuntimeRegistry.register { … }` | WAMR |
| Bundle delivery | swift_ffi | `WasmBundleProvider` (initial + update stream) | pass to `IsomerView` / `WasmView` | `AppBundleProvider` |
| GPU device | swift_gpu | `GPUDevice` (+ `GPURenderPass`) | inject via the platform bridge / renderer surface | Metal / GLES / WebGPU |
| Renderer | isomer | `TreeRenderer` (`render(tree:)`) | `Renderer.bind(_:)` before `Runtime.start` | per-platform component system |

## Wasm AOT compiler (build-time label flag)

```
bazel build ... --@isomer//swift_ffi:wasm_aot_compiler=@my_toolchain//:compiler
```

The tool is invoked wamrc-style (`<tool> [flags] -o <out> <in.wasm>`); wrap a
different CLI in a shim script. The artifact must be loadable by the wasm
runtime the app links — compiler/runtime travel as a PAIR (wamrc `.aot` ↔
WAMR's AOT loader). The iOS embedded-XIP path stays wamrc-pinned (its
zero-relocation guarantee is wamrc-specific).

## Wasm runtime (four engines behind one seam)

```swift
WasmRuntimeRegistry.register { WamrRuntime() }      // the shipping default
WasmRuntimeRegistry.register { WasmKitRuntime() }   // WasmKit (Apple; threaded reactors)
WasmRuntimeRegistry.register { JSCRuntime() }       // JavaScriptCore's wasm
WasmRuntimeRegistry.register { WasmEdgeRuntime() }  // WasmEdge (macOS dev)
```

The core host (`//shared/wasm_host`) depends on NO engine; isomer's
Apple host registers WAMR via `registerDefault` (an app's own `register`
wins). An engine is ~200 lines: conform `WasmRuntime`, bind WASI + the
`iso_hot` imports — including the two trailing swiftcc context i32s every
SwiftWasm `@_extern(wasm)` import carries — and pass the conformance suite:

```
bazel test //tests/wasm_engines:wasm_engine_tests
```

which drives the real tap-counter reactor through launch → first frame →
tap → updated tree on every engine. Measured on an M-series MacBook (macOS,
same reactor, same suite):

| engine | startup | tap | notes |
| --- | --- | --- | --- |
| WAMR | 398 ms | 6.9 ms | fast interpreter — the shipping default |
| JSC | 562 ms | 5.4 ms | a JS runtime as the wasm runtime; JIT tiers |
| WasmEdge | **182 ms** | 8.4 ms | interpreter — fastest cold start |

JSC also runs the wasm feature on iOS (`ISO_JSC=1` in the IsomerView
demo). Device caveat: third-party iOS processes get no JIT pages, so JSC
executes wasm on its interpreter tier there; the simulator JITs like macOS.
WasmEdge is a macOS dev-only SDK drop (no iOS build exists).

## Bundle delivery

`WasmBundleProvider` (swift_ffi level: `WasmBundle` = reactor bytes + small
assets) yields a synchronous initial bundle plus an `AsyncStream` of
updates. `AppBundleProvider` implements packaged-resource + dev hot-reload;
a production dynamic-delivery provider implements the same two methods over
a download cache. `IsomerView(root:bundleProvider:)` renders compiled
Swift until the provider yields a bundle, then swaps to wasm live.

## GPU device

`GPUDevice` / `GPURenderPass` (swift_gpu/core) abstract the draw backend;
the core sources have no backend dependency, and each platform package
compiles core + its device (Metal, GLES, WebGPU) into its `SwiftGPU`
module. A third-party backend follows the same shape: implement `GPUDevice`
against `@isomer//swift_gpu/core:srcs` and hand the device to
`SwiftGPURenderer` through the renderer surface — the renderer never
constructs a device itself.

## Renderer

`TreeRenderer` is one method — `render(tree:)` over the resolved tree — plus
a supported-modes property. Component systems (SwiftUI/Compose/React) and
the self-drawing SwiftGPU renderer are all implementations;
`Renderer.bind(_:)` before `Runtime.start` is the whole registration. The
core (`//shared/swift_ui_core`) references no concrete renderer.
