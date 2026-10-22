# Positioning: a browser engine for native UI

A framing for what this stack *is*, product-wise — not a cross-platform
framework with a wasm curiosity bolted on, but **a browser engine whose
content language is Swift and whose DOM is native UI**.

> **0.38:** WAMR, and with it the AOT tier below, was removed; WasmKit's
> interpreter runs every reactor on the native hosts. The interpreter tier's
> argument stands as written; the AOT tier and its numbers (measured under
> WAMR) are history.

## The analogy, stated plainly

A browser engine is three things:

1. a **sandboxed VM** that executes code the app vendor did not ship —
   downloaded, versioned and updated out-of-band (V8/JavaScriptCore running
   JS);
2. a **declarative scene description** the sandboxed code produces and the
   engine renders (the DOM + CSS);
3. a **capability boundary**: the page can only touch what the engine
   exposes (web APIs), never the OS directly.

This stack is the same three things:

1. **WasmKit** executing a SwiftWasm reactor — a `.wasm` bundle delivered with
   the app or downloaded at runtime;
2. **`tree.fbs`** — the retained UI tree the reactor produces and a
   `TreeRenderer` renders (real SwiftUI on Apple, Compose on Android, React on
   the web, SwiftGPU everywhere);
3. the **import boundary** — the module's only surface is the host functions
   we inject (`swift_ffi` DI, `iso_*`): fetch, storage, feature-host
   services. No import, no capability.

The differences are the selling points: the content language is **Swift, not
JS** (typed, no GC pauses, real value types), the scene renders as **native
platform UI, not a DOM emulation**, and there is an **AOT tier** browsers
don't get to have.

## "Executing downloaded code" — the same mechanism as a JS VM

The interpreter tier is *mechanically identical* to a JavaScript VM running
downloaded script: the `.wasm` bytes are **data**, read by an interpreter
loop. Nothing is mapped executable; no code pages are created. iOS's
prohibition on dynamically loaded executable pages (the thing that kills a
`wamrc .aot` loaded from disk, signal 9) is about *machine code*, and the
interp tier involves none. A wasm interpreter executing wasm bytecode is no
different in kind from JavaScriptCore executing JavaScript or Hermes
executing its own bytecode — the mechanism React Native and its OTA-update
ecosystem (CodePush et al.) have shipped on for a decade.

(Positioning note, not legal advice: App Review's dynamic-code guideline is
written around scripts/WebKit/JavaScriptCore. OTA-updated RN/Hermes bytecode
is long-standing accepted practice with the same mechanical shape; a wasm
interpreter sits in the same class. The AOT tier below sidesteps the question
entirely — it's ordinary signed native code, reviewed with the app.)

## The two tiers (hybrid delivery policy; until 0.38)

Measured under WAMR on an iPhone 13 Pro ([benchmarks](benchmarks.md#ios)):

| tier | delivery | mechanism | startup | tap |
|---|---|---|---|---|
| **AOT (default)** | bundled with the app | `wamrc --xip` image linked into the signed `__TEXT` segment, executes in place — zero relocations, zero runtime codegen | **74–112 ms** (the Metal cell *beats* the 83 ms hand-written native SwiftUI baseline) | 9.9–11.4 ms |
| **interp (opt-in)** | downloadable at runtime | WAMR fast-interp on the `.wasm` bytes — pure data | 208–241 ms | 12.8–15.3 ms |

One binary carries both: features run the embedded AOT image by default; if a
shipped feature has a bug, the vendor flips it to a **dynamically delivered
interpreted bundle** (`ISO_FORCE_INTERP=1` seam) — sacrificing a bit of
performance to ship the fix in minutes instead of an App Store review cycle.
When the next release rolls the fix into the bundled AOT image, the flag
flips back. That is exactly a browser's update model (content updates
instantly, engine updates with the app) — with a native-speed default tier
browsers don't have.

## Why this beats the incumbents at their own game

- **vs. WebView/PWA**: same instant-update story, but the UI is real native
  components (or a self-drawn GPU surface), startup is 74–241 ms instead of a
  browser bring-up, and the app code is Swift sharing one main thread — no
  JS-thread hop, no bridge stalls (see the tap medians *and means*:
  the JS frameworks' tails are the UX).
- **vs. React Native/Valdi**: same OTA capability class, but typed compiled
  Swift instead of JS, and the AOT tier is *faster than hand-written native
  startup*. Be honest about where the JS incumbents are strong — on the
  flagship-phone iOS counter their taps are excellent (RN 6 ms, Valdi
  3.5 ms) — and where they aren't: the language (untyped JS), the down-market
  scaling (the Pixel 3a Android column shows RN at 14.6/23 ms with a real
  tail), and Hermes/JSC engines they don't control. RN's and Valdi's own iOS
  cells are the baseline rows in [benchmarks.md](benchmarks.md#ios).
- **vs. plain native**: adds the browser superpowers (sandboxing, out-of-band
  delivery, capability-scoped features) at a measured cost of ~5 ms/tap
  (interp) or ~0 startup cost (AOT) — and the *same* SwiftUI source runs as a
  plain native build (`full|partial × compiled` cells) whenever a feature
  graduates into the app binary.

## One-line pitches

- "A browser engine where the pages are Swift and the DOM is SwiftUI."
- "JavaScriptCore runs downloaded JS; WasmKit runs downloaded Swift. Same
  mechanism, typed language, native rendering."
- "Ship the engine once; ship features like web pages — with a native-speed
  AOT tier for the ones you bundle."

Related: [wasm_view_architecture.md](wasm_view_architecture.md) (the engine
embedding), [future_direction.md](future_direction.md) (federated modules —
the shared-runtime endgame that makes feature bundles kilobytes),
[adoption_levels.md](adoption_levels.md).
