# Features as side modules over one runtime

docs/modes.md's first step: every mode gains. The linker is engine-neutral,
so a side module loads under WasmKit, in a browser and in a web view alike.
Mixed mode (native copies of the runtime's hot functions, for embedded
interpreted features: docs/modes.md, step 4) builds on this, in a pull
request of its own.

## The problem

A downloaded feature today is a reactor carrying its own copy of the Swift
standard library, Foundation and Isomer's SwiftUI. Even dead-stripped, the
smallest (the tap counter) is 16.5 MB raw, 4.8 MB gzip; the Storybook's app
18.3 MB, 5.4 MB gzip. A second feature pays it again, in download and memory.

## Side modules

Swift's wasm objects, and the Swift SDK's standard library, are position-
independent, so a feature links as a wasm **side module** over a **runtime
module**: the libraries once, every public symbol exported.

    load("@isomer//tools/wasm:side_modules.bzl", "wasm_runtime_module", "wasm_side_module")

    wasm_runtime_module(name = "runtime", deps = [<the reactor's libraries but the feature>])
    wasm_side_module(name = "feature", deps = [<the feature's own libraries>])

A loader places the side module as a dynamic loader places a shared library
(the WebAssembly tool conventions' DynamicLinking.md): its memory from the
runtime's allocator, its table slots at the table's end, its imports from the
runtime's exports and the side modules loaded before it, then its data
relocations and constructors (Swift's `swiftrt.o` registers its metadata).

- **The linker is engine-neutral.** `IsomerWasmDylink`
  (//shared/wasm_host:wasm_dylink) reads `dylink.0` and the imports, decides
  placement and bindings and runs relocations, over a small engine protocol;
  WasmKit's adapter is `WasmDynamicLinker` (and
  `WasmKitRuntime.loadSideModule`). Browsers and web views use its twin,
  wasm/libraries/swift_ui/runtime/side_modules.js. tests/wasm_dylink holds
  both to the same modules, built byte by byte: malformed and truncated
  `dylink.0`, out-of-range values, placement, binding order, relocations,
  table and memory growth, refusals.
- **wasm-ld.** Swift 6.4.2's wasm-ld gives Swift's relative pointers
  (`R_WASM_MEMORY_ADDR_LOCREL_I32`) a runtime relocation in a side module
  that adds `__memory_base`, breaking every conformance record; upstream
  LLVM rejects the relocation instead. tools/patches/lld_wasm_pic_locrel.patch
  is the fix (lld's tests pass with it, and a new one), to propose upstream.
  Until a swift.org toolchain has it, `wasm_side_module` links with the
  toolchain's wasm-ld and corrects the output: tools/wasm/side_module_fixup
  finds each relative pointer's site from the inputs' relocations and the
  link map, and removes exactly those stores (every site must be accounted
  for, or it fails).
- **What a runtime exports.** Every public symbol of Isomer's runtime is
  129,053 exports, more than the 100,000 the WebAssembly JS API lets a
  browser or web view load (WasmKit has no such limit).
  `wasm_runtime_module(exports_for = [<side modules>])` exports what the host
  calls and what those side modules import instead: 1,001 for the
  Storybook's (tools/wasm/side_module_imports). A feature binds to its
  runtime's build either way.
- **Checked by rendering.** examples' //tests/side_modules: the Storybook's
  app as a side module over its runtime module renders what its
  self-contained reactor renders, byte for byte (the first frame and a tap on
  every first-frame tap target: each story's page), under WasmKit and in V8
  with the web's linker.

| (-c opt) | Self-contained reactor | Side module |
| --- | --- | --- |
| Tap counter | 16.5 MB / 4.8 MB gzip | 12.6 KB / 5 KB gzip |
| Storybook's app (98 stories + app) | 18.3 MB / 5.4 MB gzip | 721 KB / 233 KB gzip |
| Runtime, once | — | 23.9 MB / 6.7 MB gzip, stripped |

Open: a feature binds to the exact runtime build it was linked against (no
library evolution on wasm), so features are versioned per runtime build; the
runtime holds one root (`Runtime.shared`) and starts the feature through
`__main_argc_argv`, so one feature per runtime instance until there is a
per-feature entry and a root per feature.

What it needs of WasmKit: public API to place modules in a table and memory
(`Table.grow`, `Table.function(at:)`, `Function.reference`, …), with its
tests: a commit of the side-modules author's WasmKit fork, to propose to
swiftwasm/WasmKit, which isomer pins until then.
