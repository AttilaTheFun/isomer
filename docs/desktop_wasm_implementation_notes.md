# Desktop (Windows/Linux) wasm delivery — implementation notes & blockers

> **Engine replaced in 0.38.** WAMR was removed: the desktop wasm cells now
> run the reactor on WasmKit, driven from Swift (`LinuxWasmHost` /
> `WindowsWasmHost` over `WasmFeatureRuntime` + `WasmKitRuntime`,
> //shared/wasm_host; entry module `IsomerDesktopWasmHost`) instead of the C
> WAMR host. `//shared/wamr_host`, `@wamr`, `iso_wamr_*` and `WamrRuntime`
> below are gone; the tree decoding, `SwiftGPURenderer` drawing, id-echo
> events and hot reload are as described. These notes record how the cells
> were first built.

Companion to `linux_windows_wasm.md`. That doc set the goal (run the WAMR
interpreter on the Linux/Windows desktop hosts and render wasm-delivered Swift
through `SwiftGPURenderer`). This one records what the wiring actually requires
after reading the code end-to-end, the concrete blockers hit, and the phased
plan — so the next session doesn't re-derive it.

The user's refinement of the goal (supersedes the full/partial framing in
`linux_windows_wasm.md`): **Windows and Linux each get a same-name `[compiled |
wasm]` 2×1 matrix, full-mode only** (GPU renderers don't do partial), one fixed
renderer per OS (DirectX / OpenGL), all GPU driven through `SwiftGPU` from Swift
that is either compiled-native or running in wasm. Plus a **multi-client
hot-reload server** working on Windows and Linux so a Windows wasm app and a
Linux wasm app can hot-reload from one server simultaneously.

## Target architecture (desktop wasm cell)

1. The example app compiles to a **wasm reactor** (`example_full.wasm`, already
   built by `//examples/wasm/example_full_feature`). It binds
   `SwiftUIRenderer`, so on each `iso_hot_render` it serializes its `RenderNode`
   tree to `tree.fbs` and ships the bytes out the `iso_hot.render_tree` import.
2. The desktop host drives the reactor through the **C WAMR host**
   `//shared/wamr_host:iso_wamr` (NOT the Swift `//shared/wasm_host` — see
   blocker 1). Its C ABI (`iso_wamr.h`) is clean: `create/start/render/resize/
   event` + an `on_tree(bytes,len)` callback.
3. The host **decodes `tree.fbs` → `RenderNode`** (new `FlatTreeDecoder`,
   inverse of `FlatTreeEncoder`) and renders it with the already-bound
   `SwiftGPURenderer` over D3D11 (Windows) / GL (Linux).
4. Input: the host's `Runtime` hit-tests the decoded tree; decoded nodes carry
   synthesized `tapAction`/`textSet`/`onChange` closures that call
   `send(id, value)` → `iso_wamr_event` → the reactor re-renders → new `on_tree`.
   This id-echo model is identical to how Apple's `IsomerTreeView` routes
   events; the round-trip test below exercises the same seam with a local
   handler table instead of a wasm reactor.

The compiled cell is unchanged (the existing `example_full_{opengl,directx}_*`
app: native Swift → `Runtime.renderFrame` → `SwiftGPURenderer`).

## Blockers (in priority order)

### 1. swift_ffi `analyzer` fails on a Linux build host — GATES ALL LINUX WASM
`//shared/platform_services` runs swift_ffi's `analyzer` (and c-host
generator) via an aspect. On a Linux host that tool dies at load:
`analyzer: error while loading shared libraries: libswiftCore.so: cannot open
shared object file`. It's a `swift_binary` (swift_ffi/analyzer/BUILD.bazel) run
sandboxed with a cleared environment (`env -`), and the swift.org Linux
toolchain bakes a runfiles-relative RUNPATH that doesn't resolve there. The
native app dodges this with a `LD_LIBRARY_PATH` wrapper (`run_linux.sh`); a
build tool can't. `iso_wamr` depends on `platform_services_c_host`, so **nothing
wasm builds on a Linux host until this is fixed.** Fix is upstream in swift_ffi
(statically link the analyzer's stdlib, or give it a working rpath / put the
runtime in its runfiles), then bump the pin. Was never exercised because the
Mac agent built from macOS (analyzer finds the runtime via Xcode).

### 2. `tree.fbs` is lossy for the SwiftGPU `RenderNode` sink — DESIGN DECISION
The schema (`shared/renderers/tree.fbs`) was built for component-system
renderers and omits several `RenderNode` fields the SwiftGPU draw walk honors:
`offsetX/Y` (`.offset`), `rotation`/`scaleEffect` (`.rotationEffect`/
`.scaleEffect`), `overlay`, `minWidth/minHeight`, `imageCornerRadius`. A
`tree.fbs → RenderNode` decode is therefore **not** faithful for features using
those (the Motion gallery, badges drawn as overlays, etc.). Options:
- **(a) Extend the schema** (append-only slots) + `FlatTreeEncoder` + the JS/
  Kotlin/Swift consumers to carry these fields, so desktop-wasm renders
  pixel-identical to compiled. Correct, but touches every consumer.
- **(b) Accept lossy** for v1 — desktop-wasm demo apps avoid offset/rotation/
  overlay; ship the common path now, extend later.
Recommend (b) for the first working cell, (a) as the immediate follow-up, since
"same app, compiled vs wasm, looks identical" is the actual product promise.

### 3. Windows `@wamr` platform layer — entirely unbuilt
`@wamr` (MODULE.bazel) has no Windows branch. Needed: a `:windows_x86_64`
config_setting; swap the base `core/shared/platform/common/posix/*.c` glob into
a per-OS select and add `core/shared/platform/windows/*.c` for Windows;
`-DBH_PLATFORM_WINDOWS` + the windows include dir; and the **Windows-x64
`invokeNative` trampoline**, which WAMR ships as MASM (`.asm`) — it must
assemble under Bazel's MSVC toolchain (the fiddly part; the Linux/macОS
trampolines are GAS `.s`). Then add `@platforms//os:windows` to
`_NATIVE_WASM_HOSTS` (shared/wasm_host) — though desktop uses the C host, so
that list may not even be the relevant gate.

### 4. Cross-platform hot-reload server — currently macOS-only
`hot_reload_server` (examples/apple/example_partial_wasm_macos_application/
HotReloadServer.swift) is `target_compatible_with` macos. It's plain Foundation
+ a socket server and is already multi-client by design (concurrent serve queue,
serial build queue, immutable byte snapshots, per-client TTL). Porting: make it
build on Linux/Windows (FoundationNetworking on Linux; the client
`HotReloadServerSource` in `BundleProvider.swift` already `#if canImport`s it),
and drive `bazel build` of the reactor per-OS. The desktop wasm host then polls
it env-gated (`ISO_HOT_RELOAD_SERVER`), swapping the bundle bytes live — the
same `BundleProvider` contract Apple uses, but feeding `FlatTreeDecoder` +
`SwiftGPURenderer` instead of SwiftUI.

## Phased plan — status

- **P0 — unblock Linux (blocker 1). DONE + PORTABLE.** The swift_ffi
  `analyzer`/`generator` are swift.org-toolchain `swift_binary`s run as build
  actions; on a Linux host they couldn't find `libswiftCore.so`. Final fix (no
  machine paths): rules_swift already bakes a RUNPATH of
  `external/…/usr/lib/swift/linux` (relative to the exec root) into the tools,
  which resolves only when the action runs IN the exec root — so `.bazelrc` pins
  `build:linux --strategy=SwiftFFIAnalyze=local` +
  `--strategy=SwiftFFIGenerate=local`. Paired with `use_default_shell_env` on
  those actions (swift_ffi c-host-runtime branch). The swift_ffi patch is pushed
  (`11ab6ff`) and MODULE.bazel now `git_override`s it — the `local_path_override`
  is gone. `iso_wamr_full_smoke` runs `example_full.wasm` on WSL.
- **P1 — `FlatTreeDecoder`. DONE.** `shared/renderers/TreeDecoder.swift`, the
  exact inverse of `FlatTreeEncoder`: reads the same `IsoFlat_Node` accessors
  Apple's `IsomerTreeView` reads, rebuilds `RenderNode`s, and synthesizes
  `tapAction`/`textSet`/`sliderSet`/host `onChange` closures that call a
  `send(id, value)` closure. Reuses the existing `parseJSON` (JSON.swift) to
  rebuild `GradientPaint` from the encoder's `json()`. Typechecks in the
  Windows + Linux `SwiftUI` modules. (The `ISO_TREE_ROUNDTRIP` harness was
  unnecessary — P2 exercises the real seam end-to-end instead.)
- **P2 — Linux wasm cell. DONE + VERIFIED.** `LinuxWasmApp.run(wasmBytes:)`
  (`linux/libraries/swift_ui/LinuxWasmHost.swift`) sets up the GL
  `SwiftGPURenderer`, drives `iso_wamr` with `example_full.wasm`, decodes each
  `on_tree` push and draws it, and routes SDL input through the runtime's
  hit-test → `iso_wamr_event`. Target
  `//examples/linux/example_full_opengl_wasm_linux_application`. To keep the
  WAMR interpreter out of the compiled app, it links a separate module
  `//linux/libraries/swift_ui:swift_ui_wasm` (base srcs + the wasm host file +
  the `CIsoWamr` dep). Verified on WSL via `ISO_SHOT`: WAMR loads the 17.5 MB
  reactor (load≈450ms), and the decoded tree draws the exact `SplitRootView`
  shell — rounded-rect app-icon fills, text weights/colors, the selected-row
  highlight, and the search-field chrome (so `ChromeExpansion` runs on the
  decoded semantic host-view node). Network-backed content (Pokédex, Wikipedia,
  Hacker News) now loads live: the app awaits the injected
  `NetworkService.request(url:method:)` (`//shared/platform_services`);
  the desktop host's blob dispatcher issues the fetch on its native pool
  (libcurl on Linux, WinHTTP on Windows) and answers the call id through
  `swift_ffi_host_async_resume` → the reactor's `swift_ffi_async_resume` export
  → the awaiting task resumes → re-render. (Verified on both cells before the
  platform_services migration; the rewritten dispatchers — LinuxWasmHost /
  WindowsWasmHost — are pending a Linux/Windows re-verification, which cannot
  run from macOS.)
- **P3 — matrix reconciliation. DONE + VERIFIED (both cells co-build).** Desktop
  matrix is now `[compiled|wasm]`, full-mode only, matching the Apple/Android
  `_compiled`/`_wasm` naming: `example_full_{opengl,directx}_{compiled,wasm}_*`.
  Dropped the desktop `partial` GPU cells. README references updated.
  - **Same-module-name gotcha (fixed):** the compiled and wasm cells both expose
    a Swift module named `SwiftUI` (so app code does `import SwiftUI`
    unchanged). rules_swift emits `<package>/SwiftUI.swiftmodule` keyed on
    `module_name`, so two same-named targets in ONE package collide on that
    output path — building both together (or `bazel build //...`) is an action
    conflict. Fixed by giving the wasm library its OWN package
    (`//{linux,windows}/libraries/swift_ui_wasm`), reusing `*Host.swift` +
    `renderer.h` from the sibling `swift_ui` package via `exports_files`.
    Verified: both matrix cells build in a single invocation on each platform.
- **P4 — Windows `@wamr` + Windows wasm cell. DONE + VERIFIED.** The Windows
  wasm cell (`example_full_directx_wasm_windows_application.exe`) builds, loads
  the 17.5 MB `example_full.wasm` reactor under WAMR (load ~420ms), and renders
  the full multi-tab app through SwiftGPU/D3D11 — confirmed by a PrintWindow
  (flag 2) capture of the live swapchain. The @wamr Windows build layer
  (MODULE.bazel
  `build_file_content`) — every fix that was needed, in order they surfaced:
  1. Pulled `core/shared/platform/common/posix/*.c` OUT of the unconditional
     base `srcs` glob into the per-OS `select` (posix for non-Windows); Windows
     gets `glob(core/shared/platform/windows/*.c)` (its `platform_init.c` is in
     there) — but NOT `win_atomic.cpp` (the only C++ file; it's entirely inside
     `#if WASM_ENABLE_SHARED_MEMORY != 0`, off here, so an empty TU — dropping it
     keeps the library all-C so the C-only `/std:c11` below doesn't collide with
     the toolchain's `/std:c++17`). Windows also needs
     `core/shared/platform/common/memory/mremap.c` (no native `os_mremap`; the
     `os_mremap_slow` fallback lives in the globbed `shared/utils`).
  2. `:windows_x86_64` config_setting; `core/shared/platform/windows` in
     `includes`.
  3. **The MASM trampoline just works** — `invokeNative_em64.asm` in `srcs`
     assembles under Bazel's MSVC toolchain out of the box (the biggest feared
     blocker was a non-issue; the Linux/macOS trampolines are GAS `.s`).
  4. Windows copts: `-DBH_PLATFORM_WINDOWS -DWASM_HAVE_MREMAP=0
     -DBUILD_TARGET_X86_64` (MSVC doesn't predefine `__x86_64__` for config.h),
     `-D_WIN32_WINNT=0x0A00` (win_file.c's `CreateFile2`), `/std:c11` (native
     `_Alignof`/`_Static_assert` for platform_wasi_types.h), and
     `-DCOMPILING_WASM_RUNTIME_API` (Bazel links @wamr as a DLL; without this
     WAMR decorates its whole API `__declspec(dllimport)`, so the DLL exports
     nothing and `iso_wamr.c` can't link).
  5. Windows linkopts: `ws2_32.lib` (win_socket) + `ntdll.lib`
     (win_clock's `NtQueryTimerResolution`).
  Then `WindowsWasmHost.swift` (D3D11 surface + `WindowsApp`-style loop, mirrors
  `LinuxWasmHost.swift` incl. the destroy-before-create reload swap), a
  `//windows/libraries/swift_ui:swift_ui_wasm` module, and target
  `example_full_directx_wasm_windows_application` (loads the reactor from argv or
  the hot-reload server — the SwiftWasm toolchain isn't registered on the Windows
  host so `example_full.wasm` can't be a build-time data dep; it's fetched over
  HTTP or passed as a prebuilt file). WinSock `HotReloadClient` mirrors the Linux
  Glibc one. **Windows-host build fixes that surfaced (in order):**
  1. swift_ffi `analyzer.exe` / `generator.exe` failed `-1073741515`
     (STATUS_DLL_NOT_FOUND): they're swift.org-toolchain `swift_binary`s run as
     build actions, so a scrubbed action env can't find `swiftCore.dll` (and the
     analyzer's own SwiftCompile can't find the stdlib). FIX (portable, no
     machine paths): `use_default_shell_env = True` on the analyzer/generator
     actions (swift_ffi c-host-runtime branch) so the action uses the full shell
     env instead of Bazel's strict one — this bypasses the Windows `PATH`/`Path`
     case-collision that made bare `--action_env=PATH` a no-op. It needs a shell
     whose PATH has the swift.org toolchain+runtime dirs (the installer's
     default), which `.bazelrc`'s `build:windows --action_env=Path`/`PATH`
     forwards per-build (resilient to a stale persistent server).
  2. `iso_wamr.c` included `<sys/time.h>` (`gettimeofday`) — absent on MSVC.
     Guarded with `#ifdef _WIN32` → `GetSystemTimeAsFileTime` for the profiling
     clock (deltas only, epoch irrelevant).
  3. `swift_ffi_host` (the c-host runtime) linked across a DLL boundary from
     `iso_wamr.dll` but exported nothing → LNK2019. Added
     `features = ["windows_export_all_symbols"]` to that `cc_library` (no-op off
     Windows).
  4. Final `.exe` link pulls `@wamr` as a STATIC archive (plain symbols), but
     `iso_wamr.obj` referenced the API as `__imp_` (dllimport) because
     `wasm_export.h` decorates it that way by default. Added
     `-DCOMPILING_WASM_RUNTIME_API` to `iso_wamr`'s Windows copts (matches what
     @wamr builds with) so the refs stay plain and resolve against `wamr.lib`.
  5. `WasmMain.swift` WinSock client: `IPPROTO_TCP` is imported as an `IPPROTO`
     enum (not an integer macro like POSIX) → `IPPROTO_TCP.rawValue`.
  Verified via PrintWindow(flag 2) capture (title "Isomer (wasm)").
- **P5 — multi-client hot-reload. DONE + VERIFIED (Linux AND Windows, cross-platform).**
  Portable BSD-socket server `//shared/hot_reload:hot_reload_server`
  (`shared/hot_reload/HotReloadServer.swift`) — Foundation + raw sockets, the
  cross-platform peer of the macOS Network.framework server. Watches the
  reactor's source dir, rebuilds the wasm on edit, serves `/version` + `/wasm`
  to any number of clients concurrently. The Linux wasm cell (`WasmMain.swift`)
  gets a `HotReloadClient` (blocking BSD-socket HTTP): with
  `ISO_HOT_RELOAD_SERVER` set it loads the initial reactor from the server and
  polls ~2×/sec; on a build bump it hot-swaps the reactor
  (`LinuxWasmApp.run(nextReload:)`). **Verified on WSL:** one server, TWO wasm
  cells connected at once, edited `HotDemo.swift`'s greeting → server rebuilt
  (v1→v2) → BOTH cells hot-swapped and re-rendered the new text, no crash.
  - Reactor-swap gotcha (fixed): the swift_ffi dependency natives are
    registered globally against the FIRST reactor's binding storage
    (`iso_wamr.c`). The swap MUST destroy the old reactor (refcount→0, natives
    unregister, runtime tears down) BEFORE creating the new one (refcount 0→1,
    re-registers against the new bindings) — overlapping them and freeing the
    first dangles that attachment → UAF the moment the reactor calls a
    `swift_ffi` import. See `LinuxWasmApp.run`'s reload block.
  - **Cross-platform verified:** one `hot_reload_server` in WSL (serving the
    FULL `example_full.wasm`, watching `examples/shared/example_application`) drove a
    Linux wasm cell (OpenGL/llvmpipe, `ISO_SHOT` capture) AND a Windows wasm
    cell (D3D11, PrintWindow capture) at the SAME time. Windows reached the WSL
    server over `http://localhost:8787` (WSL2 NAT localhost-forwarding; the WSL
    LAN IP also works). Edited `ExampleApp.swift`'s sidebar `navigationTitle`
    "Isomer" → "Hot Reload OK"; the server rebuilt example_full.wasm
    (v1 17,503,301 B → v2 17,503,319 B, 3.9s) and BOTH cells polled, hot-swapped
    the reactor (each log shows two `[wamr-phases]` instantiations), and
    re-rendered the new title — no restart, no crash. This is the deliverable:
    a Windows wasm app and a Linux wasm app hot-reloading simultaneously from a
    single server on one source edit.
  - The server is currently gated to Linux (Foundation `Process` drives
    `bazel build` there). Building the server ON Windows is optional — a single
    Linux/WSL server already drives both desktop clients.

## Key file map (as of 0.38)
- The engine: `shared/wasm_host/{WasmFeatureRuntime,WasmKitRuntime,WasmRuntime}.swift`
  (WasmKit built by `tools/wasmkit/BUILD.wasmkit.bazel`, MODULE.bazel's
  `wasmkit`); the desktop hosts: `linux/libraries/swift_ui/LinuxWasmHost.swift`,
  `windows/libraries/swift_ui/WindowsWasmHost.swift`. (The C WAMR host,
  `shared/wamr_host/iso_wamr.{c,h}`, and `@wamr` were removed in 0.38.)
- Encoder to invert: `shared/renderers/TreeEncoder.swift`; schema
  `shared/renderers/tree.fbs`; node `shared/swift_ui_core/Node.swift`.
- Desktop hosts to extend: `linux/libraries/swift_ui/LinuxHost.swift`
  (`LinuxApp.run`, on-demand loop via `linuxRenderScheduled`),
  `windows/libraries/swift_ui/WindowsHost.swift` (`WindowsApp.run`).
- Reactor: `examples/wasm/example_full_feature/` (`example_full.wasm`).
- Hot-reload server + client: `.../example_partial_wasm_macos_application/
  HotReloadServer.swift`, `apple/libraries/wasm_view/BundleProvider.swift`.
- IntegrationMode: `shared/swift_ui_core/Renderer.swift` (`.app`/`.embedded`;
  `SwiftGPURenderer` is `[.app]`); enforced in `Runtime.start`.
</content>
