# Generics and closures in swift_ffi

**Status:** superseded — bridge v2 ([abi.md](abi.md), branch `bridge-v2`) implements closures and generics with a different strategy (erased blob ABI + trampolines rather than per-shape monomorphization). Kept for the analysis of the v1 model.

This doc sketches how swift_ffi could support two features it currently rejects:
**closures / function-typed parameters** and **generic types**. The headline:
closures are ~80% already built (they are un-sugared `@ExportedInterface`s), and
generics hit a hard C-ABI wall that forces a choice between monomorphization and
type erasure — with one shape (constrained generics) falling out of the existing
interface path for free.

---

## 1. What the current model gives us

Types in the IR are carried as raw Swift-source strings (`FFIParameter.type: String`,
`FFIFunction.returnType: String`); there is no rich type enum. The real bridgeable
vocabulary is small and enforced by an allow-list in two places
(`BridgeTypes.isBridgeableParameter/Return` at macro time, and
`Generator+Validation.swift` after whole-module merge):

- Six scalars — `Int`, `Int32`, `Double`, `Bool`, `String`, `[UInt8]` (`BridgeValueType`)
- `Void` / `()`
- `@ExportedStruct` — flat value types, copied field-wise (fields must themselves be scalars)
- `@ExportedInterface` — protocols, crossing as owned opaque handles
- `Result<T,E>` is unwrapped to `T` + a throwing bit

The wire format is **manual flat C-ABI byte marshaling** — no FlatBuffers/JSON on the
call path. Scalars pass native; strings/`[UInt8]` as `(ptr, len)` in and a released
`+1` box out; structs as 8-byte-per-field buffers; interfaces as opaque handles.
Everything bottoms out in macro-expanded `@c` functions.

### The two handle primitives (both features lean entirely on these)

1. **Swift-owned → consumer** — an opaque `+1`-retained pointer box
   (`SwiftFFIBox_<Proto>`, `Generator+SwiftGlue.swift:285`), freed by a generated
   `_release` cdecl. Consumer wrappers own it: TS `Swift<Proto>` with
   `close()` / `Symbol.dispose` + a `FinalizationRegistry` backstop
   (`Generator+TypeScript.swift:362`), Kotlin `Swift<Proto> : AutoCloseable`.

2. **Consumer → Swift** — an integer→object registry: `registerForeign()` returns an
   incrementing id (`runtime/ts/swift_ffi_runtime.ts:90`; native peer
   `SwiftFFIWasmHost.swift:192`). The Swift side gets a generated
   `SwiftFFIForeign_<Proto>` proxy (`emitWasmForeignProxy`,
   `Generator+SwiftGlue.swift:51`) holding a `foreignID: Int32`, implementing the
   protocol by calling `@_extern(wasm)` imports and freeing the registry slot in
   `deinit`.

Interface params cross as a **dual slot** `(swift_handle_ptr, foreign_id)` with
exactly one side set; `swiftFFIResolve_<Proto>` picks the box or constructs the proxy
(`Generator+SwiftGlue.swift:526`).

**Design rule for both features:** stay inside these two primitives. Do not invent a
new wire type — every one costs emission across all eight backends
(`swift-glue-c`, `swift-glue-wasm`, `swift-glue-jni`, `c-header`, `ts`, `kotlin`,
`swift-host-wasm`, `c-host-wasm`; `GeneratorKind`).

---

## 2. Closures — desugar to a synthesized single-method interface

A `(A) -> B` closure is isomorphic to `protocol { func call(_ a: A) -> B }`. So the
work is mostly **analyzer sugar**, not new runtime:

1. When the analyzer (`ExportCollector`) sees a function-typed parameter
   (`FunctionTypeSyntax`), synthesize an anonymous single-method `FFIInterface`
   (e.g. `SwiftFFIClosure_<hash>`) and rewrite the parameter's type string to
   reference it.
2. Reuse the existing foreign-registry + `SwiftFFIForeign_<Proto>` proxy path
   verbatim. A closure passed *into* Swift becomes a foreign object; each invocation
   is the method-dispatch-back-out that already works.

Per-backend emission cost is close to zero — it is the interface path already emitted.
The real design decisions are the semantics the sugar cannot hide:

- **Direction & lifetime.** Closure *in* (callback) = foreign object, easy.
  Escaping/stored closures need the registry entry to outlive the call (the registry
  already does this) plus an explicit release contract (proxy `deinit` vs consumer).
  Non-escaping is strictly easier (release at call return). Suggest: support
  `@escaping`-in first; defer closure *returns* — interface-returns-from-foreign-impls
  is the one case already explicitly rejected (`Generator+Validation.swift:57`), and
  closures-returning-closures inherit that.
- **Arity / tuples.** Single arg maps cleanly; multi-arg reuses the 8-byte-slot
  struct packing (`emitCStructHelpers`), or canonicalize `(A, B) -> C` to a struct
  param.
- **Threading (see §4).** With the multithreaded `WASIGlobalExecutor`, a Swift-side
  closure invocation can originate on a worker thread, but the foreign registry
  (`Map<number, unknown>` in TS) and the host callback are single-threaded. Callbacks
  crossing back must hop to the main executor or they race. Decide the contract up front.
- **Errors / async.** `throws` closures reuse the existing `error_out` slot; `async`
  closures want the continuation resumed via the executor. Phase 2.

---

## 3. Generics — the monomorphization wall, with one free case

You cannot pass an unbounded `T` across a C ABI. There are three honest strategies,
and the right one is **different per generic shape**:

| Swift shape | Strategy | Cost |
|---|---|---|
| `func f<T: P>(_ x: T)` — constrained, used only through the protocol | **Erase `T` to the constraint handle**: `T` crosses as `SwiftFFIForeign_P` / box. Falls out of the existing interface path for free. | ~zero |
| `struct Box<T>` / `func f<T>(_ x: T)` where `T` is used by value | **Explicit monomorphization**: user declares instantiations (e.g. `@ExportedSpecialization(Box<Int>, Box<String>)`); generator emits one concrete binding per instantiation | N× bindings, reuses scalar/struct emission |
| Unconstrained `T` used structurally, no declared instantiations | **Reject with a real diagnostic** | — |

Today (per the analyzer) a `<T>` param is silently captured as the literal string
`"T"` and dies later in whole-module validation as "type 'T' is neither bridgeable nor
an @ExportedInterface/@ExportedStruct" — confusing. **Step 0** is a
`GenericParameterClauseSyntax` check in `ExportCollector` that emits a targeted
diagnostic: "generic parameters require `@ExportedSpecialization` or a protocol
constraint." A couple hours; makes the whole feature legible.

The framing to build the plan around: **constrained generics are just the interface
path.** If users are told "make `T` conform to an `@ExportedInterface` protocol,"
generics mostly reduce to the handles/closures already supported. Reserve true
monomorphization for value-semantic containers, and make it **explicit** rather than
inferring instantiations from call sites (much more analyzer machinery, fragile).

---

## 4. Threading contract (underpins both)

Both features cross the boundary via the foreign registry, which is single-threaded on
the consumer side (TS/host). After the wasi-threads `WASIGlobalExecutor` work
(swiftlang/swift #90715), Swift async work can run on worker threads, so a callback or
an erased-generic method call can originate off the main thread.

Open question: should foreign callbacks **always resume on the main executor** (safe,
simple, matches JS/host single-threadedness) or should worker-thread callbacks be
exposed for compute (faster, but the registry and host bridge need synchronization)?
Recommend main-executor-by-default; revisit if a compute use case demands it.

---

## 5. Recommended phasing

1. **Step 0 — generics diagnostic.** Recognize `GenericParameterClauseSyntax`; emit the
   explicit "needs specialization or constraint" error instead of the confusing
   unknown-type-name failure.
2. **Closures, in-only, non-escaping then escaping.** Synthesized single-method
   interface + existing foreign path. Settle the main-executor callback contract here —
   generics-via-handles will need the same contract.
3. **Constrained generics `<T: P>`.** Mostly analyzer work to erase `T` to the
   constraint's interface handle; reuses closures/interface runtime.
4. **Explicit monomorphization for containers.** `@ExportedSpecialization`; generator
   emits one concrete binding per declared instantiation.
5. **(Later)** closure/interface returns from foreign impls; `async`/`throws` closures.

## Open decisions

- **Order** — closures before generics? (higher everyday value, lower risk, forces the
  threading contract early). *Leaning yes.*
- **Closure direction scope** — in-only (callbacks) vs also Swift returning/storing
  closures? *In-only is dramatically simpler and covers most UI event cases.*
- **Generics philosophy** — require explicit `@ExportedSpecialization` for containers
  (keeps the C ABI honest) vs infer instantiations from call sites (fragile)?
  *Leaning explicit.*
- **Threading** — foreign callbacks always on the main executor, or expose
  worker-thread callbacks for compute? *Leaning main-executor default.*

## Key code references

- Type allow-list: `swift_ffi/swift_ffi_plugin_library/BridgeValueType.swift:5`,
  `BridgeTypes.swift:38-48`, `Generator+Validation.swift:13-37`
- IR: `swift_ffi/swift_ffi_ir_library/{FFIModule,FFIFunction,FFIParameter}.swift`
- Analyzer: `swift_ffi/.../ExportCollector.swift` (no generics/closure handling today)
- Foreign registry + proxy: `runtime/ts/swift_ffi_runtime.ts:90`,
  `runtime/swift_wasm_host/SwiftFFIWasmHost.swift:192`,
  `Generator+SwiftGlue.swift:51` (`emitWasmForeignProxy`), `:285` (box), `:526` (resolve)
- Backends: `swift_ffi/swift_ffi_generator_library/GeneratorKind.swift`,
  one `Generator+<Backend>.swift` per target
