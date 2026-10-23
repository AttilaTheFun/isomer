# Why not JavaScript?

*Why this stack reimplements SwiftUI in Swift instead of adopting a JavaScript
runtime — and how it positions itself against React Native, Lynx, and Valdi.*

The one-line thesis: **you reach for JavaScript to get two things — one
codebase across platforms, and the ability to ship UI updates out-of-band. JS
makes you pay for them with a threading architecture that taxes every
interaction and can't be fixed per-handler. Isomer keeps both prizes and
skips the tax, because its content language is compiled Swift, not interpreted
JS.**

See also [browser_engine_positioning.md](browser_engine_positioning.md) (the
"Swift is the content language, native UI is the DOM" framing) and
[benchmarks.md](benchmarks.md) (the measurements cited below).

## What the JS frameworks get right

The pitch is real and it's why React Native, Lynx, and Valdi exist:

1. **One codebase, every platform.** Write the screen once; render it on iOS,
   Android, and the web.
2. **Out-of-band delivery.** Because the UI is a JS bundle — *data*, not signed
   executable code — you can ship a fix or a whole feature without an app-store
   round trip. On iOS this is the killer feature: the OS forbids dynamically
   *loaded* native code, but a JS bundle interpreted by a VM is legal.

Both are genuinely valuable, and any honest alternative has to keep them, not
dismiss them.

## The tax that comes with the JS runtime

Adopting JS means adopting a garbage-collected VM whose execution model is
**single-threaded by design**. That one fact propagates into the whole
architecture.

### The thread hop, and why it's structural

`async`/`await`, Promises, and the event loop are **concurrency, not
parallelism**: they interleave tasks on *one* thread. `await` yields the
thread; it does not move work to another core. So inside a JS realm there is no
equivalent of `DispatchQueue.global().async { }` or a Kotlin
`Dispatchers.Default` coroutine — no cheap way to shove a heavy computation onto
another core while keeping a shared object graph.

The only real parallelism JS offers is Web Workers / worker threads, and those
are **separate isolates with separate heaps and message-passing**. You can't
hand a worker a closure over your component state; you serialize a message
across, run a second JS context, and serialize the result back. That is far too
heavyweight for the *incidental* few milliseconds of work that accumulate in a
tap handler.

This is why native "app code on the main thread" works and JS's doesn't. Native
platforms let you keep the *UI update* on the main thread (synchronous, low
latency) and offload the *heavy part* to a real thread in one line, sharing
memory. JS can't do that selectively — so the frameworks do the only thing left:
they run **all** app JS on a dedicated non-UI thread, so its inevitable
single-threaded blocking blocks a thread that isn't drawing frames. Every
interaction then crosses UI → JS → UI. The hop is the price of that isolation,
paid on every tap because you can't offload just the hot part.

The clearest evidence that this is a JS constraint, not a design whim:
**React's concurrent mode (fiber time-slicing) is a single-threaded substitute
for parallelism.** Reconciliation is CPU-bound JS; a native toolkit would run it
on a background thread; React instead chops it into chunks and cooperatively
yields to the event loop between them. If JS had cheap shared-memory threads,
fiber would look nothing like it does.

### The escape hatches don't fully escape

- **Lynx's main-thread script** (`main-thread:bindtap`) runs a handler
  synchronously on the UI thread — genuinely skipping the hop. But it's an
  opt-in fast path, not the idiomatic default, and it shifts the "don't jank the
  UI thread" burden back onto every handler author, without a cheap offload to
  relieve it. Lynx's own thread strategies confirm the default: *every* strategy
  (`ALL_ON_UI` included) still starts a dedicated JS thread (see
  benchmarks.md#android §), so a normal handler always hops.
- **Time-slicing** keeps the thread responsive; it does not make the work
  parallel or the interaction synchronous.

### What the tax actually costs

It is *not* mainly raw idle latency. On a fast SoC an empty-JS-thread round trip
is cheap — our idle iOS measurements have React Native tapping in **3 ms** on an
A15, right next to native. The cost is structural:

- **It's a best case that doesn't hold.** Those numbers are one component on an
  *empty* JS thread. Real apps share that single thread with business logic,
  network callbacks, and other components; every tap queues behind whatever it
  is doing, and there's no cheap offload to relieve it. A measured ~25%-duty
  background load *doubled* React Native's tap (3 → 6 ms) with no other change.
- **It shows on real hardware and under weight.** On a 2019 Pixel 3a the same
  React Native tap is **32 ms** — ~3× the native and Isomer-compiled cells
  (~10–13 ms) on that device. Valdi and Lynx (both QuickJS) land at ~14–15 ms;
  the spread above the frame floor is JS-pipeline weight.
- **You can never *guarantee* sub-frame.** Because the interaction can't run
  synchronously with the frame, a JS framework structurally cannot promise the
  update lands in the same frame the touch did. Native — and compiled Isomer
  — can, because the handler runs inline on the main thread.
- **GC and VM overhead.** A tracing collector, JIT warmup, and VM memory are
  along for the ride, whether or not a given tap trips them.

## The other trade: Flutter

Flutter made the *opposite* bet from the JS frameworks and it's instructive.
Dart is **AOT-compiled and runs on the UI isolate** — so Flutter has no JS
thread hop, and it feels snappy for exactly that reason. But to get there it
gave up the two JS prizes: it **draws its own widgets** (Skia/Impeller) instead
of composing native components, so fidelity is an emulation that drifts from each
platform; and AOT Dart **can't be code-pushed** on iOS, so it loses the
out-of-band delivery that motivated cross-platform JS in the first place.

So the field forces a choice between three things — **native-speed
interaction, native-component fidelity, and out-of-band delivery**:

- React Native / Lynx / Valdi (JS VM): fidelity ✓, delivery ✓, **speed taxed**.
- Flutter (Dart AOT, own renderer): speed ✓, **fidelity emulated**, **delivery lost**.

## What Isomer does instead

Isomer's content language is a **SwiftUI subset written in Swift**, and it
refuses the trade above by decoupling *how app code is delivered* from *how it
runs*:

- **It runs like native.** App code compiles to native machine code (a `.so` on
  Android, native on Apple) and its handlers run **synchronously on the main
  thread**, exactly like hand-written SwiftUI or Compose — no bridge, no JS
  thread, no hop, and **no shared-thread hazard by construction**. Swift is
  **ARC, not a tracing GC**, so there are no stop-the-world pauses. Measured, the
  compiled tier is ≈ free over native: on iOS it tracks native SwiftUI within a
  millisecond; on Android it sits next to native Compose. (benchmarks.md)
- **It renders real native components.** The UI tree is handed to a pluggable
  renderer — real SwiftUI on Apple, Jetpack Compose on Android,
  React/DOM on the web — so it *is* native UI, not a drawn emulation. (A
  self-drawing SwiftGPU renderer exists for pixel-identical output where you want
  it.)
- **It still ships out-of-band.** The same Swift app also compiles to a **wasm
  reactor delivered as data** — the `.wasm` itself, run by WasmKit's
  interpreter on every native host (iOS-legal, because it's a data artifact
  an interpreter reads, not loaded executable pages). Hotfix a bug or
  hot-reload a live screen without an app-store round trip — the thing OTA JS
  bundles buy you — except the delivered artifact is your compiled Swift, run
  through the same renderers, not a JS bundle on a JS VM. Updates cross the
  wire as diff `Patch`es applied to a retained native tree.

So Isomer aims to hold all three corners: **native-speed interaction
(main-thread, compiled, no GC), native-component fidelity (real SwiftUI /
Compose / Views / DOM), and out-of-band delivery (wasm-as-data)** — the
combination each existing framework gives up one of.

## The honest costs

This isn't free, and the doc would be dishonest not to say so:

- **Swift, not JavaScript, is the ecosystem.** No npm, a smaller hiring pool,
  and the SwiftUI-subset surface is a reimplementation that trails the real
  thing on breadth.
- **The wasm delivery tier has real weight.** A reactor is megabytes where a JS
  bundle is kilobytes, and cold start / artifact-compile times are a tax the
  compiled tier doesn't pay (benchmarks.md quantifies both).
- **It's a younger, smaller project** than the frameworks it's positioned
  against, which have years of production hardening.

The bet is that *native-speed-by-default with native fidelity* is worth a
smaller ecosystem — and that dynamic delivery, the one thing that genuinely
required a VM, can be had from a wasm-as-data tier without adopting JavaScript's
threading model along with it.
