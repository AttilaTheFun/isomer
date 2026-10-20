# Windows targets

The native Windows build of the Isomer example app. Both cells run the
same shared `examples/shared/example_application/ExampleApp.swift`, hosted in a Win32
window and drawn on the GPU through **SwiftGPU → Direct3D 11 / Direct2D**. They
differ only in how the SwiftUI is *delivered*:

| Cell | Target | SwiftUI delivery |
| --- | --- | --- |
| **compiled** | `//examples/windows/example_full_directx_compiled_windows_application` | linked into the `.exe` as native Swift |
| **wasm** | `//examples/windows/example_full_directx_wasm_windows_application` | an `example_full.wasm` reactor run under WAMR (interp, or a `.aot` passed as `argv[1]`) |

Benchmark cells (docs/benchmarks.md#windows): the shared tap-counter as
`//examples/windows/tap_counter_compiled_windows_application` (compiled
Swift) and `//examples/windows/tap_counter_native_windows_application`
(the hand-written Win32 baseline, no Swift); the wasm rows reuse the example
wasm loader with a tap-counter reactor path. All three self-drive under
`ISO_BENCH=1` (see `DesktopBench`).

DirectX is the only renderer on Windows (there is no `partial` GPU cell — the
partial adoption model doesn't apply to a self-drawing GPU renderer). See the
main [README](../README.md#native-windows-target) for what the app itself does,
and [docs/desktop_wasm_implementation_notes.md](../docs/desktop_wasm_implementation_notes.md)
for how the wasm cell works.

## Configs

| Flag | Effect |
| --- | --- |
| `--config=map` | links swift_map (Direct3D 11) → the `Map` tab renders real OpenStreetMap tiles (swift_map is a dev dependency, example-apps-only; placeholder pane without it) |
| `--config=release` | `-c opt --define=wamr_aot=1`; compiles the AOT loader into the wasm cell (MSVC). The Windows-ABI `.aot` itself is cross-produced on a macOS/Linux host: `wamrc --target=x86_64 --target-abi=msvc --size-level=0` (size-level=0 is required — default-level `.aot`s fail ADDR32 relocation on load; see swift_ffi's TODO.md) — then passed as `argv[1]` |
| *(none)* | debug loop: interpreted wasm, placeholder maps |

## Prerequisites

Both cells are **built on a Windows host** (Swift can't be cross-compiled *to*
Windows — see the [main README](../README.md#native-windows-target)):

- The **Swift for Windows** toolchain (swift.org 6.3.2). The installer adds the
  toolchain + runtime dirs to your `PATH`; the build relies on that (see
  [Toolchain PATH](#toolchain-path-note) below).
- **Visual Studio Build Tools** (MSVC + the Windows 10/11 SDK).
- **Bazel / bazelisk**.

## Running the compiled cell

```powershell
bazelisk run //examples/windows/example_full_directx_compiled_windows_application
```

A per-monitor-DPI-aware Win32 window comes up with the responsive shell
(three-pane split when wide, tab bar when narrow). Nothing else to set up.

## Running the wasm cell

The wasm cell is a thin loader: it reads an `example_full.wasm` reactor and runs
it under WAMR, drawing the decoded tree through Direct3D 11. The SwiftWasm
toolchain that compiles `.wasm` doesn't run on a Windows host, so **build the
reactor where it does** (WSL/Linux/macOS):

```bash
bazel build -c opt //examples/wasm/example_full_feature:example_full.wasm
```

(the bytes are host-agnostic — the same reactor runs on every platform), then
pass its path as an argument (note the `--`, so Bazel forwards it to the app
instead of parsing it as a flag) …

```powershell
bazelisk run //examples/windows/example_full_directx_wasm_windows_application -- C:\path\to\example_full.wasm
```

… or point it at a hot-reload server (see [Hot reload](#hot-reload)):

```powershell
$env:ISO_HOT_RELOAD_SERVER = "http://localhost:8787"
bazelisk run //examples/windows/example_full_directx_wasm_windows_application
```

The app resolves its bytes in this order: a hot-reload server if
`ISO_HOT_RELOAD_SERVER` is set and reachable, else the explicit path argument.
(There is deliberately no committed prebuilt reactor: a stale one would rot
against the always-`Patch` wire format, and ~17 MB binaries don't belong in
git history.)

## Hot reload

The reactor is delivered over plain HTTP, so the app never runs a compiler
itself and one server can drive several apps at once — including a Windows and a
Linux app **simultaneously**. Run the server on a Linux/WSL host (it shells out
to `bazel build`, which only cross-compiles `.wasm` there):

```bash
# in WSL / on a Linux host
bazel run //shared/hot_reload:hot_reload_server
```

It watches `examples/shared/example_application/*.swift`, rebuilds `example_full.wasm` on
every edit, and serves it on `http://0.0.0.0:8787` (`GET /version`, `GET /wasm`).
From Windows, reach it at `http://localhost:8787` — WSL2 forwards localhost to
the WSL server (a peer on another machine uses that host's LAN IP). Then launch
the wasm cell with `ISO_HOT_RELOAD_SERVER` set (above) and edit any source file
in `examples/shared/example_application/` — the running window re-renders without
restarting.

Config env vars (server side): `ISO_HOT_RELOAD_PORT` (default `8787`),
`ISO_HOT_RELOAD_TARGET` (default the full example reactor),
`ISO_HOT_RELOAD_WATCH` (default `examples/shared/example_application`).

## Limitations

**The Windows host cannot build the wasm reactor.** Producing `example_full.wasm`
means cross-compiling Swift to `wasm32-unknown-wasip1`, and a Windows-*hosted*
Swift→wasm toolchain is not supported yet. This is blocked at two layers:

- **Upstream Swift.** swift.org states outright that "cross-compilation with
  Swift SDKs on Windows hosts is not supported yet," tracked by
  [swiftlang/swift-package-manager#9148](https://github.com/swiftlang/swift-package-manager/issues/9148)
  (open — the `swift sdk` cross-compile path isn't validated on Windows). The
  Swift SDK *bundle* (wasm stdlib + WASI sysroot) is host-agnostic; what's
  missing is a validated Windows host driver to use it. See the
  [WebAssembly getting-started guide](https://www.swift.org/documentation/articles/wasm-getting-started.html).
- **rules_swift.** The `swift.wasm_sdk` extension only defines wasm toolchains
  for macOS (Xcode) and Linux (swift.org standalone) exec hosts — there is no
  `os:windows` exec branch — so a Windows Bazel host resolves "no matching
  toolchains" for the reactor target.

Consequences, and the workaround:

- The **compiled** cell has no such limitation — it's native Swift and
  `bazel run`s on Windows out of the box.
- The **wasm** cell needs its reactor built on a Linux/macOS host (or under
  WSL, below) and passed as `argv[1]` — or served via `ISO_HOT_RELOAD_SERVER`.
  There is no committed prebuilt.

There has been recent upstream movement on Swift-on-Windows tooling; revisit
wiring a native Windows wasm toolchain once #9148 lands and rules_swift grows a
Windows host path.

## Running the Linux targets from Windows (via WSL)

WSL2 is a fully supported Linux host, so from a Windows machine you can run the
**Linux** example cells — and build wasm reactors — inside it. Install
[WSL](https://learn.microsoft.com/windows/wsl/install) with an Ubuntu distro and
the Linux prerequisites from [linux/README.md](../linux/README.md), then:

```powershell
# Linux compiled cell (WSLg shows the SDL2 window on your Windows desktop)
wsl -d Ubuntu-24.04 -- bash -lc "cd ~/src/isomer && bazelisk run //examples/linux/example_full_opengl_compiled_linux_application"

# Linux wasm cell (as -u root, set the WSLg display env — root's shell doesn't inherit it)
wsl -d Ubuntu-24.04 -u root -- bash -lc "cd ~/src/isomer && DISPLAY=:0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir bazelisk run //examples/linux/example_full_opengl_wasm_linux_application"

# Build a fresh reactor for the Windows wasm cell / hot-reload server
wsl -d Ubuntu-24.04 -- bash -lc "cd ~/src/isomer && bazelisk build //examples/wasm/example_full_feature:example_full.wasm"
```

To hot-reload the Windows wasm cell from a reactor built in WSL, run the
[hot-reload server](#hot-reload) inside WSL and set `ISO_HOT_RELOAD_SERVER` on
the Windows side (WSL2 forwards `localhost`).

## Toolchain PATH note

The wasm cell links swift_ffi, whose `analyzer`/`generator` run as build actions
and must find `swiftCore.dll`. Bazel scrubs the action `PATH`, so the workspace
`.bazelrc` forwards it (`build:windows --action_env=Path`/`PATH`) and swift_ffi's
actions run under the default shell env. This works as long as the Bazel server
was started from a shell whose `PATH` has the Swift `Toolchains\` + `Runtimes\`
dirs (the installer default).

If a build fails with `STATUS_DLL_NOT_FOUND` (exit `-1073741515`), the persistent
server has a stale environment — run `bazelisk shutdown` and rebuild from a shell
that has the Swift dirs on `PATH`.
