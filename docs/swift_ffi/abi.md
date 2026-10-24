# The C ABI

The contract every bridge crosses. The ABI of a bridged module is generated
**inside the module itself**: the `SwiftFFI` macros (`@ExportedFunction`,
`@ExportedInterface`, `@ExportedStruct`, `@ExportedEnum`) expand each
annotated declaration into peer `@c` entry points (SE-0495 — no underscored
attributes), so the annotated `swift_library` is self-contained and every
language meets it at the symbol level. It is an implementation detail:
applications consume the per-language bindings (`cc_swift_library`,
`kt_swift_library`, `ts_swift_wasm_library`, `swift_wasm_library`,
`c_host_library`, `rs_swift_library`), never these symbols. The shared
vocabulary (`bridge_closure`, `bridge_buf`, the blob tags, the allocator, the
fixed-name runtime entries) is hand-written in
[`swift_abi.h`](../../swift_ffi/runtime/swift_abi/swift_abi.h); the consumer-side
bindings are generated from the module's IR by a Bazel aspect + generator that
agree with the macro expansions symbol-for-symbol.

## The contract

**Symbols.** One entry per exported free function:
`swift_ffi_[<namespace>_]<name>`, where `<namespace>` is the optional
per-declaration `@ExportedFunction(namespace: "…")` segment (macros expand one
declaration at a time, so the namespace is written on the declaration — it is
not derived from the module). Interfaces contribute three entries each:
`swift_ffi_[<ns>_]<Proto>_invoke`, `…_<Proto>_release`, and
`…_register_<Proto>` (dependency injection, below). The runtime entries are
FIXED names defined once per linked image by the `SwiftFFI` module itself:
`swift_ffi_alloc`, `swift_ffi_dealloc`, `swift_ffi_string_len`,
`swift_ffi_string_copy`, `swift_ffi_string_release`, `swift_ffi_lazy_get`,
`swift_ffi_lazy_release` (and, on wasm, `swift_ffi_task_run`).

**Scalars** pass flat: Swift `Int` as `intptr_t`, `Int32`, `double`, `bool`.

**Strings and byte arrays** pass as borrowed `(const void *, int32_t)` UTF-8 /
raw bytes on the way in, and as **+1 boxes** on the way out: an opaque
`void *` the consumer drains with `swift_ffi_string_len` /
`swift_ffi_string_copy` and then releases exactly once with
`swift_ffi_string_release`.

**Erased values** — struct/enum copies, `Result` values, generic arguments,
closure arguments, interface METHOD arguments, `Lazy` payloads — cross as
**blobs**: self-contained little-endian byte sequences, `(ptr, len)` borrowed
in and a +1 box out (drained with the same string-box entries). The wire
format (specified in `swift_abi.h`): `i32 tag, i32 aux`, then per tag —

| tag | payload |
| --- | --- |
| 0 VOID | — |
| 1 INT / 4 BOOL | `i64` (bool 0/1) |
| 2 INT32 | `i64` (widened) |
| 3 DOUBLE | `f64` bits |
| 5 STRING / 6 BYTES / 10 ERROR | `i64` length, then the bytes |
| 7 STRUCT | aux = the struct NAME's byte length; the name; `i64` field count, then each field's blob |
| 8 LIST | `i64` element count, then each element's blob — the general ordered composite generic containers encode through: `Result` = [isError bool, payload], `Array` = its elements, `Dictionary` = alternating key/value |
| 9 HANDLE | aux = the interface NAME's byte length; the name; `i64` = a Swift box handle (+1 crossing producer → consumer; borrowed for the call consumer → producer) |
| 11 FOREIGN | aux = the interface NAME's byte length; the name; `i64` = a consumer implementation's ref (a foreign-registry id on wasm, a `bridge_closure *` natively) |

Types are identified on the wire **by name** — the encoding is
self-describing and there are no generation-time ordinal tables. There are
**no generics in the ABI**: a generic export's C entry takes blobs where `T`
appears (a trampoline re-types them through implicitly-opened existentials;
composite values bind opaquely to the `BridgeList` / `BridgeStruct` carriers),
and each language re-types on its own side.

**Interfaces** cross function boundaries as a dual slot: producer-owned
instances as an opaque +1 handle (released once via `…_<Proto>_release`),
consumer implementations as a **dispatcher** (below) with the unused slot
NULL/0. Method calls on producer-owned instances are **ordinal dispatches**
through one entry per interface:

```c
void *swift_ffi_[<ns>_]<Proto>_invoke(void *handle, int32_t ordinal,
                                      const void *args, int32_t args_len);
```

`args` is a borrowed concatenation of the method's argument blobs (ordinals
are the methods' source order); the return is a +1 box of the result blob —
a VOID blob for void, an ERROR blob on failure.

**Closures and dispatchers.** Consumer → producer callbacks all cross the ONE
dispatcher channel: closures, consumer-implemented interfaces, and injected
dependencies alike. A dispatcher receives the concatenated argument blobs
(interface dispatch leads with an `.int32` method ordinal) and returns the
result blob (or an ERROR blob). Natively a dispatcher is a `bridge_closure`
vtable `{ctx, invoke, retain, release}` (the producer retains the context
while an escaping capture holds it and releases exactly once); on wasm it is
an id into the host's foreign registry, dispatched through the fixed
`closure_invoke` import.

**Errors.** A throwing function takes a trailing `void **error_out`: NULL on
success, a +1 string box with the message on failure (the return value is
then zero/NULL).

**Async.** On native platforms an async function takes a trailing
`const bridge_closure *completion`, invoked (from the producer's executor,
i.e. possibly another thread) with the result blob — or an ERROR blob. On
wasm the entry takes a leading `int32_t call_id` and completes through the
fixed `async_complete` import.

**Lazy.** A `Lazy<T>` return is an opaque +1 handle; `swift_ffi_lazy_get`
computes (once, producer-side) and returns a +1 blob box;
`swift_ffi_lazy_release` releases the handle exactly once.

**Wasm.** A reactor's exports are this same ABI, staged in wasm memory
(buffers crossing in are allocated via the exported `swift_ffi_alloc`). Every
reactor imports the same FIXED five-entry `swift_ffi` module — the `SwiftFFI`
runtime references them unconditionally and reactors link with
`--no-gc-sections`, so hosts always bind all five:

| import | contract |
| --- | --- |
| `closure_invoke(id, args_ptr, args_len) -> u64` | run one dispatcher; returns a packed `(len << 32) \| ptr` result blob (`swift_ffi_alloc`'d, guest frees) |
| `foreign_release(id)` | drop one foreign-registry entry |
| `dependency_get(key_ptr, key_len) -> u64` | resolve a dependency key: 0 when absent, else a packed +1 blob of `.list([.bool(lazy), .string(registry key), .int32(id)])` |
| `task_enqueue(job)` | schedule a Swift concurrency job (the host queues a microtask calling the `swift_ffi_task_run` export) |
| `task_enqueue_after(job, delay_ms)` | schedule a timed job (`Task.sleep`): the host runs it through `swift_ffi_task_run` once `delay_ms` milliseconds have passed (a timer on the web; the C host parks it with its deadline, `swift_ffi_host_next_job_delay_ms` says when to drain) |
| `async_complete(call_id, blob_ptr, blob_len)` | deliver an async export's completion blob |

**Dependency injection** (docs/wasm_di.md). Each interface's macro-expanded
`swift_ffi_[<ns>_]register_<Proto>` export registers a typed proxy factory in
the guest under the interface's **registry key** — `swift_ffi_[<ns>_]<Proto>`.
Generated host loaders call every register export at setup; when guest code
resolves `dependencies[key]`, the runtime asks `dependency_get`, matches the
answered registry key to a factory, and constructs a typed dispatcher-backed
proxy (wrapped in `Lazy` when the host injected lazily). In-process compiled
embeddings skip all of this: `installDependencies` installs real instances.

## Swift

The producer side is entirely macro-expanded, inside the annotated module:
`@c` entry thunks decode blobs via `SwiftFFIBlob`, re-type generic entries
through trampolines, wrap dispatchers in typed Swift closures
(`SwiftFFIClosureBox` natively, `SwiftFFIWasmDispatcher` on wasm — one
generated proxy class per interface serves both), box returns +1, and host
`Lazy` computations behind `SwiftFFILazyBox`. Where the native and wasm
shapes differ the expansion carries both under `#if os(WASI)`. Compiled Swift
consumers don't cross the ABI at all — they depend on the annotated library
directly. (Swift-to-Swift and Swift-consuming-C++ interop live in the
separate `swift_interop` project.)

An interface's isolation is the protocol's. A `@MainActor` protocol's
Swift-owned instances are called on the main actor (the `_invoke` entry
hands only the handle's bits and the argument bytes to a main-actor
dispatch), and its proxy is a `nonisolated` class, made anywhere, whose
methods witness the main-actor requirements. A protocol that inherits
`Sendable` gets a Sendable proxy (dispatchers are Sendable), so an app can
hand a host's implementation across isolations without an escape hatch.

`swift_wasm_library` is Swift as a wasm **host**: generated bindings drive a
reactor through an injected `SwiftFFIWasmEngine` — `Swift<Proto>` wrappers
dispatch through `_invoke`, native implementations are parked in the foreign
registry as ordinal dispatchers, async pumps the cooperative executor, and
`load(engine:wasm:dependencies:)` binds the fixed import set and calls the
register exports. This is the seam behind isomer's WasmView pattern.

## Kotlin

Kotlin calls the ABI through a generated **C JNI adapter** — pure marshaling,
no bridge semantics: `Java_<pkg>_<Class>Native_<fn>Raw` symbols map
`jbyteArray ↔ (ptr, len)`, drain +1 boxes into `byte[]`, and wrap Kotlin
callback objects in `bridge_closure` vtables (a `JavaVM` global ref as
context; invoke attaches the calling thread and calls
`swiftffi.SwiftClosure.invoke([B)[B`). Interface method calls go through one
`<proto>InvokeRaw(handle, ordinal, args)` external per interface. Above the
adapter, the generated Kotlin builds blobs with `swiftffi.BridgeBlob` (struct
codecs registered per class, keyed by wire name), exposes generics as
`inline reified` functions, closures as lambdas, `Lazy` as
`swiftffi.SwiftLazy<T>`, async as `suspend` functions resumed by a completion
dispatcher, and interfaces as `AutoCloseable` `Swift<Proto>` wrappers with
`ForeignDispatcher_<Proto>` for Kotlin implementations.

## TypeScript

TypeScript consumes the **wasm flavor**: the reactor's exports are the ABI.
The generated module stages buffers and blobs into wasm memory with
`swift_ffi_alloc`, drains boxes back out, and registers callbacks, interface
implementations, and injected dependencies in the foreign registry as ordinal
dispatchers (`makeDispatcher_<Proto>`), all dispatched back through the one
`closure_invoke` import. TS generics are erased at runtime, so generic calls
take one **type token** per type parameter (`Types.int`,
`Types.result(...)`, a generated `<Struct>Type`); `Lazy<T>`, `Result<T>`,
`SwiftError`, and the blob machinery come from the staged shared runtime
(`swift_ffi_runtime.ts`). Async exports resolve Promises via the
task-enqueue microtask pump and the fixed `async_complete` import (each
pending call carries its own blob decoder).

## C

C is the contract itself: the generated `<bridge>.h` (which includes
`swift_abi.h`) declares every symbol above, and a C translation unit may call
them directly — stage UTF-8, drain boxes, fill a `bridge_closure` with
function pointers. In practice C is not a consumption target: the header
exists for the per-language layers, and the `c_host_library` path (a C host
driving a *reactor* with no compiled Swift) generates a separate
`c-host-wasm` header over the reactor flavor of the same contract — its
representable subset is scalars, String, `[UInt8]`, and host-implementable
interfaces (as vtables bridged into blob dispatchers).

## C++

C++ is a **consumer** (`cc_swift_library`): the generated header-only
bindings call the C symbols through
[`swiftffi.hpp`](../../swift_ffi/runtime/cpp/swiftffi.hpp): `swiftffi::traits<T>`
encode/decode blobs (generated specializations per struct, named on the
wire), generic exports are real templates, closures are `std::function`
wrapped by `swiftffi::Closure` (exceptions become ERROR blobs),
producer-owned interfaces are RAII `Swift<Proto>` wrappers dispatching
through `_invoke`, C++ implementations cross as `std::shared_ptr` behind a
generated dispatcher, `swiftffi::Result<T>` and `swiftffi::Lazy<T>` carry
failures and deferred values, and async takes a completion `std::function`.
(C++ as a *producer* — Swift consuming C++ — lives in `swift_interop`.)

## Rust

Rust is a **consumer** (`rs_swift_library`): the generated crate declares
the C symbols in an `extern "C"` block and wraps them idiomatically — `&str`
/ `&[u8]` staged as `(ptr, len)`, +1 boxes drained into `String` / `Vec<u8>`,
structs copied through an inlined blob codec, and throwing functions surfaced
as `Result<T, String>`. The generated file is self-contained (no runtime
crate); v1 covers scalars, strings, bytes, structs, and throwing functions —
closures, `Lazy`, generics, interfaces, and async are not yet emitted for
Rust.
