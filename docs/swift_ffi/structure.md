# Repository structure

A guided tour for engineers new to developing swift_ffi itself. It maps every
Bazel package to its role in the system and shows how a change flows through
them. Read [README.md](../../swift_ffi/README.md) first for the consumer-facing story; the
companion references are [types.md](types.md) (the bridge contract and ABI),
[ownership.md](ownership.md) (lifetimes), [examples.md](examples.md) (the
platform matrix), and [toolchains.md](toolchains.md) (pins and build
gotchas). This doc is about where the code lives and how the pieces fit.

## The system in one paragraph

swift_ffi turns an annotated `swift_library` into idiomatic bindings for
another language. The **macro plugin** validates each annotation AND expands
the module's C ABI in place — peer `@c(swift_ffi_[<ns>_]<name>)` entry points
compiled into the annotated library itself (docs/abi.md), so there is no
generated glue module anywhere. At build time an **analyzer** (driven by a
Bazel aspect) extracts the exported surface into a JSON **IR**, and a
**generator** emits the CONSUMER-side bindings from that IR (Kotlin,
TypeScript, C++, a C header, or Swift host bindings) against the same
symbols. Small per-language **runtime** libraries provide the shared
machinery the generated code leans on (handle boxes, dispatcher registries,
string marshaling); for wasm delivery a native Swift host runs the reactor
under an engine it injects (Isomer's hosts use WasmKit; WAMR, which the
repo bundled until 0.38, is gone). Everything meets at a C ABI; no serialization framework sits on the
call path.

```
@ExportedFunction / @ExportedStruct / @ExportedEnum / @ExportedInterface
        │  (macros: validate + expand the @c ABI into the module)
        ▼
swift_ffi_analyzer  ──(aspect, per source file)──▶  JSON IR
        │
        ▼
swift_ffi_generator ──(ffi_generate, per kind)──▶  C header │ TS │ Kotlin │ C++ │ hosts
        │
        ▼
per-platform macros (kt_swift_library, ts_swift_wasm_library, cc_swift_library, …)
        │
        ▼
runtime libraries (ts / kotlin / cpp / c_host / swift_wasm_host)
```

## Directory map

| Path | What lives there |
| --- | --- |
| `swift_ffi/swift_ffi/` | The public `SwiftFFI` macro module consumers import |
| `swift_ffi/swift_ffi_plugin/`, `_plugin_library/` | The compiler plugin implementing the macros |
| `swift_ffi/swift_ffi_analyzer/`, `_analyzer_library/` | The swift-syntax source analyzer |
| `swift_ffi/swift_ffi_ir_library/` | The JSON IR types shared by analyzer and generator |
| `swift_ffi/swift_ffi_generator/`, `_generator_library/` | The code generator, one extension file per backend |
| `swift_ffi/*_tests/` | `swift_test` suites for plugin, analyzer, and generator |
| `swift_ffi/rules/` | The Bazel layer: one `.bzl` per public macro + internal `utils.bzl` (aspect, `ffi_generate`, transitions) + the cross-compilation `platform()`s |
| `swift_ffi/runtime/` | Per-language runtime halves |
| `examples/` | The runnable platform × mode matrix over one shared greeter module |
| `tools/` | Build helpers for examples (e.g. `electron.bzl` for the web cell) |
| `docs/` | Design docs (this file, [generics.md](generics.md)) |

## The pipeline, package by package

### 1. `//swift_ffi/swift_ffi` — the public macro module

`swift_library` named `SwiftFFI`; the only target application code imports.
Declares `@ExportedFunction`, `@ExportedStruct`, `@ExportedEnum`, and
`@ExportedInterface`, attaches the plugin, and carries the RUNTIME the
expansions call — the blob codec (`SwiftFFIBlob`), the boxes and dispatchers,
the fixed-name shared `@c` exports (`swift_ffi_alloc`, the string/Lazy boxes),
the wasm import shims and executor, and the dependency-injection registry.
One module, one dependency: macro expansions compile inside the CONSUMER's
module and can only reference what it imports, which is exactly `SwiftFFI`.
(Swift forbids global peer macros introducing arbitrary names, so every
expanded Swift name uses a fixed prefix — `swift_ffi_<name>`,
`SwiftFFIBox_<Proto>`, … — while the free-form C symbol rides in the `@c`
attribute; interface METHODS therefore dispatch through one `_invoke` entry
per interface rather than per-method symbols.)

Also here: the `include_documentation` bool flag — DocC articles under
`swift_ffi.docc/` ride along as `data` only when
`--//swift_ffi/swift_ffi:include_documentation=true`, so ordinary consumer
builds don't pay for them.

### 2. `//swift_ffi/swift_ffi_plugin` (+ `_plugin_library`) — the macros

`swift_compiler_plugin` wrapping `swift_ffi_plugin_library`. The library holds
one `*MacroProtocol.swift` per macro plus the ABI emitters and shared
vocabulary:

- `ABIModel.swift` — the per-declaration signature model. Classification is
  SYNTACTIC (macros can't see the module): `any P` existentials are
  interfaces (Swift 6 enforces the spelling), the function's own generic
  parameters are generic, known spellings are scalars/buffers/Result/Lazy,
  and any other bare identifier is a `Bridgeable` value type.
- `ABIEmitter.swift` / `ABIEmitter+Interface.swift` — the `@c` entry-point
  emitters (function thunks, generic trampolines, async entries; interface
  boxes, `_invoke`/`_release`/`register` entries, foreign proxies). Where the
  native and wasm shapes differ, the expansion carries both under
  `#if os(WASI)`.
- `BridgeValueType.swift` / `BridgeTypes.swift` — the bridgeable-scalar
  vocabulary and syntax classifiers.

Macro-level checks are per-declaration; whole-module cross-checks (unknown
type names, interface/struct collisions) still happen in the generator's
validation, and a wrong bare-identifier guess surfaces as a clear "does not
conform to 'Bridgeable'" compile error in the expansion.

### 3. `//swift_ffi/swift_ffi_analyzer` (+ `_analyzer_library`) — source → IR

A thin `swift_binary` (`Analyze.swift`) over the library. `ExportCollector`
walks each Swift file with swift-syntax, collecting annotated declarations into
the IR types. It runs **per source file**, invoked by the analyzer aspect (see
§5), so analysis parallelizes and caches at file granularity.

### 4. `//swift_ffi/swift_ffi_ir_library` — the contract in the middle

Plain Codable structs (`FFIModule`, `FFIFunction`, `FFIInterface`, `FFIMethod`,
`FFIStruct`, `FFIField`, `FFIParameter`) serialized as JSON between analyzer
and generator. Types are carried as raw Swift source strings — there is no
rich type enum — which keeps the analyzer simple and defers meaning to the
generator's validation. If you change the IR, you touch both neighbors and
both test suites.

### 5. `//swift_ffi/rules` — the Bazel layer

One `.bzl` per public macro, plus the internal `utils.bzl` (the analyzer
aspect + provider, the `ffi_generate` rule, the platform transition, small
helpers) and the cross-compilation `platform()` targets in `BUILD.bazel`
(`//swift_ffi/rules:wasm32-wasip1`, `:android-aarch64`, `:android-x86_64`).
The macros compose the aspect + generator into the targets consumers declare
— and since the C ABI ships inside the annotated library, none of them
generates Swift glue:

  | Macro (its own `.bzl`) | Platform | Emits |
  | --- | --- | --- |
  | `kt_swift_library` | Android | JNI adapter `.so` (via transition) + Kotlin bindings |
  | `ts_swift_wasm_library` | web/wasm | wasm reactor + TypeScript module (+ staged runtime copy) |
  | `cc_swift_library` | Apple/Linux/Windows | idiomatic C++ over the C ABI |
  | `bridge_cc_library` | building block | the generated C header over the annotated library |
  | `c_host_library` | any C host | c-host bindings for driving a reactor under a C engine the host brings |
  | `swift_wasm_library` | Swift wasm hosts | generated Swift host bindings driving a reactor (explicit `swift_wasm_reactor` for the artifact) |
  | `rs_swift_library` | Rust | generated Rust bindings over the C ABI |
  | `swift_wasm_reactor` | building block | annotated library → `.wasm` reactor binary |

### 6. `//swift_ffi/swift_ffi_generator` (+ `_generator_library`) — IR → code

A thin `swift_binary` (`Generate.swift`) over the library, which is organized
as instance-state `Generator` plus **one extension file per backend**. The
backends (`GeneratorKind.swift`) and their pairings:

| Kind | Output |
| --- | --- |
| `c-header` | the C ABI header (declaring the macro-expanded symbols) |
| `jni-adapter` | the C JNI adapter mapping `Java_*` onto the C ABI |
| `kotlin` | idiomatic Kotlin bindings |
| `ts` | idiomatic TypeScript module |
| `cpp` | idiomatic header-only C++ bindings |
| `rust` | idiomatic Rust bindings |
| `swift-host-wasm` | native-Swift host bindings that drive a reactor |
| `c-host-wasm` | C host bindings that drive a reactor |

`Generator+Validation.swift` performs the whole-module validation (unknown
types, effect rules, the interface-return-from-foreign restriction). The
Swift-side marshaling model — the `SwiftFFIBox_<Proto>` owned-handle box, the
`SwiftFFIForeign_<Proto>` dispatcher proxy, the dual `(swift_handle, foreign)`
interface slot — lives in the MACRO plugin's `ABIEmitter*` files; the
backends here are consumer-side views of that contract. **A new feature
usually means touching the emitters AND every backend file** — partial
support fails consumers at build time.

### 7. `//swift_ffi/runtime/...` — the per-language runtime halves

Generated code is kept lean by pushing shared machinery into small runtimes:

| Package | Language | Role |
| --- | --- | --- |
| `runtime/swift_abi` | C | `swift_abi.h`: the shared vocabulary — blob tags, `bridge_closure`, the fixed runtime prototypes, the wasm import declarations (header-only) |
| `runtime/ts` | TypeScript | consumer-side registry/marshaling; `exports_files` only — `ts_swift_wasm_library` stages a copy next to each generated module |
| `runtime/kotlin` | Kotlin | `SwiftError` and shared consumer machinery |
| `runtime/c_host` | C | host runtime for driving reactors from C (`swift_ffi_host`) |
| `runtime/swift_wasm_host` | Swift | native-Swift host runtime (`SwiftFFIWasmHost`, `WasmBundleProvider`) for dynamically-delivered reactors |
Until 0.38 `runtime/wamr` vendored WAMR for the whole stack (with
`runtime/c_host_wamr`, its C host, and `//swift_ffi:wasm_aot_compiler`,
wamrc behind a label flag); they were removed with WAMR. The engine is the
host's now: Isomer's native hosts inject WasmKit (`WasmKitRuntime`,
//shared/wasm_host) through `runtime/swift_wasm_host`.

## `examples/` — the integration matrix

One annotated module — `//swift_ffi/examples/shared/greeter` — exercises the full
surface (functions, structs, interfaces both directions, `throws`, `async`,
bytes) and is delivered unchanged by every cell in the platform × mode matrix
(`compiled` = natively linked over the C ABI; `wasm` = reactor under an
engine). The shared building blocks:

- `greeter` — the annotated `swift_library` (self-contained C ABI), plus its
  generated C++ bindings, c-host bindings (for a C host with its own engine),
  and the `.wasm` reactor.
- `greeter_compiled_host` — the C driver for compiled mode (Linux/Windows
  cells are thin `main`s over it).
- `greeter_host` — the `swift_wasm_library` building block: native Swift host
  bindings + reactor, compile-checking the `swift-host-wasm` backend.

Per-platform apps live at
`//swift_ffi/examples/<platform>/example_<platform>_<mode>_application`;
[examples.md](examples.md) has the full matrix — which cells are runnable,
from which host OS, and what each verifies. Treat the examples as living
integration tests: a generator or runtime change isn't done until the
affected cells still build (and run, where the host OS allows).

## Developing in this repo

- **Tests**: `bazel test //swift_ffi/...` runs the plugin, analyzer, and
  generator suites. Generator tests assert on emitted source text, so
  intentional output changes mean updating expectations.
- **Warnings are errors** throughout `swift_ffi/` (each BUILD file's
  `package(features = …)`, Swift 6 mode).
- **Run the matrix** for anything touching generation or runtimes: at minimum
  the Linux-independent cells your host can build, e.g.
  `bazel build //swift_ffi/examples/...` on macOS covers the web, Android, iOS, and
  shared targets.
- **`--strategy=SwiftCompile=local`** is already in `.bazelrc` — macro
  expansion fails sandboxed (the plugin is host-built but loaded by the
  cross-compile frontend). Don't remove it. More build gotchas of this kind
  live in [toolchains.md](toolchains.md).
- **Where a change starts**: a new bridgeable type or effect starts in
  `ABIModel`/`BridgeTypes` (classification), then the `ABIEmitter*` files
  (the macro-expanded Swift side), then `Generator+Validation`, then each
  consumer backend extension, then the runtime halves that carry it, then the
  greeter (so the matrix proves it).

## Consumers

swift_gpu, swift_map and the SwiftUI libraries (the rest of the isomer
repository) build on this directory — the dependency only points downward, and
swift_ffi never references them. If you change a public label or
macro signature, fix the stack above you in the same commit.
