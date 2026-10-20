# swift_ffi

An idiomatic cross-language bridge for the platforms
[`rules_swift`][rules_swift] supports. Annotate Swift declarations with
macros, wrap the unchanged `swift_library` in a per-platform Bazel rule, and
get native bindings that let C, Kotlin or TypeScript consume your Swift code as
if it were written natively.

```
application  ->  swift_ffi  ->  rules_swift
```

**Why**: share one Swift core across every platform without writing FFI glue
by hand and without leaking C into your Kotlin or TypeScript. Values cross as
real native types (a copy at the boundary beats an abstraction leak), object
lifetimes follow [swift-java]'s proven arena model, and everything bottoms out
in a plain C ABI — no serialization framework on the call path.

## Who consumes what

| You are writing… | You use | You get |
| --- | --- | --- |
| an Android app (Kotlin) | `kt_swift_library` | a JNI `lib<name>.so` + idiomatic Kotlin bindings (`use { }`, `suspend`, `Result<T>`) |
| a web app (TypeScript) | `ts_swift_wasm_library` | a wasm reactor + a strict-mode TypeScript module (`using`, `Promise`, `Result` unions) |
| an Apple / Linux / Windows app (C++) | `cc_swift_library` | idiomatic C++ over the bridge (templates, std::function, RAII wrappers) |
| a Rust crate | `rs_swift_library` | generated Rust bindings over the bridge |
| a native host that loads Swift as wasm (dynamic delivery, no recompile) | `c_host_library` / `swift_wasm_library` | C or Swift host bindings that drive the reactor under a bundled [WAMR][wamr] engine |

On Apple platforms you can also skip the bridge entirely and import the
annotated library directly — the macros are inert there.

## How it works

1. **Annotate.** The `SwiftFFI` module provides four macros:
   `@ExportedFunction` (free functions), `@ExportedStruct` (flat value
   types), `@ExportedEnum` (raw-value enums), and `@ExportedInterface`
   (protocols — instances cross in *both* directions: Swift-owned ones as
   owned handles behind idiomatic wrappers, consumer-implemented ones as
   foreign objects Swift calls back into).

   ```swift
   import IsomerFFI

   @ExportedFunction
   public func greeting(for name: String) -> String {
       "Hello from Swift, \(name)!"
   }

   @ExportedInterface
   public protocol Counter {
       func increment() -> Int
       func label() -> String
   }
   ```

   The macros validate the signature at compile time AND expand the
   module's entire C ABI in place: each exported declaration gains peer
   `@c(swift_ffi_[<namespace>_]<name>)` entry points (SE-0495 — no
   underscored attributes anywhere), so the annotated `swift_library` is
   fully self-contained. Compiled Swift consumers just depend on it
   directly. An interface declared `@_spi(Name)` gets its public peers
   declared `@_spi(Name)` too, so a library can keep its host interface out
   of its public API (Isomer's SwiftUI does).

2. **Analyze & generate.** At build time an analyzer extracts the exported
   surface into a small JSON IR, and a generator emits the idiomatic
   consumer bindings against the same symbols the macros expanded
   ([docs/abi.md](../docs/swift_ffi/abi.md)).

3. **Wrap.** You declare one per-platform target over your unchanged
   `swift_library` (one `.bzl` per macro under
   [`//swift_ffi/rules`](rules)) and depend on it like any native
   library.

## Getting started

swift_ffi is part of the [isomer](../README.md) Bazel module. Depend on that
(a `git_override` pin, until it is published to a registry; isomer's
root-only overrides are listed in [`examples/MODULE.bazel`](../examples/MODULE.bazel)):

```starlark
# MODULE.bazel
bazel_dep(name = "isomer", version = "0.1.0")
git_override(
    module_name = "isomer",
    remote = "https://github.com/AttilaTheFun/isomer.git",
    commit = "<main commit>",
)
```

Using swift_ffi alone builds nothing else of Isomer.

Annotate a `swift_library`, then wrap it for your platform:

```starlark
load("@isomer//swift_ffi/rules:kt_swift_library.bzl", "kt_swift_library")
load("@isomer//swift_ffi/rules:ts_swift_wasm_library.bzl", "ts_swift_wasm_library")
load("@isomer//swift_ffi/rules:cc_swift_library.bzl", "cc_swift_library")

# Android: lib<name>.so + Kotlin bindings.
kt_swift_library(name = "greeter_android", swift = ":greeter")

# Web: a wasm reactor + a TypeScript module.
ts_swift_wasm_library(name = "greeter_web", swift = ":greeter")

# Apple / Linux / Windows: idiomatic C++ over the C ABI.
cc_swift_library(name = "greeter_cpp", swift = ":greeter")
```

The [example matrix](../docs/swift_ffi/examples.md) is a full working reference for every
platform — `examples/shared/greeter` is one annotated library, and each
`//swift_ffi/examples/<platform>/...` application delivers it unchanged, either
**compiled** (natively linked over the C ABI) or as **wasm** (a reactor under
WAMR, or the browser itself on the web).

## Bridgeable types

Values are copied at the boundary; exported interfaces cross as owned handles.

| Swift                | Kotlin        | TypeScript    |
| -------------------- | ------------- | ------------- |
| `Int`¹               | `Long`        | `number`      |
| `Int32`              | `Int`         | `number`      |
| `Double`             | `Double`      | `number`      |
| `Bool`               | `Boolean`     | `boolean`     |
| `String`             | `String`      | `string`      |
| `[UInt8]`            | `ByteArray`   | `Uint8Array`  |
| `@ExportedStruct`    | data class    | object        |
| exported interface   | wrapper class | wrapper class |
| `Void` return        | `Unit`        | `void`        |

¹ `Int` is the platform word — 64-bit on Android, 32-bit on wasm32; use
`Int32` for a guaranteed width.

Free functions may also be `throws` or return `Result<T, E>` (→ Kotlin
`Result<T>` / a TypeScript `Result` union) and may be `async` (→ Kotlin
`suspend` / a TypeScript `Promise`); `async throws` composes. The C ABI, the
effect mappings, and the naming conventions are specified in
[docs/types.md](../docs/swift_ffi/types.md).

## Memory & ownership

Ownership follows [swift-java]'s `SwiftArena` model; ARC and the consumer's
GC are never coupled:

- One owning runtime per object; the other side holds an opaque handle.
- Returns are +1, parameters are +0; release happens exactly once, through
  generated entry points — consumers never touch reference counts.
- Deterministic disposal (`use { }` / `using`) with an automatic
  finalizer/registry backstop for leaks; double-release is guarded.
- Consumer-implemented interfaces invert the model: Swift holds a proxy that
  calls back out and releases on `deinit` — nothing to `close()`.

The full model — the handle primitives, both interface directions, and the
cross-heap cycle hazard — is in [docs/ownership.md](../docs/swift_ffi/ownership.md).

## Status & roadmap

v0 works end to end: the shared greeter (functions, structs, interfaces both
directions, `throws`, `async`, bytes) runs on web, Android, iOS, Linux, and
Windows — see [docs/examples.md](../docs/swift_ffi/examples.md) for what each cell
verifies. On the roadmap: optionals/arrays, typed errors, wasm timers,
effectful interface methods, and [closures & generics](../docs/swift_ffi/generics.md).

## Documentation

- [docs/structure.md](../docs/swift_ffi/structure.md) — contributor's map: every target
  and how the pipeline fits together. Start here to work on swift_ffi itself.
- [docs/types.md](../docs/swift_ffi/types.md) — the type system, effect mappings, and the
  C ABI / symbol naming conventions.
- [docs/ownership.md](../docs/swift_ffi/ownership.md) — the memory & ownership model in
  full.
- [docs/examples.md](../docs/swift_ffi/examples.md) — the platform × mode example matrix:
  what runs where, and how.
- [docs/toolchains.md](../docs/swift_ffi/toolchains.md) — toolchain pins, why each exists,
  and hard-won build gotchas.
- [docs/abi.md](../docs/swift_ffi/abi.md) — the C ABI contract (macro-expanded `@c`
  symbols, the erased blob encoding, the fixed wasm import set) and how each
  language calls across it.
- [docs/generics.md](../docs/swift_ffi/generics.md) — superseded design notes (v1 model).

Licensed under Apache-2.0 ([LICENSE](LICENSE)).

[rules_swift]: https://github.com/bazelbuild/rules_swift
[swift-java]: https://github.com/swiftlang/swift-java
[wamr]: https://github.com/bytecodealliance/wasm-micro-runtime
