# Future direction: federated wasm modules

**Status: not possible today — recorded so we don't overstate the capability.**

This is the north-star we do **not** yet have, and an honest account of why. It
exists so nobody reads the WasmView system as claiming something it can't do,
and so a future reader knows exactly which two upstream pieces have to land
first.

## The vision

Ship the heavy, rarely-changing code **once** and let many independently-
delivered feature bundles reference it:

- an app-shipped **runtime module** carrying the Swift stdlib, `swift_ui_core`,
  the renderers, and the injected dependency protocols;
- tiny **feature bundles** that contain only the feature's own code and link
  against that shared runtime at load time — sharing its code *and* its heap.

This is "federated wasm modules": several modules that share a common runtime
and call into each other, so a feature bundle is kilobytes, not megabytes, and
each feature can be updated out-of-band on its own cadence.

C / C++ / Rust already do exactly this in the browser (Emscripten
`MAIN_MODULE` / `SIDE_MODULE`, `dlopen`). **Swift cannot, yet.**

## Two different capabilities (don't conflate them)

**a) Modules talking to each other — already works, everywhere.** Every wasm
runtime supports this via imports/exports: one module's exports satisfy
another's imports at instantiation. It is exactly how our host bridge works
(`iso_hot.*` / `swift_ffi.*`). The WebAssembly **Component Model** (WASI
Preview 2) is the newer standardized form. So interoperation is not the
problem.

**b) Sharing one copy of a big runtime across bundles — this is the hard part,
and what we lack.** Deduplicating the stdlib+core baseline needs **dynamic
linking**, which is a *convention layered on top of* core wasm, not part of the
spec: position-independent code, a **shared** linear memory + table, a global
offset table (GOT), a `dylink.0` custom section, and a runtime loader that
relocates and resolves symbols at load (`dlopen`).

Crucially, the Component Model does **not** solve (b): it is *shared-nothing* —
every component keeps its own linear memory and copies values at the boundary.
It fixes typed interop, not code-size sharing; each component still carries its
own stdlib copy. So "just use the component model" would not shrink per-feature
size.

## Why it's blocked for us specifically

Both of these have to move, and both are upstream of this repo:

| Layer | Needs | State today |
|---|---|---|
| **Toolchain (SwiftWasm)** | Emit the stdlib as a PIC/relocatable **side module** (build Swift as a wasm shared library) | Not supported — the harder, Swift-specific gap |
| **Runtime (WasmKit)** | A **dynamic-linker runtime**: parse `dylink.0`, do GOT.mem/GOT.func relocation, `dlopen` | Not implemented — WasmKit instantiates one module against fixed imports |

Emscripten-on-JS is the one environment where the full approach works today, but
you cannot simply "switch runtimes": SwiftWasm would still have to emit the
PIC/dylink output for any loader to consume it. The toolchain is the gating
piece.

We chose WasmKit deliberately (pure-Swift, no native deps, cross-compiles to
Android — see [wasm_view_architecture.md](wasm_view_architecture.md)). Adding a
dylink runtime to it, *or* swapping to a runtime that has one, forfeits that
property, and is moot until SwiftWasm emits side modules anyway.

## No upstream tracking issue

As of this writing there is **no dedicated issue** tracking wasm dynamic linking
/ side-module support in `swiftwasm/WasmKit` or `swiftwasm/swift`. The nearest
related, forward-looking threads:

- `swiftwasm/swift#5549` — *Roadmap: Component Model Support* (shared-nothing
  composition; the standards-track direction, though it does not dedupe a
  runtime).
- `swiftwasm/swift#7` — *build wasm file is very big* (the motivating size
  problem).

SwiftWasm's toolchain work is being upstreamed into `swiftlang/swift`, so a
future side-module effort may land there rather than in `swiftwasm/swift`.

## Runtime mirror: multiple live instances

WasmKit **can** run many bundle instances at once and load/unload them freely —
each `WasmView` gets its own `Engine` + `Store` + `Instance` (its own linear
memory), fully isolated; a reload just discards one and instantiates another.
But without shared linear memory, **M concurrent instances cost ≈ M × the
baseline memory** (each carries its own stdlib+core copy). That is the runtime
mirror of the same duplication — dynamic linking is what would let instances
share one heap.

## What we ship instead (see wasm_view_architecture.md, "Bundle splitting")

Because true sharing is infeasible today, the two viable options are:

1. **One shared app-wide bundle with internal id-routing** — a single wasm with
   the runtime + all wasm-delivered features; pays the baseline **once**.
   Trade-off: all wasm features update together. Best default.
2. **Self-contained per-feature bundles, release-built** (`--gc-sections`,
   ABI-only exports, `--strip-all`, `-c opt`) — independent delivery, but each
   re-pays its DCE'd baseline (~2.1 MiB gzip, measured). Fine for a handful of
   large features; implemented as the `hot_demo_release.wasm` target.

Neither duplicates code silently or claims a capability we don't have — which is
the point of writing this down.
