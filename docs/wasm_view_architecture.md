# WasmView: dynamically-delivered SwiftUI features

**Status: in progress.** This is the design + rollout plan for shipping
isomer features as WebAssembly bundles embedded in a native app — the
"Valdi/dynamic-delivery" model. Development already has hot reload
(the `example_wasm_view_*` hosts, hot-reload being an optional provider mode);
this productizes it.

The goal a feature team gets: write a SwiftUI feature against our
`swift_ui_core`, choose **compiled** (native, App-Store cadence) or **wasm**
(a bundle you can update out-of-band for bug fixes / optimizations), and in the
wasm case embed it with `WasmView(...)` anywhere in a native SwiftUI/UIKit
hierarchy — injecting native dependencies (networking, DB, custom native
views) that the wasm feature consumes.

Compliance note: interpreted/downloaded code that doesn't change the app's
primary purpose is permitted (Apple 3.3.2; precedent: Valdi/Snap, React
Native, Expo). New *features* still ship compiled through the store.

## The pieces

1. **`WasmView`** — a SwiftUI `View` that hosts one wasm feature instance and
   renders its emitted tree with `IsomerTreeView` (real SwiftUI) or, with
   `renderer: .gpu` (iOS), the self-drawing SwiftGPU renderer over Metal
   (`GPUTreeView`, `apple/libraries/gpu_tree_view` — it compiles the
   reimplementation core, so importers use a scoped
   `import class IsomerGPUTreeView.GPUTreeView`; one live instance at a
   time, the core's `Runtime.shared` being a process singleton).
   `WasmViewModel.onPatch` / `onPatchReset` hand the raw tree.fbs patches to
   a renderer that keeps its own retained tree. Embeds in SwiftUI or
   `UIHostingController`.
2. **`WasmRuntime`** — owns the WasmKit engine, instantiates bundles, and
   **caches/pre-warms instances** (instantiation cost). One shared runtime.
3. **`WasmBundleProvider`** — supplies bundle bytes: `BundledProvider`
   (in-app), `HotReloadClient` (dev), a signed-OTA provider (prod). The dev
   client is the reference implementation of the prod protocol.
4. **Dependency injection across the boundary (the core new capability)** —
   native Swift implementations injected into the wasm feature, consumed there
   for networking, storage, etc. Grounded in swift_ffi (below).
5. **Native-view bridging** — register a native SwiftUI `FooView` so a wasm
   feature can place it and have the native side render the real view.
6. **Bundle splitting** — pin shared Swift libraries (stdlib, `swift_ui_core`,
   the injected protocols) into an app-shipped runtime bundle, so per-feature
   bundles stay small. The hard part; see "Bundle splitting" below.

## Dependency injection = swift_ffi "foreign interfaces", native transport

The key insight: **swift_ffi already has this primitive, in the wrong
transport.** An `@ExportedInterface` is a protocol that can cross the boundary
in *both* directions. When a *consumer* implements the contract and passes it
into wasm-Swift, wasm-Swift calls back out through **wasm imports in module
`"swift_ffi"`** (that's why reactor builds pass
`-enable-experimental-feature Extern`). Today a JS/TS registry satisfies those
imports. We want a **native-Swift host, over WasmKit**, to satisfy them.

So a dependency is just a shared `@ExportedInterface`, implemented natively,
handed to the wasm feature as a foreign instance:

```swift
// shared/wasm_core (compiled into BOTH the app and every feature bundle)
@ExportedInterface
public protocol NetworkService {
    func get(url: String) -> Data          // (async variants per swift_ffi effects)
}

// native app
struct URLSessionNetwork: NetworkService { ... }        // real implementation

// feature bundle (wasm)
struct FeatureView: View {
    let net: NetworkService                              // injected; calls out via `swift_ffi` imports
}

// embedding
WasmView(bundle: .feature("profile"),
         dependencies: [ .service(NetworkService.self, URLSessionNetwork()) ])
```

**This transport is now built** — the native-Swift peer of the TS transport:

| Direction | swift_ffi mechanism | TS transport | Native/WasmKit transport (DONE) |
|---|---|---|---|
| Native → wasm export | `@ExportedFunction`, wasm exports `swift_ffi_*` | JS calls the export | `SwiftFFIWasmKitEngine.call` → `instance.exports[function:]` |
| Native impl → wasm (a dependency) | foreign `@ExportedInterface`, wasm imports `swift_ffi.*` | JS registry satisfies imports | **WasmKit `Imports` dispatch to the registered native Swift impl** |
| wasm impl → native (a service bundle) | `@ExportedFunction`/interface returned | JS wrapper calls exports | `Swift<Proto>` wrapper calls exports; the inverse of row 2 |
| strings / memory | `swift_ffi_alloc`/`dealloc`/`string_*` exports | TS module stages linear memory | `SwiftFFIHostRuntime` stages via the same exports |

It is a **new `swift-host-wasm` generator kind** (the peer of `emitTypeScript`,
in the swift_ffi repo) plus an **engine-agnostic `SwiftFFIWasmHost` runtime**;
`isomer` supplies the concrete `SwiftFFIWasmKitEngine`
(`//apple/libraries/wasm_view`). The generator emits `Swift<Proto>` wrappers, a
module facade, and the `swift_ffi` import table (foreign dispatchers) from the
same IR the TS transport uses, so it works for **arbitrary
`@ExportedInterface`s** — no longer a hand-written per-capability ABI. Verified
end-to-end by `//examples/apple/example_swift_ffi_host:host_test` (both
directions below). The hand-written `iso_host` capability ABI (Phase 2) still
serves the `WasmView` demo; this generator is the general replacement.
(Currently sync-only: async facade calls trap, its imports stubbed so
async-bearing reactors still instantiate.)

### Service bundles (the inverse) — also working

"Protocol defined in wasm-core, consumed by native, implemented in a wasm
dynamic bundle" is the same machinery with the roles swapped: an
`@ExportedFunction` returns an `@ExportedInterface` the wasm bundle implements;
the native host receives it as a `Swift<Proto>` wrapper over the boxed guest
instance and consumes it. The demo's `makeCounter()` → `SwiftCounter` proves
this. A `WasmServiceBundle` (a headless, view-less sibling of `WasmView` over
the same runtime) is the natural packaging, still to be added.

## Native-view bridging

The tree already carries `hostView` nodes (representables/native widgets) that
the native side materializes. Extend that into a **registry**: the app
registers `("FooView", (params) -> AnyView)` with the *non-dynamic* core
runtime; a feature places `HostView("FooView", params)`; `IsomerTreeView`
looks up the id and renders the real `FooView`. The same `FooView` symbol is
usable compiled (direct) and from wasm (by id) — the bundle only needs the
id + a param contract, not `FooView`'s code. Bridged views ship with the app,
never in a feature bundle.

## Bundle splitting (investigated 2026-07-08)

**What the bytes are.** A feature `.wasm` (the hot-reload demo) section
breakdown: `code` 52.6%, `name` 18.4%, `export` 15.8%, `data` 8.9%, debug
~0.4%. The `name`/debug sections strip in release; the `export` section is an
artifact of the dev reactor's `--export-all --no-gc-sections` (keeps every
symbol for hot reload). A production link (export only the `iso_hot`/`iso_host`
ABI + `--gc-sections` + strip, then `-c opt`) additionally dead-strips
unreferenced stdlib/core from `code`. Measured on the demo feature (targets
`hot_demo.wasm` / `hot_demo_release.wasm`, both verified by `hot_smoke`):

| Build | raw | gzip |
|---|---|---|
| dev (`--export-all --no-gc-sections`, fastbuild) | 14.1 MiB | 3.7 MiB |
| release flags (`--gc-sections`, ABI-only exports, `--strip-all`), fastbuild | 8.4 MiB | 2.5 MiB |
| release flags **+ `-c opt`** | 7.3 MiB | 2.1 MiB |

The residual is **Swift stdlib + `swift_ui_core`**, statically linked (no
OS-shared stdlib on wasm) — the fixed baseline the feature itself barely moves.
The demo's own code is a rounding error here; a second real feature re-pays
essentially the same ~2.1 MiB gzip baseline (the sharing problem below).

**Can we share that baseline across independently-updatable bundles?** That
needs **wasm dynamic linking**: an app-shipped runtime module (stdlib + core +
protocol glue) exporting its memory + symbols, and PIC "side-module" feature
bundles resolved against it at load (Emscripten `dylink.0` / GOT relocation).
Findings:
- **Linker: yes.** The toolchain's `wasm-ld` supports `--experimental-pic`,
  `--import-memory`, `--import-table`, `--export-dynamic`, `--growable-table`.
- **Runtime: no.** WasmKit (our vendored interpreter) has **no dynamic-linker
  runtime** — no `dylink.0` parsing, GOT.mem/GOT.func relocation, or `dlopen`.
  It instantiates one module against fixed imports.
- **Toolchain: no.** SwiftWasm does not ship the stdlib as a PIC side-module;
  building Swift as a wasm shared library is unsupported/experimental.

So true cross-bundle sharing is **not feasible on the current SwiftWasm +
WasmKit stack** without (a) SwiftWasm side-module support and (b) implementing
the dylink runtime in WasmKit (or swapping the interpreter, which forfeits the
pure-Swift/no-dep reason WasmKit was chosen).

**Recommendation (works today).**
1. **One shared app-wide bundle with internal routing** — ship a single wasm
   containing the shared runtime + all wasm-delivered features; route to a
   feature by id at load. Pays the stdlib+core baseline **once**. Trade-off:
   all wasm features update together (no per-feature independent delivery).
   Best default; matches how most dynamic-delivery systems actually ship.
2. **Self-contained per-feature bundles, release-built** (`--gc-sections`,
   ABI-only exports, `--strip-all`, `-c opt`): independent delivery, but each
   re-pays its DCE'd baseline (**~2.1 MiB gzip**, measured above). Fine for a
   handful of large features. **The `hot_demo_release.wasm` target implements
   exactly this link config** and `hot_smoke` confirms it still runs (the
   dependency-injection path survives `--gc-sections`).
3. **True dynamic linking** ("federated wasm modules" — share one runtime like
   C/C++/Rust do) — future work, gated on SwiftWasm side-modules + a WasmKit
   dylink runtime, neither of which exists today. Written up, with the exact
   blockers and why the Component Model doesn't substitute, in
   [future_direction.md](future_direction.md). No upstream tracking issue yet.

Concrete next steps: option 2's release link config is **done + verified**
(`hot_demo_release.wasm`); the remaining build-config work is a shared-bundle
router for option 1 (ship one wasm with all features, route by id at load).
Both are build-config + routing work, not new runtime mechanism.

## The swift_ffi native transport generator — DONE

Phases 2–3 hand-wrote the `iso_host` capability glue. The general version now
exists: the **`swift-host-wasm` generator kind** + engine-agnostic
**`SwiftFFIWasmHost` runtime** (swift_ffi repo, commit a2ae504) auto-wire
**arbitrary `@ExportedInterface`s** as injected deps and as service bundles,
from the same IR the TS transport uses. `isomer` supplies the WasmKit
engine (`SwiftFFIWasmKitEngine`, in `//apple/libraries/wasm_view`) and a
worked round-trip (`//examples/apple/example_swift_ffi_host`):

```swift
// wasm-core: a dependency the feature consumes, implemented natively
@ExportedInterface public protocol HostEnvironment { func flag(name: String) -> Bool; func now() -> Int }
@ExportedFunction public func renderBanner(using env: HostEnvironment) -> String { … }

// native host
struct NativeEnvironment: HostEnvironment { … }              // real impl
let bridge = try Service.load(engine: SwiftFFIWasmKitEngine(), wasm: bytes)
bridge.renderBanner(using: NativeEnvironment())              // wasm calls back into the native impl
let counter = bridge.makeCounter()                           // a wasm-implemented service, as a native handle
```

Remaining polish (not blocking): async facade calls (the marshalling for
`task_enqueue`/completion pumping — imports are currently stubbed so
async-bearing reactors still instantiate); a `swift_host_library` bazel macro
wrapping the reactor + host-binding + engine wiring the demo does by hand; and
a `WasmServiceBundle` packaging for the view-less service case.

## Instantiation cost

Parsing + instantiating ~12 MiB under WasmKit is not free, and each instance
owns its linear memory (16 MiB stack + heap). `WasmRuntime` therefore:
pre-warms the shared runtime at app launch; caches instances keyed by bundle
id + version; reuses across `WasmView` appear/disappear; drives each instance
on a single actor (`@MainActor`). Fresh state per feature = fresh Store.

## Lifecycle: multiple runtimes, teardown, shutdown

**Ownership.** `WasmView` owns (or is handed) a `WasmViewModel`; the model
owns a `WasmFeatureRuntime`; the feature runtime owns the engine instance
(`WasmRuntime`: WAMR, WasmKit, …), created per loaded bundle by an
injected factory — `WasmViewModel(runtime:)` takes it, defaulting to
`WasmRuntimeRegistry.make(for:)`. A host that wants to pick or configure
the engine per feature, or to hold the model so it can shut the feature
down before releasing the view, uses that initializer and the
`WasmView(model:…)` form.

**Several at once.** Every model has its own engine instance, linear
memory and dependency table, so independent features can run in separate
runtimes anywhere in the hierarchy without seeing each other. Shared native
services are just the same dependency objects passed to both tables; they
must tolerate concurrent callers. Verified by the Playground's
`testCoexistingRuns` probe (a full-screen user run beside the agent's
offscreen run).

**Teardown.** Releasing the view releases the model, which releases the
engine instance (WAMR: exec env, instance, module, swift_ffi host; a
refcount destroys the process-global WAMR runtime with the last instance).
Two rules keep that true: `WasmView` subscribes to bundle updates with
`.task`, so a provider whose stream never finishes cannot keep the model
alive; and closures stored on the model (`onLog`, status callbacks) must
capture values, never the SwiftUI view struct — its `StateObject` wrapper
holds the model, and model → closure → view → model never frees.
In-flight service completions after teardown are dropped (every entry
point checks for a live runtime).

**Graceful shutdown.** `model.shutdown(timeout:)` (async) asks the guest to
unwind first: `iso_hot_shutdown` cancels every task the framework started
for views (`.task {}` / `.task(id:)`), drops pending timers and stops
rendering; the host then keeps draining the guest job queue — where the
cancelled tasks actually run to completion — until `iso_hot_pending_tasks`
reports zero or the deadline passes, and releases the instance either way.
The outcome says which: `.graceful`, `.forced(pendingTasks:)` (something
awaited a service that never answered), or `.unsupported` (a reactor
built before the export existed — torn down immediately).
`forceShutdown()` skips straight to teardown. Wasm has no preemption, so a
guest spinning in synchronous code cannot be cancelled cooperatively; the
host thread is blocked in the call anyway.

**Memory per instance** (measured 2026-09-06 in the iPhone 17 Pro
simulator, phys_footprint of the Playground process, a 17.7 MB
unoptimized feature build with a 16 MiB guest stack):

| engine | before run | run loaded | after release |
| --- | --- | --- | --- |
| WAMR (interpreter) | 274 MB | 321 MB (+46) | 271 MB (baseline) |
| WAMR, second instance alive beside the first (`testCoexistingRuns`) | 323 MB | 406 MB | — |

(The second row's "before" already includes that build's compile and its
module load, so the two-live-runtimes total is ~130 MB over the idle app —
about what two single instances add up to; nothing is shared or saved
between instances beyond the process-global runtime.)

So one live instance of this feature costs ~46 MB under the WAMR
interpreter (module bytes + parsed structures + linear memory), all of it
returned after `shutdown` + release; repeated runs do not stack. A
release-built feature bundle is a few MB instead of 17.7, so
expect the instance cost to be dominated by linear memory (16 MiB stack +
heap) rather than code.

## Rollout

- **Phase 1 — DONE** (commit 716d4bf). Extracted the hot-reload WasmKit
  machinery into `//apple/libraries/wasm_view` (`IsomerWasmView`):
  `WasmRuntime`, `WasmBundleProvider` (+ `BundledWasmProvider`), `WasmView`.
  Both the `example_wasm_view_*` hosts (formerly `example_hot_reload_*`) consume it (`HotReloadClient`/`Poller` became
  providers). macOS + iOS build; `hot_smoke` passes.
- **Phase 2 — DONE** (commit 9498caa). Native dependency injection:
  `//wasm/libraries/host_services` (`IsoHostServices.Host`) — guest facade over
  `iso_host` wasm imports; `WasmFeatureHost` native protocol bound in
  `WasmRuntime`; `WasmView(host:)`. Demo injects a flag/analytics host; the
  feature renders a native-decided promo banner. Verified by smoke (flag
  round-trips into the tree) and on-screen.
- **Phase 3 — DONE** (commit a897a09). Native-view bridge registry
  (`BridgedViewRegistry`) + `BridgedView("id", …)`; demo bridges a native
  SF-Symbol badge the wasm core can't draw itself. Verified on-screen.
- **Phase 4 — DONE.** Two parts, both landed:
  - *Bundle splitting* — investigation complete (see "Bundle splitting"): true
    cross-bundle sharing is infeasible on SwiftWasm + WasmKit today, so the
    shippable answers are option 1 (shared router) or option 2 (self-contained
    release bundles). Option 2's release link config is implemented
    (`hot_demo_release.wasm`, ~2.1 MiB gzip) and smoke-verified.
  - *Native transport generator* — the `swift-host-wasm` generator kind +
    `SwiftFFIWasmHost` runtime (swift_ffi a2ae504) + `SwiftFFIWasmKitEngine`
    (isomer) auto-wire arbitrary `@ExportedInterface`s as injected deps
    and service bundles. Verified end-to-end by
    `//examples/apple/example_swift_ffi_host:host_test` (native impl injected
    into a wasm feature; wasm service consumed as a native handle). See "The
    swift_ffi native transport generator — DONE" above. Async marshalling +
    a `swift_host_library` macro are the remaining polish.

- **Phase 5 — productization (2026-07-08, in progress).**
  - *Async on the native host — DONE* (swift_ffi bb31f98). The `swift-host-wasm`
    facade bridges the wasm cooperative executor (`task_enqueue`/`task_run` +
    `async_<name>_complete`) to native Swift `async` via a synchronous pump.
    Verified: `example_swift_ffi_host` async round-trip.
  - *`swift_host_library` macro — DONE* (swift_ffi bb31f98). Wraps the reactor +
    host bindings; `example_swift_ffi_host` and `examples/apple/greeter_host`
    use it.
  - *BundleProvider + WasmServiceBundle — DONE* (10833b8). `BundleProvider`
    yields a synchronous initial bundle + an async stream of updates;
    `AppBundleProvider` serves the packaged wasm and shadows it with a dev
    hot-reload stream (env-gated). `WasmServiceBundle` = reactor + small
    co-versioned assets. Hot-reload sources moved into the library; both example
    apps migrated (hot-reload is now a provider mode).
  - *IntegrationMode / SwiftGPU-app-only — DONE* (280b7db).
    `TreeRenderer.supportedModes`; component-system renderers embed OR fill,
    `SwiftGPURenderer` is `[.app]`. `installRootView` (the
    `IsomerHostingController` embedded path) sets `.embedded`; `@main App`
    (`installApp`) stays `.app`; `Runtime.start` enforces it.
  - *Swap WasmView DI to the generalized transport — DONE* (8aa9aa6). The DI is
    now the swift_ffi transport, not the hand-written `iso_host` ABI.
    `//shared/platform_services` (formerly app_services) is a
    swift_ffi module — `@ExportedInterface`s (`KeychainService`,
    `AnalyticsService`, `ConfigurationService`, …; networking and files were
    services too until 0.31, when Foundation's URLSession and FileManager
    replaced them) + `installPlatformDependencies`, with
    `PlatformDependencies.<service>` the guest's accessors. It emits guest glue
    (linked into the reactor) and native bindings (used by `wasm_view`).
    `SwiftFFIWasmKitEngine.additionalImports` binds the reactor's `iso_hot`
    render callbacks alongside the swift_ffi DI imports in one instantiation;
    `WasmRuntime.load` instantiates via the generated host loader, installs
    the native services, and drives `iso_hot_*` through the engine. The old
    `host_services`/`iso_host` module is deleted. Verified by the rewritten
    `hot_smoke` (composed path). It was scoped after all — `iso_host` was only
    the WasmView feature-reactor DI, not shared with swift_ui_core or the
    self-drawing web/android bridges. **New host deps are just methods on the
    platform_services interfaces (async/throws allowed) — no bespoke glue.**
  - *Per-platform WasmView equivalents — DONE, compile-verified (#129).* One
    `WasmView` per platform that can run Swift-compiled-to-wasm:
    - **Apple** — `WasmView` (SwiftUI), the reference implementation.
    - **Web** — `<Isomer>` (React), over the existing TS transport, driven
      by a JS `BundleProvider` (`runtime/bundle_provider.js`).
    - **Android** — a Jetpack Compose `@Composable WasmView`
      (`//android/libraries/wasm_view`), running on **WAMR**, a tiny C
      WebAssembly interpreter, NOT WasmKit. This is deliberate: Android's "wasm"
      delivery cell must carry **no compiled Swift** (compiled-vs-wasm is an
      exclusive choice on Android; mixing is only free on Apple, where the Swift
      runtime ships in the OS). WasmKit is pure Swift, so it would drag the
      stdlib into the app — WAMR is C, so a wasm feature ships with zero Swift
      `.so`. The stack: `@WAMR` (vendored + patched in MODULE.bazel) →
      `//shared/wamr_host:iso_wamr` (a C host binding the `iso_hot` render ABI
      + WASI) → a JNI shim (`//android/libraries/wasm_view/jni`) → Kotlin
      `WamrRuntime`/`WamrHost` → the SAME Compose interpreter
      (`IsoNode`/`FlatTree`, now the Swift-free
      `//android/libraries/swift_ui:interpreter_kotlin`) draws the tree. A
      swappable `IsoEventRouter` routes node events to the reactor. The whole
      app is one `kt_android_library` + `android_binary` with **one native lib**
      (`libiso_wamr_jni.so`, ~344 KB) — verified on the hermetic emulator
      (renders + interactive). Dependency injection over WAMR goes through the
      swift_ffi C host runtime (`iso_wamr` binds the fixed `swift_ffi` imports;
      the app registers its dependency table — see `PlatformServicesWasm.kt`).
      *(WasmKit remains the Apple `WasmView` engine via `//shared/wasm_host`;
      the old WasmKit-on-Android bridge — `WasmHostBridge`,
      `isomer_wasm_android_library` — is superseded.)*

    Bundle **delivery** is per-platform (Apple `BundleProvider`/`AppBundleProvider`
    with URLSession; web `bundle_provider.js`; Android Kotlin
    `WasmBundleProvider`) — the shared core only takes a `WasmServiceBundle`'s
    bytes. On-device Android execution is not yet verified (no emulator in CI);
    known integration points: libdispatch main-queue draining on the Android
    Looper, and dual Swift-runtime `.so` co-load.
  - *WasmServiceBundle assets — guest API OPEN.* Assets are held per-instance
    (`WasmRuntime.assets`); a guest-facing asset service still to be exposed.

Current DI capability surface is minimal (`flag`/`track`, string-in /
scalar-or-void-out); the generalized transport (Phase 4) is where
networking/DB/storage land as `@ExportedInterface`s.

Presentation/navigation escaping the embedded frame is deferred — for now a
`WasmView`'s presentations render within its own bounds.
