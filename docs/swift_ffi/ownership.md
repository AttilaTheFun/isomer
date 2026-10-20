# Memory and ownership

How object lifetimes work across the bridge. The model follows
[swift-java]'s `SwiftArena` semantics, generalized to non-JVM consumers; ARC
and the consumer's garbage collector are never coupled. See
[types.md](types.md) for what crosses the boundary and
[structure.md](structure.md) for where the mechanics are implemented.

## The rules

- **One owning runtime per object** — the side that created it. The other
  side only ever holds an opaque handle.
- **Returns are +1, parameters are +0.** A handle returned across the
  boundary carries a retain that the consumer's `Swift<Proto>` wrapper owns.
  A handle passed *in* is borrowed for the duration of the call. Release
  happens exactly once, through the generated `…_release` entry point;
  consumers never touch reference counts directly.
- **Two disposal modes**, mirroring swift-java's confined/auto arenas:
  - *Confined (deterministic)*: call `close()` — Kotlin `AutoCloseable` with
    `use { }`, TypeScript `close()` / `Symbol.dispose` with `using`. A
    TypeScript wrapper whose protocol declares a `close` of its own (a
    connection's) releases with `release()` instead: a class has one
    implementation per name there.
  - *Automatic (backstop)*: a leaked wrapper is released by Kotlin
    `finalize()` (a `Cleaner` needs API 33+; minSdk is 28) or a TypeScript
    `FinalizationRegistry`.

  Double-release is guarded: `close()` after the backstop (or twice) is a
  no-op, and use-after-close throws.

## The two handle primitives

Everything above rides on two mechanisms, and new features are expected to
reuse them rather than invent a third (see [generics.md](generics.md) for how
closures and generics will):

1. **Swift-owned → consumer**: an opaque +1-retained pointer box
   (`SwiftFFIBox_<Proto>`), freed by the generated `_release` C entry point.
   The consumer-side wrapper class owns the box and implements the disposal
   modes above.
2. **Consumer-owned → Swift** (a *foreign* object): the consumer registers
   its object in an integer-keyed registry and passes the id; the Swift side
   receives a generated `SwiftFFIForeign_<Proto>` proxy that implements the
   protocol by calling back out — over JNI on Android (a global ref with
   cached `jmethodID`s), over wasm imports on the web — and frees the
   registry slot in its `deinit`. There is nothing for the consumer to
   `close()`: the proxy's lifetime is ARC's business.

Interface *parameters* travel as a dual slot `(swift_handle, foreign_id)` with
exactly one side set; the glue's resolver picks the box or constructs the
proxy. This is what lets an interface flow in both directions with one
signature.

## Directions that work, and the one that doesn't

- Consumer → Swift: pass a consumer-implemented interface into Swift ✔
- Swift → consumer: return or hand a Swift-owned instance out ✔ (an owned
  `Swift<Proto>` wrapper — including *inside callback methods*, where Swift
  boxes +1 and the callback receives the wrapper; contracts declare
  interface-typed method parameters as the wrapper type)
- Foreign implementations returning interface-typed values back to Swift ✘ —
  rejected by the generator (the one restriction; closures-returning-closures
  will inherit it, per [generics.md](generics.md)).

## The cycle hazard

A cross-heap cycle — a Swift object holding a foreign proxy while the
consumer object holds a Swift handle — is invisible to both collectors and
leaks. Neither ARC nor the consumer GC can see through the other's heap. Keep
callback graphs acyclic, or break the cycle explicitly (close one side, or
null out the back-reference) when tearing down.

[swift-java]: https://github.com/swiftlang/swift-java
