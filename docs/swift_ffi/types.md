# The type system and C ABI

What can cross the bridge, what it looks like on each side, and the naming and
marshaling conventions the generated code follows. This is the authoritative
reference; the README carries only the summary table. See
[ownership.md](ownership.md) for the lifetime rules and
[structure.md](structure.md) for where the code implementing all of this lives.

## Bridgeable types

Values are copied at the boundary; exported interfaces cross as owned handles.

| Swift                | C ABI                      | Kotlin        | TypeScript    |
| -------------------- | -------------------------- | ------------- | ------------- |
| `Int`                | word-sized int¹            | `Long`        | `number`      |
| `Int32`              | `int32_t`                  | `Int`         | `number`      |
| `Double`             | `double`                   | `Double`      | `number`      |
| `Bool`               | `int8` (0/1)               | `Boolean`     | `boolean`     |
| `String`             | `(ptr, len)` UTF-8 / box²  | `String`      | `string`      |
| `[UInt8]`            | `(ptr, len)`               | `ByteArray`   | `Uint8Array`  |
| `@ExportedStruct`    | packed field buffer        | data class    | object        |
| exported interface   | opaque handle              | wrapper class | wrapper class |
| `Void` return        | —                          | `Unit`        | `void`        |

¹ **Swift `Int` is the platform word**: 64-bit on Android (`jlong`), 32-bit on
wasm32 (`i32` — TS `number`, no BigInt). Use `Int32` when you need a
guaranteed width. The generator and this table encode the same rule — keep
them in sync when changing either.

² A `String` *parameter* passes in as `(pointer, byteLength)` UTF-8, copied
into a `Swift.String`. A `String` *return* is a +1 box handle the consumer
drains and then releases (`string_len` / `string_copy` / `string_release`).
JNI uses `jbyteArray` in both directions.

The allow-list lives in two places, deliberately: per-declaration checks at
macro time (`swift_ffi_plugin_library/BridgeTypes.swift`, over the scalars in
`BridgeValueType.swift`), and the authoritative whole-module validation after
IR merge (`swift_ffi_generator_library/Generator+Validation.swift`). Macro
checks are heuristic (a capitalized identifier *might* be an exported
interface); the generator has the whole module and gives the real diagnosis.

## Effects: `throws`, `Result`, `async`

Effects are supported on **free functions only** — interface methods take no
effects (an entry on the roadmap).

- **`throws` / `Result<T, E>`** both bridge the same way: the C ABI grows a
  trailing `void **error_out` slot; Kotlin receives `Result<T>` (failures wrap
  the generated `SwiftError`, thrown as a pending JNI exception on Android);
  TypeScript receives a `Result` discriminated union.
- **`async`** becomes a Kotlin `suspend` function (stdlib `suspendCoroutine`
  over generated `Completion_<fn>` objects) and a TypeScript `Promise` (a
  call-id registry with per-function completion imports).
- **`async throws`** composes: a suspend/Promise of `Result`.

Two platform notes behind `async`:

- **wasm**: the glue installs `swift_task_enqueueGlobal_hook`, forwarding jobs
  through a `task_enqueue` import to a host microtask that calls the
  `task_run` export (JavaScriptKit's pattern). Timers are not wired yet, so
  `Task.sleep` has no driver.
- **Android**: Swift concurrency needs libdispatch. rules_swift's Android
  toolchain links `-ldispatch -lBlocksRuntime` itself (upstreamed in
  bazelbuild/rules_swift#1830) because autolink extraction cannot see the
  C++-object dependencies inside `libswift_Concurrency.a`. Unused symbols are
  GC'd, so this is free for code that doesn't use concurrency. No consumer or
  rule flags needed.

## Symbol naming

- **C symbols**: `swift_ffi_<module_lowercased>_<name>` for free functions;
  `swift_ffi_<m>_<Proto>_<method>` for interface methods; one `…_release` per
  interface. Runtime helpers:
  `swift_ffi_alloc` / `dealloc` / `string_len` / `string_copy` /
  `string_release`.
- **JNI symbols**: `Java_<pkg with _>_<Class>Native_<name>Raw`. The `Raw`
  suffix is camelCase-appended **without an underscore** — an underscore would
  JNI-mangle to `_1` and break the symbol match.
- **TypeScript** escapes JS reserved words in generated identifiers (a Swift
  argument label `for` becomes `for_`).

## Generated-shape constraints (do not "simplify" these)

- **Kotlin**: the externals live on an `internal object <Class>Native` whose
  members are *public*, fronted by a public `object <Class>` facade. Kotlin
  mangles the JVM names of `internal` members (`greetingRaw$module`), which
  silently breaks the `Java_*` symbol match and surfaces only at runtime as
  `UnsatisfiedLinkError`. The two-object shape is load-bearing.
- **Interface callbacks over wasm** are `@_extern(wasm)` imports in module
  `"swift_ffi"`; the reactor builds with
  `-enable-experimental-feature Extern`. The `ts` generator kind pairs with
  `swift-glue-wasm`; plain C pairs with `swift-glue-c`.

## What is rejected today

Generics and closures (function-typed parameters) are not yet bridgeable —
[generics.md](generics.md) is the design for adding them. Interface-typed
*returns* from consumer-implemented (foreign) interface implementations are
rejected by the generator; every other interface direction works (see
[ownership.md](ownership.md)).
