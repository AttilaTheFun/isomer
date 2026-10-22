# Linux + Windows: WAMR wasm engine and the full/partial matrix

> **Superseded in 0.38.** WAMR was removed: the Linux and Windows hosts now
> run reactors on WasmKit (`LinuxWasmHost`/`WindowsWasmHost` drive
> `WasmFeatureRuntime` over `WasmKitRuntime`, //shared/wasm_host; the entry
> module is `IsomerDesktopWasmHost`), as every native host does. `@wamr`,
> `//shared/wamr_host` and `WamrRuntime` are gone. What follows is the plan
> as it stood under WAMR.

Goal (parity with the other platforms): run the *same* WAMR wasm interpreter on
the Linux and Windows desktop hosts that Android already uses, and give each a
**2×1 matrix** — `full` and `partial` — with a single fixed renderer per OS:

| platform | renderer | targets |
| --- | --- | --- |
| linux   | opengl  | `example_{full,partial}_opengl_linux_application` ✅ both exist |
| windows | directx | `example_{full,partial}_directx_windows_application` ✅ both exist |

Unlike Apple/Android (which carry a `compiled`/`wasm` axis) and web/electron
(which carry a `react`/`webgpu` axis), Linux and Windows expose only the
`full`/`partial` axis — the renderer is fixed (OpenGL on Linux, DirectX on
Windows), both drawn by the self-drawing `SwiftGPURenderer`.

## Why this can't be built from a macOS host

The Linux and Windows apps are **native-host** builds (`target_compatible_with`
`@platforms//os:{linux,windows}`): they compile the shared Swift app to a native
ELF/PE and own `main` + the SDL2/Win32 window and render loop themselves. They
are *not* cross-compiled via a platform transition the way the wasm/Android
targets are — they build **on** a Linux/Windows machine with that host's Swift
toolchain. There is no registered Linux/Windows platform or cross toolchain in
this repo, so on a macOS host these targets are cleanly *skipped*. Everything in
"Remaining work" below therefore has to be built and verified on the target OS.

## Done

- **Linux WAMR engine enabled.** `@wamr` already had Linux as its
  `//conditions:default` branch (`BH_PLATFORM_LINUX`, the POSIX platform
  sources, `core/shared/platform/linux/platform_init.c`). Two fixes landed:
  - The native-call trampoline asm is now chosen by **CPU** via the
    `:linux_x86_64` / `:linux_arm64` config settings (desktop Linux is x86_64 →
    `invokeNative_em64.s`). The old default branch hardcoded
    `invokeNative_aarch64.s`, which is wrong for an x86_64 ELF.
  - `//shared/wasm_host` (`wasm_runtime` / `wamr_runtime` / `wasm_host`) is now
    `target_compatible_with` Linux, so `WamrRuntime` — the same Swift engine
    verified on macOS/iOS — is available to the Linux host. The Swift is
    platform-agnostic; no per-OS engine code is needed.

- **Naming standardized.** The Windows target is
  `example_full_directx_windows_application` (was `…_direct2d_…`). Direct2D is
  the DirectX 2-D API it draws through; the label uses the matrix's `directx`.

- **The 2×1 matrix cells exist.** Added `example_partial_opengl_linux_application`
  and `example_partial_directx_windows_application`, so each OS now has both
  `full` and `partial`. Each `partial` cell runs one shared feature
  (`//examples/shared/embedded_example`, whose `EmbeddedExampleApp` is the `@main`) as a
  native ELF/PE — the desktop analogue of Apple's `example_partial_compiled`.
  It clones the verified `full` target's BUILD with only the source archive
  swapped, so it is correct by mirroring, but like the `full` cell it is a
  native-host build and must be compiled/run **on** Linux/Windows — it cannot be
  built from this macOS host. Target labels verified via `bazel query`.

## Remaining work (must be done on a Linux / Windows host)

1. **Windows `@wamr` platform layer.** Windows is *not* yet in
   `_NATIVE_WASM_HOSTS`. `@wamr`'s `srcs` glob pulls
   `core/shared/platform/common/posix/*.c`, which does not compile on Windows;
   Windows needs `core/shared/platform/windows/*.c`, `-DBH_PLATFORM_WINDOWS`,
   the `core/shared/platform/windows` include dir, and the Windows-x64 call
   trampoline. Add a `:windows_x86_64` config setting and Windows branches to
   the `@wamr` selects (mirroring the Linux/Android branches), and swap the
   POSIX glob for a per-OS select. Then add `@platforms//os:windows: []` to
   `_NATIVE_WASM_HOSTS`.

2. **The wasm-delivered variant (optional enhancement).** The `full`/`partial`
   cells above are native *compiled* Swift (like the pre-existing `full` cell,
   and like Apple's `compiled` column). To also run these apps as a *wasm*
   bundle under the now-enabled Linux WAMR engine — the "same interpreter as
   Android" story — drive `WasmFeatureRuntime` (`//shared/wasm_host:wasm_host`)
   with e.g. `//examples/wasm/example_full_feature:example_full.wasm`, feed
   each emitted `tree.fbs` frame into the existing `SwiftGPURenderer` +
   SDL2/Win32 loop (see `linux/libraries/swift_ui/LinuxHost.swift`), and route
   input back through `iso_hot_event`. This is the desktop analogue of Apple's
   `WasmView` host, minus SwiftUI — the render sink is `SwiftGPURenderer`, which
   already runs on both OSes. (Linux/Windows carry only the `full`/`partial`
   axis, so this is a delivery mode of the same cells, not new matrix targets.)

3. **On-host verification.** Build + run each cell on Linux and Windows;
   confirm the WAMR module load/run cost is acceptable (Android measured module
   load at ~241 ms and cold start ~2.8 s for the full reactor — desktop should
   be comparable or better).
