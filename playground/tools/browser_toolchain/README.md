# The browser toolchain campaign (swift-frontend + wasm-ld as WebAssembly)

Sibling of `tools/playground_toolchain` (the on-device compiler): the same
LLVM/clang/lld + swift-frontend sources, cross-compiled with HOST =
`wasm32-unknown-wasip1` so the compiler itself runs in a browser (or under
any standalone WASI runtime). Nothing here replaces the native pipelines; the wasm SDK it
compiles user code against is the same SwiftWasm 6.3.2 artifact bundle.

Workspace: `~/Developer/ios-toolchain` (worktrees of swift, llvm-project,
swift-syntax, cmark, swift-experimental-string-processing at
`swift-6.3.2-RELEASE`, host tablegens in `build/host-tblgen`, native helper
tools in `native-tools/`) — override with `ISO_WORKSPACE`. Host compiler:
the swift.org 6.3.2 toolchain's clang (it has the wasm backend; Xcode's does
not) — `ISO_BASE_TC`. Target sysroot/stdlib: the SwiftWasm artifact bundle's
`wasm32-unknown-wasip1` dir — `ISO_WASM_SDK` (see `env.sh`).

    ./build_phase_1_wasi_llvm.sh      # LLVM + clang libs + lld → bin/lld.wasm
    ./build_phase_1b_wasi_cmark.sh
    ./build_phase_2_wasi_swift.sh     # swift-frontend.wasm

## How the wasm host is described to CMake

`wasi-toolchain.cmake`: `CMAKE_SYSTEM_NAME=WASI`, the swift.org clang with
`--target=wasm32-unknown-wasip1`, `CMAKE_SYSROOT` = the SDK's `WASI.sdk`,
`-resource-dir` = the SDK's clang resource dir (wasm32 builtins), the WASI
emulation defines/libs (`_WASI_EMULATED_SIGNAL/MMAN/PROCESS_CLOCKS/GETPID`),
`-fno-exceptions -fno-rtti`, an 8 MiB linear stack and a 4 GiB max memory,
and `-isystem shims/`. CMake has no WASI platform module and LLVM keys its
Unix/Windows split on `UNIX`, so the phase scripts pass `-DUNIX=1` (setting it
from the toolchain file or a Platform module does not survive CMake's
platform setup). The swift tree already knows `CMAKE_SYSTEM_NAME=WASI`
(`SWIFT_HOST_VARIANT_SDK=WASI`, `configure_sdk_unix("WASI" "wasm32")`).

## shims/ — single-threaded std threading types

The SDK's libc++ is configured with `_LIBCPP_HAS_THREADS=0` and omits
`std::mutex`, `shared_mutex`, `condition_variable`, `future`, `thread`
entirely, while LLVM's headers name them unconditionally (RWMutex.h,
ThreadPool.h, BalancedPartitioning.h, …) even with `LLVM_ENABLE_THREADS=0`.
`shims/<header>` does `#include_next` the real header and, under
`!_LIBCPP_HAS_THREADS`, defines no-op lockables, immediately-returning
waits, synchronous futures/async/packaged_task and a synchronous
`std::thread`. Correct because with threads off nothing ever runs
concurrently (verified with a probe program under a standalone WASI runtime).

## Patches (apply to the worktrees)

- `llvm-wasi-endian.patch` — `llvm/ADT/bit.h` includes `<machine/endian.h>`
  on unknown Unixes; wasi-libc has `<endian.h>`.
- `swift-wasi-taskqueue.patch` — `lib/Basic/TaskQueue.cpp` picks the Unix
  (posix_spawn) queue for any `LLVM_ON_UNIX`; the wasm host takes the
  Default (unsupported) one — only the driver spawns, the frontend never does.

## stubs/wasi_stubs.c

Weak definitions of process/dl/rlimit APIs the compiler sources reference
but wasi-libc lacks; unreachable at runtime, ENOSYS if called.

(Build log continues below as the campaign progresses.)

### Build log — Phase 1 (LLVM/clang/lld)

- Configure worked once `-DUNIX=1` was passed on the command line (the
  toolchain file / a `Platform/WASI.cmake` module do not survive CMake's
  platform setup; LLVM then reports "Unable to determine platform").
- First compile wall: `llvm/ADT/bit.h` → `<machine/endian.h>`
  (`llvm-wasi-endian.patch`), then every header naming `std::mutex`,
  `shared_mutex`, `condition_variable`, `shared_future`, `thread` — the SDK
  libc++ omits them (`_LIBCPP_HAS_THREADS 0`) → `shims/`.
- `lib/Support/Unix/*.inc` + friends: wasi-libc hides the POSIX APIs WASI
  cannot implement behind `__wasilibc_unmodified_upstream`. Defining that
  macro globally breaks `<errno.h>` (`bits/errno.h` missing) and toggling it
  per header double-defines `bits/alltypes.h` types — so instead the shims
  ADD declarations after `#include_next`: `unistd.h` (alarm, getsid, setsid,
  pipe, fork/exec, dup, …), `signal.h` (sigaction/sigset/SA_*/stack_t),
  `sys/resource.h` (rlimit), `sys/wait.h` (whole file; wait4), `sys/stat.h`
  (umask), `sys/ioctl.h` (winsize), `fcntl.h` (F_RDLCK/F_WRLCK/F_SETLK),
  `pwd.h` (whole file), `dlfcn.h` (Dl_info/dladdr). Definitions for the
  functions live in `stubs/wasi_stubs.c` (weak, ENOSYS).
- Source patches (`llvm-wasi-host.patch`): `CrashRecoveryContext.cpp` — no
  setjmp/longjmp on wasm without exception handling (RunSafely just runs
  Fn; HandleCrash aborts); `raw_socket_stream.cpp` — compiled out (no
  sockets); `Unix/Path.inc` — `is_local` is always true (preopens only);
  `Unix/Program.inc` — wasi's `rusage` has no `ru_maxrss`.
- **`wasm-ld` as a WASI command WORKS** (`build/wasi-llvm/bin/lld`, 34.7 MB
  unoptimized, all lld drivers; `-flavor wasm`): linked a natively compiled
  Swift hello-world object against the SDK archives in 2.2 s wall
  (under a standalone WASI runtime that compiles the module with an
  optimizing JIT at launch; 1.6 GB RSS mostly the runtime's own compiled
  code) and the output prints under the same runtime. The linker link line is the one
  `clang -###` prints for the swift driver's link job, with the SDK's own
  `libclang_rt.builtins-wasm32.a`.

### Build log — Phase 2 (swift-frontend) configure

- The swift tree already knows a WASI host (`CMAKE_SYSTEM_NAME=WASI` →
  `SWIFT_HOST_VARIANT_SDK=WASI`, `configure_sdk_unix("WASI" "wasm32")`,
  `Threading/Impl.h` picks `SWIFT_THREADING_NONE` for `__wasi__`).
- `BOOTSTRAPPING_MODE=CROSSCOMPILE`: SwiftCompilerSources are compiled by the
  swift.org 6.3.2 host `swiftc` targeting wasm32 against the SwiftWasm SDK
  (`SWIFT_COMPILER_SOURCES_SDK_FLAGS` = `-sdk WASI.sdk -resource-dir
  swift_static -static-stdlib`); the host Swift runtime the frontend links
  is the SDK's static stdlib, found through `build/wasi-swift/lib/swift` →
  symlink to the SDK's `swift_static` (`SWIFTLIB_DIR/<sdk>/<arch>/swiftrt.o`
  and `-lswiftCore` resolve there).
- CMake's Swift compiler test links an executable: the swift.org toolchain
  lacks wasm compiler-rt in its own resource dir, so `CMAKE_Swift_FLAGS`
  carries `-Xclang-linker -resource-dir -Xclang-linker <SDK>/swift_static/clang`.
  `CMAKE_ASM_COMPILER` must be the swift.org clang too (CMake picked Xcode's).
- libuuid: `shims/uuid/uuid.h` + an implementation over `getentropy` in the
  stubs (`UUID_INCLUDE_DIR`/`UUID_LIBRARY` seeded like the iOS campaign).
- `swift-wasi-host.patch`: TaskQueue takes the Default implementation on
  `__wasi__`; `add_dependencies` on the absent `swift-stdlib-wasi-wasm32`
  (CROSSCOMPILE + prebuilt stdlib) and on the `clang` executable
  (`CLANG_BUILD_TOOLS=OFF`) are guarded with `TARGET` checks.
- clang libraries: `clang/Support/Compiler.h` spells the wasm predefined
  macro `__WASM__` (it is `__wasm__`), leaving `CLANG_ABI` undefined for a
  wasm host → 600 files fail on `class CLANG_ABI …` (in `llvm-wasi-host.patch`).
- LLVM's JIT (Orc) headers reach `std::condition_variable` through
  `<mutex>`/`<thread>` as libc++-with-threads would; the shims now chain
  the same way. `ninja all` also tries the clang Interpreter (netdb.h),
  shared-object test plugins (`--version-script`) and test tools — not
  needed; the libraries swift-frontend links all build (158 archives +
  the JIT set).
- A declaration in a shim needs a definition in the stubs: `alarm` and
  `getsid` bit at link time.

### Reworked: libc++'s own threading API instead of no-op shims

The no-op `std::mutex` shims carried the C++ build but broke the Swift side:
swiftc's clang importer builds LLVM's headers as clang MODULES (BasicBridging
→ LLVM_CAS uses `std::future`), and textual shim types are invisible across
module boundaries; making the shims a module of their own cycled with
libc++'s `std` module (its headers include `<mutex>` by name). The fix that
works everywhere: `shims/__config_site` is the SDK's libc++ config with
`_LIBCPP_HAS_THREADS 1` + `_LIBCPP_HAS_THREAD_API_PTHREAD 1` — the
single-threaded wasi-libc already defines the whole pthread API as stubs,
so libc++'s headers compile as on any Unix — and
`build_phase_0_wasi_support.sh` compiles libc++'s out-of-line threading
sources (`mutex`, `condition_variable`, `shared_mutex`, `future`, `thread`,
`call_once` from `libcxx/src`) with that config into
`libiso_cxxthreads.a`, linked into every executable (`ISO_WASI_LINK_EXTRA`,
with the stubs object). Verified: the threading probe under a standalone WASI runtime, and a
`-cxx-interoperability-mode=default` swiftc compile of a bridge using
`<future>`/`<mutex>` (fresh module cache — stale caches hide config changes).
Also for the importer: the SDK's `wasi-libc.modulemap` lists `inttypes.h`
etc. in `SwiftWASILibc` while libc++'s wrappers include_next them from
`std_inttypes_h` → "cyclic dependency"; `resource_overlay/` replaces it with
the glibc shape (one umbrella `SwiftWASILibc.h`, everything textual), and
the compiler sources get `-Xcc -D_WASI_EMULATED_*` + `-Xcc -isystem shims`.
`SwiftCompilerSources/CMakeLists.txt`: for a WASI host the shims include is
the build tree, not the host toolchain's `lib` (second SwiftShims map).
32-bit host: `PointerIntPair<…, 3>` on `llvm::Value*` / `SILInstruction*`
has only two spare bits with 4-byte pointers → `PointerIntPairCompat.h`
(`SWIFT_WIDE_POINTER_INT_PAIR`, side-by-side on 32-bit) at the two sites
(IRGen `Address.h`, `StackNesting.cpp`). `Default/TaskQueue.inc` had
bit-rotted (`std::make_unique`, `Wait` signature). `ToolChains.cpp` host
switch gained `__wasi__`. The whole LLVM/clang/lld + swift trees are rebuilt
under the threads config (ODR: every object must agree on `std::mutex`).

### Build log — swift-frontend links and runs; first compile

- `swift-frontend` links (99 MB unoptimized) once the WASI host is added to
  `_add_swift_runtime_link_flags`'s Unix list (`AddSwift.cmake`) — before
  that the Swift runtime archives were never on the link line — and the
  compiler sources are compiled `-Xcc -fno-exceptions` (the clang importer
  compiles inline C++ WITH exceptions by default → `__cxa_throw` refs; the
  stubs also carry abort()ing `__cxa_*` entry points).
- As a WASI command `swift-frontend -frontend -version` / `-print-target-info`
  work (5.4 s wall, 3.6 GB RSS — the runtime JIT-compiling the 99 MB module;
  precompile/cache will matter in the browser). The frontend needs
  `-module-cache-path` inside a preopened dir (the driver's default per-user
  cache does not exist in the sandbox).
- First real compile tripped `Assertion failed: (wrong FunctionInfo layout)`
  (`Function.swift:537`): the Swift classes of the compiler overlay C++
  objects through `SwiftObjectHeader` (`BridgedSwiftObject`: metatype +
  `int64_t refCounts` = 16 bytes), but the Swift runtime's inline refcount
  is 32-bit on wasm32, so Swift lays `effects` out 8 bytes after the header
  while C++ reserves `libswiftSpecificData` 16 bytes in. `refCounts` is now
  pointer-sized (identical on 64-bit hosts).

### Build log — Phase 0 done: hello world compiles, links and runs as WASI commands

`verify_wasi.sh` passes end to end (2026-09-09): the wasm-hosted
`swift-frontend` compiles `print("hello …")` to a wasm32 object, the
wasm-hosted `lld` links it against the SDK archives, and `main.wasm` run
under the same WASI runtime prints the line. (The script takes the runner
as `WASI_RUN`; Isomer's own is `@isomer//tools/wasm/wasi_command:iwasm`,
WAMR.)

- The last blocker was a 32-bit pointer-tagging bug in the compiler itself,
  not in serialization: `PointerLikeTypeTraits<AbstractConformance *>`
  (`ProtocolConformanceRef.h`) claims `TypeAlignInBits` (3) spare low bits,
  but `AbstractConformance` (`lib/AST/AbstractConformance.h`) carried no
  `alignas` — on a 64-bit host it is 8-byte aligned by accident (pointer
  members), on wasm32 only 4. The three-way `ProtocolConformanceRef` union
  masked bit 2 off the pointer, so every abstract conformance read from a
  swiftmodule (first hit: `_allocateUninitializedArray`'s substitution map
  while SIL-linking `print`) dereferenced 4 bytes early → garbage type /
  protocol → an endless `DeclContext` parent walk. Fix: `class alignas(1 <<
  TypeAlignInBits) AbstractConformance` (in `swift-wasi-host.patch`; no-op
  on 64-bit hosts). An audit of every `LLVM_DECLARE_TYPE_ALIGNMENT` /
  `NumLowBitsAvailable` claim in the tree found no other class that relies
  on accidental alignment (Decl/Expr/Stmt/TypeBase/Pattern/TypeRepr/
  DeclContext/ProtocolConformance/PackConformance/GenericEnvironment all
  declare `alignas`; `Identifier` goes through the `alignas(uint64_t)`
  `Aligner`; `GenericParamList`/`RequirementRepr`/`SILFunction`/`ASTContext`
  only claim 2 bits).
- Objects are the same size as the native toolchain's for the same input
  (`UserApp.o`: 3619 B both) and differ in a handful of bytes (embedded
  paths); the reactor link with the web driver's exact `wasm-ld` flags
  produces a 9.3 MB `iso_hot`-style reactor.

Timings on the M-series host (a standalone WASI runtime with an optimizing
JIT, 3 runs, hello world):

| step | wall | max RSS | notes |
|---|---|---|---|
| frontend `-c`, module compiled by the runtime at launch | 8.4 s | 3.7 GB | the JIT compiling the 99 MB module dominates |
| frontend `-c`, precompiled ahead of time (375 MB of native code, 9 s once) | 2.8 s | 242 MB | fresh vs warm `-module-cache-path`: no difference (2.65 s / 2.84 s) |
| lld link (launch compile) | 2.1 s | 1.65 GB | precompiled 131 MB, 1 s to produce |
| run `main.wasm` | ~0.1 s | | 7.3 MB command binary |

Sizes (the `-O3` link already drops the name section):

| artifact | raw | `wasm-opt -Oz --strip-debug --strip-producers` | gzip -9 | brotli -q 9 |
|---|---|---|---|---|
| `swift-frontend.wasm` | 99,146,468 | 97,621,371 (39 s) | 32,378,432 | 24,816,277 |
| `wasm-ld.wasm` (`lld`) | 34,706,405 | 34,009,679 (19 s) | 11,882,326 | 9,468,818 |

Browser-driver notes (`web/playground_web_application/toolchain_driver.js`):
`-static-stdlib` is a driver flag the frontend rejects ("unknown argument");
the frontend spelling is `-use-static-resource-dir`. Every other flag in the
driver's frontend and link lines was accepted as-is (`-Xcc
--target=wasm32-unknown-wasip1`, `-swift-version 5`, `-parse-as-library`,
reactor link with `crt1-reactor.o --entry _initialize --export-all
--no-gc-sections`). `-module-cache-path` must point inside a preopened dir
(the driver's `/work/module-cache` is right). Invoking `_initialize` on the
reactor from a standalone runtime traps the same way for the native
toolchain's build, so that is the host-import environment, not the
toolchain.

Still open for the browser: the module is single-threaded (libc++ threads
config over wasi-libc's stub pthreads), and the standalone runtime's
launch-time compile shows why the browser must cache the compiled module
(`WebAssembly.compileStreaming` + Cache API / IndexedDB) — the browser's
baseline compiler is far faster than an optimizing JIT but 100 MB is still
seconds.

## Macros (2026-10-12)

`@Observable`, `@TaskLocal` and the toolchain's other prebuilt macros
compile in the browser. Three pieces:

- **A compiler with swift-syntax.** `ISO_SWIFT_SYNTAX=ON
  ISO_SWIFT_BUILD=build/wasi-swift-syntax ./build_phase_2_wasi_swift.sh`
  (a build directory of its own) after `swift-wasi-plugins.patch`:
  swift-syntax and ASTGen as static libraries for a WASI host (CMake has
  them shared), a stand-in for the stdlib target CROSSCOMPILE's host Swift
  libraries wait for (the SDK's stdlib is used), WASI's emulation flags and
  the threading shims for those libraries (in pairs: CMake drops a repeated
  `-Xcc`), no macro libraries or in-process plugin server for the frontend
  to depend on (a WASI host loads none), and `LoadedExecutablePlugin` on
  WASI: an executable plugin is a wasm module the host runs beside the
  compiler, reached through the `iso_plugin` imports (`open`, `write`,
  `read`, `close`: the plugin's pipes). The script also passes the
  string-processing sources (ASTGen's regex parsing needs them). The
  frontend grows from 99 to 105 MB (103 MB after `wasm-opt -Oz`, 34 MB
  gzipped).
- **The plugin as wasm.** `build_macro_plugins.sh` builds ObservationMacros
  and SwiftMacros (the swift worktree's lib/Macros, over its swift-syntax)
  into one WASI command, `MacroPlugins.wasm`
  (`macro_plugins/MacroPluginsMain.swift`: a macro is found by its type's
  module and name, so one module serves both and carries swift-syntax once),
  with the swift.org 6.3.2 toolchain and the SwiftWasm SDK. Its `main`
  registers swift-syntax's handler; `swift_wasm_macro_v1_pump` answers one
  request from stdin on stdout. SwiftPM's manifest compile needs a macOS
  SDK the 6.3.2 clang understands: `SDKROOT=<CommandLineTools>/MacOSX26.5.sdk`
  with Xcode 27 installed. 43.8 MB, 8.4 MB after `wasm-opt -Oz`.
- **The host.** `stage_bundle.sh --plugin MacroPlugins.wasm#ObservationMacros,SwiftMacros`
  puts it in the bundle's `plugins/` and the manifest's `plugins`; the
  driver (`toolchain_driver.js`) passes `-load-plugin-executable
  /toolchain/plugins/MacroPlugins.wasm#ObservationMacros,SwiftMacros` and
  gives the compiler the `iso_plugin` imports: it instantiates the plugin in
  the worker (kept for later compiles), frames nothing itself (the compiler
  writes an 8-byte little-endian length and the JSON), pumps the plugin once
  a whole request is in, and hands its stdout back.

Two shim bugs the new frontend found: `fd_readdir` claimed a full buffer
without writing the entry that did not fit, so wasi-libc's `readdir` parsed
stale bytes as an entry and spun forever (the frontend lists its default
plugin directories); and `path_readlink` answered ENOSYS, which made
`realpath` fail on the plugin's path (now EINVAL for an existing path, as
POSIX says for a non-link).

Measured (headless Chrome, the page's worker): the Pokédex template, whose
models are `@Observable`, compiles in 3.5 s and runs (its list over
URLSession: the Playground SDK links `hot_bridge_network`); under Node
(`test_driver.mjs`) the templates compile in 3.5–4.4 s.

### Build log — second 32-bit alignment bug: compound names (Counter compiles)

Hello world passed, but `print("Tapped \(n) times")` failed with `value of
type 'DefaultStringInterpolation' has no member '<garbage>'` and `struct A:
P` for `protocol P { init() }` failed its conformance check (the SwiftUI
`App` case is the same bug: `init()` is a compound name). Same family as
`AbstractConformance`, on the allocation side this time: `CompoundDeclName`
and `SelectiveDeclNameRef` (`Identifier.h`) were declared
`alignas(Identifier)` — 8 on a 64-bit host, 4 on wasm32 — while
`DeclName`'s traits claim `Identifier::NumLowBitsAvailable - 1` (2) spare
bits on top of the `PointerUnion<DeclBaseName, CompoundDeclName *>` tag.
With 4-byte-aligned compound names the union only has one bit, so the next
level of tagging (`DeclNameRef::Storage`, `PointerIntPair`s of names)
collided with the union's own tag and every compound name (`init()`,
`appendInterpolation(_:)`) decoded to the wrong object. Fix: both structs
are now `alignas(Identifier::RequiredAlignment)` (8 everywhere; a no-op on
64-bit hosts). Swept the tree for other `alignas(<pointer-sized type>)`
classes: the rest (`ParameterList`, `ArgumentList`, `TrailingWhereClause`,
`LazyMemberLoader`, `ImportCache`, `MarkupASTNode`) have no explicit traits
claim, so their tag bits derive from the real alignment.

After the rebuild all three repros produce objects against the staged
bundle (`/toolchain` + `/work` preopens, the web driver's flags):
interpolation links and prints `Tapped 3 times`; `init()` conformance
passes; the Playground's `Counter.swift` (`import SwiftUI` /
`Isomer`, `-I /toolchain/sdk/modules`) compiles to a 29.9 KB
object and links with the driver's reactor line into a valid 17.8 MB
`iso_hot` reactor. `node tools/browser_toolchain/test_driver.mjs <stage>
Counter.swift` → `PASS (1.3s)`. `build/browser-work/opt/` holds the
refreshed `swift-frontend.opt.wasm` (97,621,669 B; .gz 32,380,000; .br
24,812,642) and its precompiled native form; `swift-wasi-host.patch` carries
both alignment fixes.
