# Features as side modules over one runtime, and mixed mode

docs/modes.md's first step: every mode gains. The linker is engine-neutral,
so a side module loads under WasmKit, in a browser and in a web view alike.
Mixed mode (below: native copies of the runtime's hot functions, for
embedded interpreted features, docs/modes.md's step 4) builds on it.

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
tests: commits on AttilaTheFun/WasmKit's isomer/side-modules, to propose to
swiftwasm/WasmKit. Until a release has them, isomer takes WasmKit 0.5.0 with
those commits as a patch (tools/patches/wasmkit_host_linking.patch).

## A feature over a runtime module, in a host

A host takes the runtime module once and features as bundles. A bundle
(`WasmServiceBundle`, swift_ffi's `WasmBundle`) is a reactor, as before, or
a side module naming the runtime build it was linked against
(`kind: .sideModule(runtime: <name>)`); its module's bytes are in memory
(`.bytes`) or in a file the engine reads at launch (`.file(path:offset:length:)`).
The runtime module is a `WasmRuntimeModule`: its name, its source, and the
engine made for each launch.

    let runtime = WasmRuntimeModule.mixed(           // IsomerMixedRuntime
        name: "app-runtime-12",
        source: .packaged(resource: "runtime")!,     // a file in Bundle.main
        native: native)                              // the app's MixedNativePart
    WasmView(provider: provider, runtimeModule: runtime)
    // provider's bundles: WasmServiceBundle(label:module:kind: .sideModule(runtime: "app-runtime-12"))

- **The engine.** `.mixed` makes a `MixedWasmKitRuntime` while the
  process's native part is free (`MixedWasmKitRuntime.isAvailable`) and a
  `WasmKitRuntime` otherwise (another view's feature holds it);
  `.interpreted` (IsomerWasmKitRuntime) always a `WasmKitRuntime`. Either
  is a `WasmSideModuleRuntime` (`launch`, then `loadSideModule`); an app's
  own engine can be too.
- **A load** (`WasmFeatureRuntime.load(bundle:)`, which WasmView and
  WasmViewModel call): the running engine released, a new one made, the
  runtime module launched in it and the bundle's side module loaded over
  it, then the feature started. A side module can't be unloaded, so a
  reload is that again: only the side module differs, and the released
  engine's hand-over gives the next mixed one the native part, so it stays
  native. A bundle naming another runtime build, or none given, fails to
  load (`WasmFeatureLoadError`, in the status).
- **Files, not bytes.** A runtime module is tens of megabytes; read into a
  Kotlin `ByteArray` and copied through JNI, one ran an Android 6 emulator
  out of the JVM's memory. A source names a file, and the engine's Swift
  reads it at launch (and doesn't keep it). On Apple platforms,
  `WasmModuleSource.packaged(resource:)` and `WasmBundle.packagedFile(…)`
  name a resource's file in `Bundle.main`. On Android, the Kotlin
  `WasmModuleSource` is `Bytes`, `File(path, offset, length)` or
  `Asset(name)`: an asset stored uncompressed (list `.wasm` among the app's
  uncompressed extensions) is read in place, its range of the APK through
  its descriptor; a compressed one is streamed once per install into the
  app's no-backup files and read from there. The Kotlin `WasmView` takes a
  `WasmRuntimeModule(name, source)` (`runtimeModule =`), and
  `PackagedWasmBundleProvider`/`AppWasmBundleProvider` deliver side
  modules (`sideModuleOf =`) and assets the engine reads
  (`engineReads = true`).
- **Android runs it interpreted.** Its engine is isomer's own Swift library
  (android/libraries/wasm_view:engine), which has no mixed mode's native
  part; reactors in memory still go to `WasmView`'s `engineFactory`, and the
  rest to `WasmKitRuntime`.

Checked: examples' //tests/side_modules: the Storybook's app as a
side-module bundle through `WasmFeatureRuntime`, interpreted
(:side_module_render_test, runtime and side module read from their files)
and mixed (:mixed_render_test, natively and interpreted), renders what its
reactor renders, tap for tap; a reload swaps the Storybook for the corpus's
side module and back (from its file rather than bytes), each a new mixed
runtime, native, the Storybook's first frame the same both times; a module
read from a file, or a region of one, is its bytes.

## Mixed mode

Interpreting the runtime is slow, and compiling all of it to C (wasm2c) is
319 MB of C and 36 MB of native code. Mixed mode keeps the runtime one wasm
module WasmKit interprets and compiles **copies** of its hot functions into
the app, over the same memory, a mirrored table and the one mutable global,
`__stack_pointer`, synced at each crossing. Interpreted code never calls
native code (moving functions instead made 18 million crossings and ran 5×
slower than interpreting); the host enters native code at the runtime's entry
points, native code calls back into the interpreter for the rest and for the
feature, and features call a few heavy runtime functions natively ("routed").

    load("@isomer//tools/wasm:mixed.bzl", "wasm_mixed_native")

    wasm_mixed_native(
        name = "native",
        runtime = ":runtime.wasm",
        native_set = ["corpus_native_set.txt"],  # from profiling the corpus
        modules = ["SwiftUI", ...],              # Isomer's own, whole
        closure = True,                          # and all they call directly
        routed = "routed.txt",
    )

`:native` is a cc_library the app links; `MixedWasmKitRuntime`
(//shared/wasm_host:mixed_runtime) runs the runtime and its side modules with
it. tools/wasm_mixed generates the C (Binaryen's wasm-split on the chosen
functions, WABT's wasm2c, a bridge and a WasmKit shim); Binaryen and WABT are
pinned (MODULE.bazel).

**The native set is the runtime's, not a feature's.** Native code ships in
the app; a feature downloaded later can't bring its own. So the set comes
from a corpus no app is in: tools/wasm_mixed_corpus writes a SwiftUI app of
88 screens made methodically from a catalog (43 pieces, 30 modifiers, 11
containers, 8 screen patterns; every pair of kinds meets; each screen's root
a NavigationStack, a NavigationSplitView or a TabView in turn, its state
changed by a timer), examples' //tests/side_modules:corpus_profile drives it
under the interpreter (taps, drags, text, sliders, toggles and pickers, long
presses, context menus: whatever each screen shows) with
`WasmKitFunctionProfile`, and `wasm_mixed profile-set` keeps every runtime
function that ran (about 4,950 of 104,000). Rules add what a profile can
miss: every function of Isomer's own modules (`modules`), and what the chosen
functions and the entry points call directly, all the way down (`closure`):
interpreted code never calls native code, so one interpreted function on the
way (the `MainActor.assumeIsolated` specialization under every entry point)
leaves everything beneath it interpreted. A set names functions, and a name
means every function by it (the runtime has thousands of same-named
helpers, which wasm-split tells apart by index, an index each build
changes), so a set outlives the runtime build it came from. A feature built
into the app may add a set from its own profile (`native_set` takes several).

When a held-out app is slow, `ISO_MIXED_COUNT=1` (native code's calls into
the interpreter, by function) names the kind of API the corpus lacks, which
goes into the catalog, never the app: the corpus's first version missed the
Storybook's root, a NavigationSplitView, and ran 96% of it interpreted.

**The guest on its own thread.** `MixedWasmKitRuntime` runs the guest only on
a thread of its own with a large stack (native code recurses on it), so the
main thread never waits for the guest's renders: calls that answer nothing are
queued in order, an allocation answers at once with a placeholder address
made real on the guest's thread, and the guest's calls into the host run on
the main thread while its thread keeps serving the queue (so the host's calls
back in can't deadlock). Measured below, this is what made mixed mode better
than the web view rather than worse.

**Without guard pages, interpreted.** Native code without bounds checks
needs the runtime's memory reserved with WasmKit's guard pages (4 GiB and
more), whose base never moves. An iPhone grants a process one such
reservation (an iPhone Air, iOS 27.2.1): a mixed runtime that isn't the first
engine in its process gets a memory that moves as it grows, and runs the
guest interpreted there (`isNative` false; on that iPhone, 2048's drag
events 5.29 ms on average so, against 1.19 ms with native code), as
`ISO_MIXED_NATIVE=0` does anywhere; `bounds_checks = True` builds the slower checked code instead.

Checked: examples' //tests/side_modules:mixed_render_test and
:mixed_interpreted_render_test, the Storybook's app in mixed mode, natively
and interpreted, render byte for byte what its reactor renders.

One runtime at a time: the native part is one C instance a process, and a
side module can't be unloaded, so a feature's reload is a new runtime. The
old one's `release()` (or its deinit) stops its guest's thread: what was
queued runs, then the hand-over, last (`iso_mixed_release`, which frees the
instance, and the bridge let go of); calls after it throw `released`, and
what the old guest sends its host is dropped. A launch while a released
runtime's hand-over is still to run waits for it, answering what the old
guest asks the main thread for meanwhile, without running the main run loop
(`MixedNativeClaim`); then it makes the instance again over its own memory.
`WasmFeatureRuntime.load` releases the running engine before it makes the
next (`WasmRuntime.release()`, nothing for other engines), so a reloaded
feature runs natively too. The same tests check that a released runtime's
successor, and a reload through `WasmFeatureRuntime`, render as the first.

What it needs of WasmKit, beside the side modules' API: cheaper host calls
(`invokeUnchecked`, no signal mask saved per entry, a return to the host that
doesn't throw), on the same branch with its tests, to propose to
swiftwasm/WasmKit.

Open: a trap in native code (or in interpreted code under it) ends the
process (native code can't unwind into Swift); one mixed runtime runs at
a time, with the features it serves (the native part is one C instance a
process; a released runtime hands it over, above), and one feature per
runtime instance until the runtime has a root per feature (several
features' side modules already load into one instance); the routed list is
still the Storybook's (from its feature calls).

## Launch time

Once a page runs, its frames cost little (a downstream app's measured about
0.1 ms each, its idle CPU under 1%). Opening it is the cost, and most of that
is WasmKit parsing the runtime module: 230 to 300 ms for a 29 MB module, about
70% of a 340 ms launch on a Mac, longer on an emulator.

- **Build the wasm modules `-c opt`**, whatever the app's own mode. That
  app's runtime module went from 37.7 MB to 29.6 MB, and its first frame from
  136 ms to 45 ms. WasmKit itself is optimized in every build
  (tools/wasmkit/BUILD.wasmkit.bazel), so only the guest's mode matters.
- **A reload builds once.** Before 0.62 a page's first poll of a hot-reload
  server reloaded even an unchanged build, launching the runtime twice.
- **Planned:** a parsed runtime module kept for the process, so a reload or
  a second page doesn't parse it again; and the launch off the main thread
  everywhere, its first frame posted back (Android's WasmView has it as
  `offMainInit`), so opening a page doesn't freeze the app's frames.

## Measurements

**A set from the corpus, apps held out** (a Mac, median of three; busy time
from each event or frame to the guest being idle; 2048: 60 swipes; the
Storybook: every story's page, its frames and drags):

| Native set | 2048 | Storybook | Native code |
| --- | --- | --- | --- |
| interpreted | 19.7 s | 26.1 s | — |
| the corpus's | 7.0 s | 5.1 s | 4.1 MB |
| the corpus's, Isomer's modules and the closure | 6.7 s | 4.4 s | 9.8 MB |
| 2048's own profile | 7.1 s | 4.6 s | 5.0 MB |
| the Storybook's own profile | 10.2 s | 4.8 s | 4.8 MB |

The rest of the numbers below were measured with the Storybook's own profile;
an iPhone XS's (A12) are in docs/modes.md.

The harnesses (profiling, the drag benchmark, 2048 Lab, simulator replays)
aren't in this tree; they and each game's raw stats are on the
side-modules-bench branch of the pull request's head repository
(tools/mixed, tools/mixed/results).

**The Storybook's 99 taps, WasmKit, Mac:** interpreted 3.15 s; mixed 0.44 s,
byte-identical. Native code 3.9 MB for 4,990 functions.

**2048, played, iPhone Air** (2048 Lab: the same game, the same native
renderer, only the engine differs; event to frame, ms):

| | Mixed, main thread (first build) | Web view (JavaScriptCore) | Mixed, own thread |
| --- | --- | --- | --- |
| mean | 10.4 | 3.1 | **2.5** |
| median | 11.7 | 1.8 | **1.5** |
| p99 | 23.2 | 11.0 | **7.7** |
| events over 8.3 ms | 54% | 4.2% | **0.6%** |
| display frames dropped while playing | 13.1% | 2.9% | **1.2%** |
| main thread's longest stall | 29.6 ms | 0.9 ms | **0.1 ms** |
| app memory | 111 MB | 31 MB + the web process (250–280 MB on a Mac) | 109 MB |

**The same 150-swipe game replayed through a simulator's touch input**
(iPhone Air simulator, two runs each, every run ending on the same board):

| | Mixed, main thread | Web view | Mixed, own thread |
| --- | --- | --- | --- |
| mean (ms) | 2.0 | 1.3 | 1.5 |
| p99 (ms) | 6.6–7.0 | 4.3–4.7 | 5.4–5.6 |
| display frames dropped while playing | 0.6% | 0.2–0.4% | **0.1%** |
| first frame | 0.45 s | 1.3–1.4 s | 0.45 s |
| app CPU (s) | 26–27 | 39, + the web process | 37 |

The first mixed build ran the game's Swift jobs fully interpreted (their entry
point wasn't native) and was profiled on a benchmark that ran none; with both
fixed, and the guest off the main thread, mixed mode is on par with the web
view's JIT on latency, ahead on dropped frames and start, and keeps what an
engine in the app's process gives: synchronous calls into the host (0.11 µs
under WasmKit against 61 µs from a web view), one process (the web process
can be killed on its own, losing the guest's state), no second process's
memory, and every place the app's code runs (tvOS, watchOS, widgets and
background work have no web view).
