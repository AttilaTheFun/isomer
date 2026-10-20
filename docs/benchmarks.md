# Benchmarks

Performance of the shared Isomer app across its delivery modes, and — via a
purpose-built, behavior-identical **"Tap me" counter** — head-to-head with
React Native and Valdi. Organized by **platform**; within each platform a table
covers every delivery mode / framework. **Blank** = not yet measured;
**N/A** = the combination isn't supported.

**Delivery modes** (Isomer):
- **native** — the platform's idiomatic native UI as a reference ceiling
- **compiled Swift** — the shared Swift app built to native (`.so`/`.dylib`/ELF),
  drawn by a component-system renderer (Compose on Android) or `SwiftGPURenderer`.
- **wasm AOT** — the *identical* app compiled to a `iso_hot` wasm reactor,
  lowered to a native `.aot` by wamrc and run under **WAMR**. The reactor emits
  the same `tree.fbs`, so the UI is pixel-identical to compiled; only how the
  app's own logic executes differs. Not iOS-deliverable (see the iOS footnotes).

(The WAMR fast-interp tier — what a dynamically delivered or hot-reloaded
reactor runs on, on iOS too — is not in the matrices: AOT beats it wherever
AOT is deliverable. Its last measured rows, same methodology: iOS 214 ms /
12.66 ms taps; Windows 421 ms; Linux 249 ms.)
(A "wasm pulley" tier, a wasmtime pulley64 data artifact, was measured here until wasmtime was removed in 0.35.)

**External frameworks** (for the cross-framework counter): **React Native**
(Hermes), **Valdi** (QuickJS on Android, JavaScriptCore on Apple), **Lynx**
(ByteDance; PrimJS/QuickJS), and **Flutter** (Dart AOT, self-drawn Impeller) —
real, standalone, behavior-identical counter apps, not their stock samples.
Build recipes live in each app's `README.md`.

The self-drawing SwiftGPU renderer is fully supported on mobile but no longer
benchmarked there (the component-system renderers beat it across the board);
it remains the — and the benchmarked — renderer on desktop.

---

## Android

**Device / method.** Pixel 3a (`sargo`, Android 12, arm64 — a 2019 budget
phone), release builds, DEVICE-DEFAULT settings (no animation-scale or
refresh-rate overrides — both metrics measure app-owned work, so display
pacing doesn't bias them). Driven by **Jetpack Macrobenchmark**
(`//tools/benchmark/android_macrobenchmark`, `-e targetAppId <cell>`):

- **startup** = `StartupTimingMetric`, `StartupMode.COLD`, ART pinned to
  `speed`, shader cache dropped per iteration: process create → first frame
  (`timeToInitialDisplayMs`), 10 measured iterations (median), one warmup
  launch discarded, ≥500 ms between launches. Cells call
  `reportFullyDrawn()` at their content frame.
- **interaction** = 5 iterations of 10 cycles of (50 ms → REAL injected tap
  on the button → 50 ms → swipe up → 50 ms); the measured value is the
  cell's own `iso-tap` async trace section — **ACTION_UP receipt → the
  first pre-draw pass carrying the updated count** — via
  `TraceSectionMetric` (average per iteration, median across iterations).
  Injection latency and RenderThread/present time are excluded by
  construction. Sections open only for true taps (travel ≤ touchSlop,
  hold < 300 ms). The probe is `dev.isomer.runtime.TapProbe` in the
  UUI/native cells and the same pattern in the RN/Valdi forks.

| config | app code runs in | renderer | startup (TTID med) | interaction (med of per-iter avg) | APK | compile ▵ |
|---|---|---|---|---|---|---|
| **native Compose** (baseline) | Kotlin | Jetpack Compose | 526 ms | 10.8 ms | 8.1 MB | — |
| UUI compiled + Compose | Swift `.so` | Compose interpreter | 609 ms | 12.0 ms | 33.0 MB † | — |
| UUI wasm AOT + Compose | WAMR AOT | Compose interpreter | 478 ms | **9.6 ms** | 14.6 MB | 72 s |
| React Native | Hermes | RN views | 477 ms | 32.2 ms ‡ | 17.4 MB | — |
| Valdi | QuickJS | Valdi views | 399 ms ◦ | **13.3 ms** ‡ | 10.5 MB | — |
| Lynx | PrimJS (QuickJS) | Lynx views | 478 ms | 15.1 ms ‡§ | 13.3 MB | — |
| Flutter | Dart AOT | Impeller (self-drawn) | 1,826 ms | 12.1 ms ¶ | 15.1 MB | — |

- ‡ **RN, Valdi, and Lynx interaction numbers are IDLE-JS BEST CASE**: one
  trivial component, an empty JS thread. Real apps contend for that single
  thread and every tap queues behind it — the UUI cells have no such hazard.
  A ~25%-duty busy pass barely moved tap medians (the ~1-frame posted-click
  floor masks short bursts) but cost +50 ms (RN) / +78 ms (Valdi) startup.
- The tap column now has ONE anchor for every row (the content-anchored
  probe): all cells pay Android's posted-`performClick` + next-frame floor
  (~10-13 ms at 60 Hz), so read the sub-frame engine differences from the
  spread above that floor. RN's 32 ms = its heavier async-JS pipeline
  missing that next frame. Numbers from the earlier framestats /
  hand-driven passes are NOT comparable to this table.
- ◦ Valdi's startup runs without Macrobenchmark's per-iteration shader-cache
  drop (its APK lacks the profileinstaller receiver the drop broadcast
  needs) — a slightly warm-biased number. The harness also caught that the
  Valdi APK measured in EARLIER passes was a debuggable build (Valdi's
  default Android manifest ships android:debuggable="true"; Macrobenchmark
  refuses such targets) — this pass benchmarks a `-c opt`,
  debuggable=false build, which is faster than the old rows suggested.
- § **Lynx specifics.** Same ReactLynx counter in a native `LynxView` host
  (SDK `org.lynxsdk.lynx:*:3.9.0`, `MOST_ON_TASM`). Its APK carries
  profileinstaller, so 478 ms is an honest per-iteration-cold TTID like the
  UUI cells — Lynx ties RN's start, taps 2× faster than RN, and lands ~2 ms
  behind Valdi (both QuickJS). Its `ALL_ON_UI` strategy does NOT speed up the
  tap: every Lynx thread strategy calls `StartJSThread()`
  (`task_runner_manufactor.cc`), so PrimJS is always on its own thread —
  `ALL_ON_UI` moves only layout/pipeline to the UI thread, not the `bindtap`
  handler. Lynx's synchronous `main-thread:bindtap` fast path is deliberately
  NOT benchmarked (RN/Valdi use background-thread handlers; the background
  `bindtap` is apples-to-apples). The `iso-tap` probe reads the
  `contentDescription` Lynx mirrors its `<text>` into; label + button are
  `flatten={false}`. Cell: `../lynx-tap-counter`.
- ¶ **Flutter has NO idle-JS caveat** (unlike ‡): Dart AOT runs on the UI
  isolate — no JS-thread hop — so the 12.1 ms tap sits at the native/compiled
  floor and does not degrade under app load, below every JS-runtime cell. It
  draws its own widgets (Impeller) into one FlutterView, so it's found via the
  semantics tree (`contentDescription` "Tap me", the existing `descStartsWith`
  fallback — no harness change); the `iso-tap` close crosses one extra sub-ms
  Dart→platform MethodChannel hop (small upward bias — read "≤ 12.1 ms").
  Startup 1,826 ms is honest Flutter cold start (engine + Dart AOT VM init),
  ~3-4× the JS cells on this budget SoC (ART speed-compile can't help the
  native `libapp.so`). Cell: `../flutter-tap-counter`.
- Isomer renders with Compose or OpenGL on Android; its Android Views
  renderer, and the native Views baseline cell, are gone (2026-10-15:
  at most two renderers a platform).
- † One APK hosts all the renderers (`--es renderer …`); the 33 MB is
  dominated by the Swift app+stdlib `.so`.
- ▵ **compile** = producing the delivery artifact from the built reactor
  `.wasm` (7.7 MB, `-c opt`), M-series host: wamrc `.aot` **72 s** — a
  build cost, which is why a hot-reloaded reactor runs interpreted rather
  than AOT.

### Parallelism (wasi-threads) — Android compute microbenchmark

The counter cells above measure *interaction latency* (a trivial handler). This
separate microbenchmark measures *compute throughput* to answer one question:
can a wasm-delivered Swift reactor use **multiple cores**, and how close does
**AOT wasm + real threads** get to native compiled Swift on Android?

The reactor is compiled for `wasm32-unknown-wasip1-threads` (shared memory +
atomics) and run under WAMR built with wasi-threads (`--define wamr_threads=1`).
A CPU-bound kernel is run serially (1 thread) vs split across N threads that
`thread_spawn` real OS threads. Pixel 3a (`sargo`, 8 cores), same device as
above. Wall-time of the parallel phase (N threads × equal per-thread work):

| tier | 1 thread | 4 threads | 8 threads | vs native (1T) |
|---|---|---|---|---|
| **native arm64** (compiled Swift-class, C+pthreads) | 0.211 s | 0.232 s (3.16×) | 0.269 s (5.42×) | 1.00× |
| **wasm AOT + wasi-threads** (wamrc `--enable-multi-thread`) | **0.213 s** | 0.242 s (3.13×) | 0.253 s (5.82×) | **≈1.01×** |
| wasm interp + wasi-threads (fast interp) | 3.82 s | 4.96 s (3.07×) | — | ~18× |
| wasm AOT, Swift `TaskGroup` (not pthreads) | 0.182 s | 0.726 s (0.25×) | 1.452 s (0.13×) | serial-only |

- **AOT wasm + threads is at parity with native** — single-thread 0.213 s vs
  native 0.211 s (~1%), and parallel scaling tracks native (3.13× vs 3.16× at
  4T; at 8T the wasm run is actually a hair faster, within noise). So a
  **wasm-delivered** Swift reactor — data, not loaded native code — reaches
  compiled-Swift throughput *and* uses every core.
- **AOT is essential.** The same reactor under the interpreter is **~18×
  slower** single-thread (3.82 s vs 0.21 s); parallelism alone doesn't save a
  weak SoC. Threading multiplies whatever the per-thread speed is.
- **Swift Concurrency needs a custom executor, and even then parallel
  *throughput* is memory-bound.** The default `wasip1-threads` global executor is
  single-threaded cooperative (a `TaskGroup` fan-out regresses to 0.25×). Binding
  a **custom `TaskExecutor` over a wasi-threads pool** correctly runs jobs on N
  threads concurrently — but CPU-bound *Swift* compute still doesn't *scale*: an
  identical pthread harness in one module measured **C 3.67× vs Swift 0.87×** at
  4 threads. Swift threads run concurrently (responsiveness holds — see below),
  but parallel throughput is memory-bandwidth-bound (SwiftWasm keeps hot loop
  state in shared linear memory rather than wasm locals; C is register-resident
  and scales). The wasi-threads *mechanism* is sound; the gap is SwiftWasm codegen
  (tracked in [oss_contributions.md](oss_contributions.md)).
- Toolchain: version-matched swift.org 6.3.0 host + swiftwasm 6.3-RELEASE threads
  SDK (swiftmodule compat is exact-patch); WAMR threads via the vendored
  `--define wamr_threads=1` build (thread-mgr + lib-wasi-threads). Verified on
  Android AND the **iOS simulator** (C parallelism 3.89× at 4 threads — same
  Darwin runtime as device; the interp tier runs threads on a physical iOS device
  too, since threads — unlike loaded AOT code — are allowed). Cell/harness:
  a wasi-threads spike outside this repository.

### Interim: wasi-threads with async fan-out (a test cell, archived)

Not blocked on the upstream PRs. The wasi-threads test cell (this
repository's `wasm_threads/` directory until 2026-10-02) was a standalone Bazel module
(rules_swift allows one wasm SDK per build) whose `swift.wasm_sdk(threads =
True, url = …, sha256 = …)` points at a bundle built from OUR fork —
`AttilaTheFun/swift` branch `threads-sdk-6.3.2`, release
`threads-sdk-6.3.2-1`: swift-6.3.2-RELEASE + the Concurrency build fix
(swiftlang/swift#92018) + the thread-pool global executor (the package
proposed in swift-platform-executors#30) — consumed by the STOCK swift.org
6.3.2 host toolchain. Native Apple/Android code never sees the fork; only
the stdlib inside the wasm SDK bundle differs. `bazel test //...` there builds a TaskGroup peak-concurrency probe as a wasm command and
runs it under the threads-enabled WAMR the hosts embed
(`--define wamr_threads=1`): **peak 4 of 8** (the stock SDK reads 1).
Rebuilding the bundle: `scratchpad/assemble_threads_sdk.sh` in the
fork's swiftwasm-source workspace (see the release notes); host and SDK
must match to the patch version. Not in the slice: Foundation (the skim
Foundation is what isomer uses on wasm). When upstream lands, the
pin moves to the official bundle and nothing else changes.

### Threads under load — responsiveness vs JS (Android)

The parallelism table above is about *throughput*. The property that actually
decides UX is **responsiveness under background load**: can the app keep the UI
thread free while heavy work runs? This is where single-threaded JS structurally
loses — and where even *concurrency-only* (non-scaling) wasi-threads wins.

Metric: main-thread "UI" throughput (tiny work units/s) retained while a
background CPU task runs continuously. Pixel 3a, AOT reactor, `--define
wamr_threads=1`:

| model | UI throughput retained under background CPU load |
|---|---|
| **UUI AOT wasm + wasi-threads** (bg on a wasi thread) | **~1.00** (100%) |
| single-thread **JS model** (bg shares the one thread) — i.e. Valdi/RN/Lynx | **~0.00** (UI starved) |

- **This is the ‡ "idle-JS best case" caveat made concrete.** JS frameworks run
  *all* app logic on one thread (Valdi/QuickJS, RN/Hermes, Lynx/PrimJS), so any
  background computation blocks interaction: the UI thread does ~0 useful work
  until the JS task yields. UUI offloads the same work to a wasi thread and the UI
  thread is **untouched** (retention 1.00 measured, background thread running real
  heavy compute the whole time). Valdi's own busy-load rows corroborate (a
  ~25%-duty background task measurably degraded its tap).
- The single-thread row is a controlled same-device, same-kernel measurement of
  the JS execution model (one thread must do both), not the Valdi app itself
  (which lacks UI-throughput instrumentation); it is the structural ceiling every
  single-threaded-JS runtime shares. React fiber time-slicing raises it off zero
  but caps it well below the threaded 1.00 and cannot make the interaction
  synchronous.
- Note this holds even though parallel *throughput* doesn't scale (above): the
  background Swift thread runs **concurrently** on its own core, so the UI thread
  keeps its full budget. Responsiveness (the UX-critical property) is delivered
  today; throughput scaling awaits the codegen fix.

## iOS

**Device / method.** iPhone 13 Pro (iOS 18.7), release builds (`-c opt`),
DEVICE-DEFAULT settings (ProMotion on, animations on — both metrics measure
app-owned work, so display pacing doesn't bias them). Driven by **XCUITest
`measure` blocks** (`//tools/benchmark/ios_xcuitest`, run on-device via
`run_on_device.sh` — a personal-team-provisionable XCTRunner; rules_apple's
stock `com.apple.test.*` runner id cannot be provisioned by a free team):

- **startup** = `XCTApplicationLaunchMetric`, 10 measured launches (XCTest
  discards its own warmup): process launch → first frame, by Apple's own
  system signposts.
- **interaction** = 5 measured iterations of 10 cycles of (50 ms → REAL
  synthesized tap → 50 ms → swipe up → 50 ms); the measured value is the
  app's own `os_signpost` interval ("tap", subsystem
  `dev.isomer.bench`) — **UIEvent receipt at the handler edge → the
  end of the Core Animation commit carrying the update** (a runloop
  observer at order 2,500,000, after CA's commit observer) — via
  `XCTOSSignpostMetric`. Injection latency and render-server present time
  are excluded by construction. Instrumentation: `InteractionSignpost`
  (UUI/native cells, installed by the bench boot constructor, armed by
  `-bench-signpost`) and the same pattern in the RN/Valdi/Lynx cell harnesses.

| config | app code runs in | renderer | startup | interaction (med of per-iter avg) | app (.ipa) |
|---|---|---|---|---|---|
| **native SwiftUI** (baseline) | Swift | SwiftUI | 210 ms | 5 ms | **0.05 MB** |
| UUI compiled + SwiftUI | Swift (native) | SwiftUI | **203 ms** | 5 ms | 0.07 MB |
| React Native | Hermes | RN views (Fabric/UIKit) | 217 ms | 3 ms ♢ | 4.6 MB |
| Valdi | JavaScriptCore | Valdi views (UIKit) | 204 ms | 18 ms ♢ | 8.0 MB |
| Lynx | PrimJS (QuickJS) | Lynx views (UIKit) | 213 ms | 7 ms ♢§ | 4.9 MB |
| Flutter | Dart AOT | Impeller (self-drawn) | 230 ms | 11 ms | 14.0 MB ‖ |

- **UUI compiled ≈ native SwiftUI on both metrics** — measured by Apple's
  own launch metric and a real-touch signpost, the reimplementation-core
  path costs nothing over hand-written SwiftUI.
- Isomer renders with SwiftUI or Metal on Apple platforms; its UIKit
  renderer, and the native UIKit baseline cell, are gone (2026-10-15:
  at most two renderers a platform).
- **Why there is no wasm row on iOS**: the OS forbids dynamically
  loaded executable pages, and an embeddable XIP image has no delivery
  advantage over compiling the Swift — so the measured iOS tier is
  **compiled** (`IsomerView`'s default). A delivered or hot-reloaded reactor
  runs interpreted (WAMR reads it as data, not code — iOS-legal); its last
  pass under the OLD harness was 214 ms / 12.7 ms / 2.5 MB. (The JSC
  engine also runs the reactor on-device — no-JIT wasm in a JSContext,
  `tap_counter_jsc_ios_application` — kept as an engine-seam proof, not a
  shipping tier.)
- ♢ **RN, Valdi, and Lynx interaction numbers are all IDLE-JS BEST CASE**:
  one trivial component, an empty JS thread; each tap crosses its async JS
  thread (harnesses close the signpost on the complete text+frame update).
  The spread is empty-thread engine cost: RN 3 ms (Hermes), Lynx 7 ms
  (PrimJS/QuickJS), Valdi 18 ms (JSC, heavier pipeline). Real apps contend
  for that single thread — a ~25%-duty busy pass doubled RN's tap (3 → 6 ms);
  the UUI cells have no such hazard.
- § **Lynx specifics.** iOS Lynx uses PrimJS/QuickJS too (Valdi is JSC on
  Apple), same ReactLynx counter in a native `LynxView` host (CocoaPods
  `Lynx`/`PrimJS`/`LynxService` 3.9.0). Its 7 ms beats Valdi's 18 ms because
  the QuickJS round trip + native-view update is a light pipeline on the A15
  (a default `bindtap` still crosses the JS thread — see the Android § on why
  `ALL_ON_UI` can't remove that hop). The probe reads the `accessibilityLabel`
  Lynx sets on its `<text>` (`LynxUIText.enableAccessibilityByDefault`=YES),
  which also makes the button XCUITest-tappable with no bundle change. Cell:
  `../lynx-tap-counter/ios`.
- ‖ **Flutter has NO idle-JS caveat** (contrast the ♢ rows): Dart AOT runs on
  the UI isolate with no JS-thread hop, so the 11 ms tap doesn't degrade under
  app load. It draws its own widgets (Impeller) into one FlutterView, so it's
  found via the accessibility/semantics tree (`Tap me` button node, existing
  buttons/staticTexts/otherElements probe — no harness change); the tap
  signpost's close crosses one extra sub-ms Dart→platform MethodChannel hop
  (small upward bias — read "≤ 11 ms"). Startup 230 ms is honest Flutter cold
  start (engine + Dart AOT VM init). Size is the release `.app` on disk (no
  `.ipa` built) — an upper bound vs the other rows' zipped `.ipa`. Cell:
  `../flutter-tap-counter/ios`.

## macOS

Same stack as iOS (compiled SwiftUI + `WasmView`/WAMR); not separately
benchmarked. Microbench proxy (`//examples/shared/greeter_aot_bench`):
~266 ms interp → ~30 ms AOT load+instantiate+exercise.

| config | app code runs in | renderer | startup | tap → present (med / mean) | app size |
|---|---|---|---|---|---|
| **native SwiftUI** (baseline) | Swift | SwiftUI | | | |
| UUI compiled + SwiftUI | Swift (native) | SwiftUI (`IsomerTreeView`) | | | |
| UUI compiled + GPU | Swift (native) | SwiftGPU (Metal) | | | |
| UUI wasm AOT + SwiftUI | WAMR AOT | SwiftUI (`WasmView`) | | | |
| UUI wasm AOT + GPU | WAMR AOT | SwiftGPU (Metal) | | | |
| React Native (macOS) | Hermes | RN views (AppKit) | | | |
| Valdi | JavaScriptCore | Valdi views | | | |

## Web

The app always ships as a wasm bundle JIT-compiled by the browser, so the
compiled/interp/AOT distinctions collapse; what remains is the renderer
choice. Not benchmarked this pass.

| config | app code runs in | renderer | startup | tap → present (med / mean) | bundle size |
|---|---|---|---|---|---|
| UUI wasm + React | browser wasm JIT | React (DOM components) | | | |
| UUI wasm + GPU | browser wasm JIT | SwiftGPU (WebGPU) | | | |
| react-native-web | browser JS | React DOM | | | |
| Valdi (web export) | browser JS | Valdi web | | | |

- `react-native-web` is a different renderer from RN proper — the nearest
  comparison, not a like-for-like one.

## Windows

**Machine / method.** i9-13900K, Windows 11 Pro, 240 Hz display; `-c opt`
builds (`--config=release` for the AOT cell). Same counter and metrics as
Android, driven by the **in-process bench harness** (`ISO_BENCH=1` →
`DesktopBench`): desktop cells draw every pixel themselves (SwiftGPU/D3D11),
so the loop logs `[iso-content-frame]` at the first presented frame and
dispatches 15 taps through `Runtime.pointerEvent` (the exact entry the Win32
mouse callback uses), timing each to the present of the frame carrying the
new count. Startup = spawn epoch → content-frame epoch; 4 cold runs, first
dropped. The **Win32 baseline** (one STATIC + one owner-drawn BUTTON, no
Swift) does the same via `BM_CLICK` + synchronous GDI repaint.

| config | app code runs in | renderer | startup | tap → present (med / mean) | app |
|---|---|---|---|---|---|
| **native Win32** (baseline) | C | Win32 controls (GDI) | **39 ms** | **0.9 / 1.0 ms** | **0.015 MB** |
| UUI compiled + GPU | Swift (native PE) | SwiftGPU (D3D11) | 276 ms | 4.2 / 4.2 ms † | 1.1 MB ‡ |
| UUI wasm AOT + GPU | WAMR AOT | SwiftGPU (D3D11) | **245 ms** | 4.2 / 4.2 ms † | 28.1 MB ‡ (1.4 loader + 26.7 .aot) |
| React Native (Windows) | Hermes | RN views (WinUI) | | | |
| Valdi | — | N/A (no Windows target) | N/A | N/A | N/A |

- † tap→present is **vsync-quantized**: SwiftGPU presents with
  `Present(1, 0)`, so every tap lands exactly one 240 Hz frame (~4.17 ms)
  after dispatch; the GDI baseline paints synchronously without waiting for
  vblank. The actual CPU cost of a UUI tap is far below the frame (reactor
  render 0.5–1.5 ms) — the honest cross-row comparison is "presents on the
  next frame" for every UUI cell.
- ‡ Plus the swift.org Swift runtime DLLs (shared, installed system-wide),
  not counted per-app.
- The Windows-ABI `.aot` is cross-produced on a Linux/macOS host
  (`wamrc --target=x86_64 --target-abi=msvc --size-level=0` — the large code
  model is required or a big reactor's 32-bit relocations truncate); the AOT
  runtime loader builds under MSVC (`--define wamr_aot=1`).

## Linux

**Machine / method.** Same i9-13900K, WSL2 Ubuntu 24.04 under WSLg — GL is
Mesa **llvmpipe** (software rasterizer), so absolute numbers are
conservative; relative deltas between rows are the signal. Protocol identical
to Windows (in-process `DesktopBench`, 4 cold runs, first dropped). The
**GTK3 baseline** (one GtkLabel + one CSS-styled GtkButton, no Swift) times
`gtk_button_clicked()` → the frame clock's after-paint.

| config | app code runs in | renderer | startup | tap → present (med / mean) | app |
|---|---|---|---|---|---|
| **native GTK3** (baseline) | C | GTK widgets (cairo) | **57 ms** | **1.5 / 1.5 ms** | **0.014 MB** |
| UUI compiled + GPU | Swift (native ELF) | SwiftGPU (OpenGL) | 111 ms | 2.3 / 2.4 ms | 2.0 MB ‡ |
| UUI wasm AOT + GPU | WAMR AOT | SwiftGPU (OpenGL) | **150 ms** | **2.5 / 2.5 ms** | 24.8 MB ‡ (2.3 loader + 22.5 .aot) |
| React Native | — | N/A (no desktop-Linux target) | N/A | N/A | N/A |
| Valdi | QuickJS | Valdi views (`valdi_linux_application`) | | | |

- ‡ Plus the swift.org Swift runtime .so files (shared), not counted per-app.

---

## Open work

- **Fill the blank cells**: macOS, web, RN-Windows, Valdi-Linux.
- **One externally-driven tap harness for every row**: real synthesized
  touches (XCUITest on iOS; `input` on Android as today) with in-app
  content anchors — touch receipt → commit/pre-draw carrying the update —
  replacing the mixed framestats / in-process-trigger anchors, plus push
  telemetry to the build host instead of devicectl/logcat pulls. Re-measure
  all iOS and Android rows under it (the framestats anchor undercounts
  posted-click work; the iOS in-process trigger skips hit-testing).
- **SwiftUI-level memoization in the reactor**: the Patch diff catches
  unchanged output at the encode boundary, but the reactor still re-runs the
  full `body` per event — memoizing unchanged subtrees would cut interp
  per-tap compute (the AOT/compiled tiers run `body` native already).
