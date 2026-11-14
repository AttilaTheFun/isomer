# Features as side modules over one runtime (2026-11-13)

**Status: prototype, measured.** docs/future_direction.md called this "not
possible today"; it is, with two small upstream changes. The tooling is
tools/mixed (README there); the loader is `WasmDynamicLinker`
(//shared/wasm_host).

## The problem

A downloaded feature today is a reactor carrying its own copy of the Swift
standard library, Foundation and Isomer's SwiftUI. Even dead-stripped, the
smallest (the tap counter) is 16.5 MB raw, 4.8 MB gzip; the Storybook 18.3 MB,
5.4 MB gzip. A second feature pays it again, in download and in memory.

## Side modules

Swift 6.4.2's wasm objects, and the Swift SDK's standard library, are already
position-independent, so a feature links as a wasm **side module**
(`wasm-ld --experimental-pic -shared -Bsymbolic
--unresolved-symbols=import-dynamic`, with `swiftrt.o`, whose constructor
registers the module's metadata with the Swift runtime) against a **runtime
module**: the same reactor link without the feature, exporting its public
symbols (`--export-dynamic --no-gc-sections`), its table (`--export-table
--growable-table`), `__stack_pointer`, its allocator and a few libc functions,
and leaving the app's entry (`__main_argc_argv`) an import the feature
provides.

A loader places the side module as a dynamic loader does (the WebAssembly
tool conventions' DynamicLinking.md): its memory from the runtime's
`aligned_alloc`, its table slots at the table's end, its `env` imports and
`GOT.mem`/`GOT.func` entries from the runtime's exports; instantiating runs
its global relocations, then the loader calls `__wasm_apply_data_relocs`
(the start function doesn't) and `__wasm_call_ctors`.

| (-c opt) | Self-contained | Side module |
| --- | --- | --- |
| Tap counter | 16.5 MB / 4.8 MB gzip | 12.6 KB / 5 KB gzip |
| Storybook (98 stories + app) | 18.3 MB / 5.4 MB gzip | 695 KB / 226 KB gzip |
| Runtime, once | — | 23.9 MB / 6.7 MB gzip / 4.4 MB brotli |

Checked by rendering: the Storybook's 99 first-screen taps (every story's
page) give a render stream byte-identical to the self-contained build's,
under V8 (node/loader.mjs) and under WasmKit (WasmDynamicLinker, and
`WasmKitRuntime.loadSideModule`).

What it took:

- **wasm-ld** (tools/patches/lld_wasm_pic_locrel.patch; pawlowskialex/llvm-project
  branch wasm-ld-pic-locrel-6.4.2): in PIC data it added `__memory_base` to
  Swift's relative pointers (`R_WASM_MEMORY_ADDR_LOCREL_I32`), which hold
  wherever the module loads; conformance records pointed outside memory and
  the runtime's first conformance scan trapped. Upstream LLVM rejects the
  relocation instead. Until a toolchain carries the fix, a loader can correct
  the slots (node/locrel_fix.mjs, split/locrel_from_map.py).
- **WasmKit** (pawlowskialex/WasmKit, branch isomer-side-modules, pinned in
  MODULE.bazel): public `Table.grow`/`count`/`function(at:)`,
  `Function.reference`, `Instance.function(at:)`, `Memory.grow` and
  `unsafeBaseAddress`.

Open: a feature binds to the exact runtime build it was linked against (no
library evolution), so features are versioned per runtime build; the runtime
holds one root (`Runtime.shared`) and features start through
`__main_argc_argv`, so one feature per runtime instance until a per-feature
entry and several roots exist (features sharing one instance would share its
heap too); getting the patched wasm-ld into Bazel (prebuilt by sha256, built
from source, or a post-link fixup).

## A mixed native/interpreted runtime

The runtime stays interpreted wasm (that is what lets features link against
it), but most of its time is in few functions: in the Storybook run, 95% of
the runtime's time is in 787 of its 104k functions. Compiling everything to C
(wasm2c) works but is 319 MB of C and 36 MB of native code. Instead:

- **Native copies, not moved functions.** The whole runtime stays
  interpreted; native copies (wasm2c) of a set of its functions are compiled
  into the host, over the same memory (WasmKit's reserved memory, its base
  fixed), a mirrored table and the one mutable global, `__stack_pointer`,
  synced at each crossing. Interpreted code (features, cold code) never calls
  native code; the host enters native code at the runtime's entry points, and
  native code calls back into the interpreter for cold functions and for the
  feature. Moving functions instead (interpreted code calling native
  `swift_retain`) made 18 million crossings and ran 5× slower than
  interpreting everything.
- **The set by call structure**: the functions on profiled stacks, their
  direct callees, and what native code then called into the interpreter most,
  in rounds (Binaryen's wasm-split on a copy with only the entry points
  exported; otherwise it keeps every exported function native).
- **Routed calls**: features call 74 heavy runtime functions (`Text.init`,
  `String` appends, conformance lookups, `@State`, modifiers: at least 0.3 µs
  each in the profile) through their native copies; 83% of the feature's time
  in runtime calls, for 37k crossings.
- **Cheap crossings**, in WasmKit: raw-slot calls (`invokeUnchecked`), no
  signal mask saved on entry (two system calls each), and a return to the host
  that halts the handler chain instead of throwing an error the loop boxed,
  recorded and cast every call.

| Storybook, 99 taps, WasmKit | Time | Crossings |
| --- | --- | --- |
| All interpreted | 3.15 s | — |
| Native copies by profile and crossing counts | 0.75 s | 87k |
| + routed feature calls, cheaper crossings | 0.54 s | 84k + 36k |
| + raw-slot calls, halt on return | **0.44 s** | 84k + 36k |

Byte-identical render streams throughout. Native code: 3.9 MB (4,990
functions, 2.4 MB of wasm), relying on WasmKit's guard pages; 7.4 MB with
wasm2c's bounds checks. Of the 0.44 s, about 60% is native code, 28% the
interpreter (the feature's code and cold code), 11% crossings.

Open: WasmKit's trap handling to cover native code (the guard-page build
faults on an out-of-bounds access instead of trapping); the set and routed
list from a broader corpus than the Storybook's taps; Bazel rules for the
runtime, the native part and features; the bridge in `WasmKitRuntime` and the
hosts (iOS, Android), and the same scheme on the web, where the browser's own
engine runs both.

### Event → frame: the Playground's 2048

The Playground's 2048 sample (examples/wasm/game2048_feature, built with the
Storybook reactor's libraries so the Storybook's runtime hosts it), dragged:
ten drags of 60 `changed` events, a render after each (the samples), then
each release and its animation's frames, as tests/wasm_engines'
testBenchmarkDrag does. The native set is the Storybook's grown on this drag
(tools/mixed/data/storybook_2048_native_set.txt: 5,187 functions, 3.95 MB of
native code; the Storybook stayed byte-identical through its rounds).

| 2048 drag | Self-contained reactor | Side module, interpreted | Side module, mixed |
| --- | --- | --- | --- |
| **Mac** (WasmKit 5fbb9db for the reactor) | | | |
| mean | 2.02 ms | 2.04 ms | 0.67 ms |
| median | 0.51 ms | 0.51 ms | 0.71 ms |
| p90 | 7.0 ms | 7.1 ms | 0.96 ms |
| first frame | 133 ms | 136 ms | 40 ms |
| release animation, per frame | 7.1 ms | 7.2 ms | 0.75 ms |
| **iPhone Air** (iOS 27.2; one WasmKit for all, see below) | | | |
| mean | 1.41 ms | 1.50 ms | 0.50 ms |
| median | 0.38 ms | 0.40 ms | 0.52 ms |
| p90 | 4.9 ms | 5.1 ms | 0.58 ms |
| first frame | 70–75 ms | 79–87 ms | 24–35 ms |
| release animation, per frame | 4.9 ms | 5.1 ms | 0.54 ms |
| **download** | 17.6 MB | 67 KB (26 KB gzip) | 67 KB (26 KB gzip) |

Three runs of each. The frames that do work (rebuilding the board, animating)
are 7–9× faster in mixed mode; the cheapest events, which change almost
nothing, are about 0.15 ms slower: each still crosses into the interpreter
for 2048's own code (about 280 calls an event: its bodies, closures and
value witnesses). The iPhone app can't link the original WasmKit beside the
new one, so its reactor runs on the new one; on the Mac the two measure the
same for a reactor (2.02 against 2.04 ms). On the iPhone, two of the three
mixed runs got no guard-page reservation for the runtime's memory (the
earlier runs' were still held), so they ran over a memory that moves as it
grows, unprotected from native code's out-of-bounds accesses: the same times.

## Verifying the claims

Every step is in tools/mixed/README.md ("Reproducing it"); the published
pieces are the isomer branch (WasmDynamicLinker, tools/mixed, the 2048 cell,
the iPhone app), pawlowskialex/WasmKit `isomer-side-modules` and
pawlowskialex/llvm-project `wasm-ld-pic-locrel-6.4.2`.

| Claim | Step |
| --- | --- |
| Swift's wasm objects and the SDK's stdlib are PIC; a feature links as a side module | 3 (`split_link.py`; `llvm-objdump -r` on the objects shows `MEMORY_ADDR_REL_SLEB`/GOT relocations) |
| Side module and runtime sizes (tap counter, Storybook, 2048) | 3 |
| wasm-ld's LOCREL bug, its fix, lld's tests | 1 (`shared-locrel.s`) |
| The loader-side workaround (`--emit-relocs`, the `-Map` sidecar) | 1, 4 |
| Byte-identical renders: V8, WasmKit, `WasmKitRuntime.loadSideModule` | 4 |
| WasmKit's tests pass with its two commits | 2 |
| 95% of the runtime's time in 787 functions; 82% core machinery vs 18% feature code; 74% of feature time in runtime calls | 5 |
| All of the runtime as C: 319 MB of C, 36 MB of native code, 56 s to compile | 5 |
| Mixed mode: 0.44 s against 3.15 s, 3.9 MB (7.4 MB bounds-checked), byte-identical | 6 (`round.sh` with `data/storybook_native_set.txt`; the WasmKit build options in host/Package.swift) |
| Raw-slot calls vs checked (`CHECKED_CALLS=1`) | 6 |
| The 2048 numbers, Mac and iPhone | 7 |

Not reproducible from the published tools:

- **Moving the hot functions instead of copying them** (18 million crossings,
  16.1 s, 5× slower than interpreting): measured with a first version of the
  mixed host whose split gave the native part the hot functions alone; it
  was replaced, not kept.
- **The time breakdowns of the mixed runs** (60% native code, 28% the
  interpreter, 11% crossings; signal setup 5.2% of the run before its fix, the
  error thrown on each return): macOS `sample` profiles of `MixedCheck`
  (`REPEAT=<n>` repeats the taps for a longer sample), read by hand.
- **The steps between the published sets**: each round's timing is
  reproducible from its set, but only the sets the rounds ended with are
  published (the earlier ones follow from rerunning `grow_set.py`).
- **The toy linking test** (a hand-written runtime and feature, before
  Isomer's): superseded by step 4.
