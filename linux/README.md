# Linux targets

The native Linux build of the Isomer example app. Both cells run the same
shared `examples/shared/example_application/ExampleApp.swift`, hosted in an **SDL2**
window and drawn on the GPU through **SwiftGPU → OpenGL**. They differ only in
how the SwiftUI is *delivered*:

| Cell | Target | SwiftUI delivery |
| --- | --- | --- |
| **compiled** | `//examples/linux/example_full_opengl_compiled_linux_application` | linked into the ELF as native Swift |
| **wasm** | `//examples/linux/example_full_opengl_wasm_linux_application` | an `example_full.wasm` reactor run under WasmKit (the bundled one; an explicit reactor path as `argv[1]` wins) |

Benchmark cells (docs/benchmarks.md#linux): the shared tap-counter as
`//examples/linux/tap_counter_compiled_linux_application` (compiled Swift)
and `//examples/linux/tap_counter_native_linux_application` (the
hand-written GTK3 baseline, no Swift; tagged `manual`, links the system GTK);
the wasm rows reuse the example wasm loader with a tap-counter reactor path.
All three self-drive under `ISO_BENCH=1` (see `DesktopBench`).

OpenGL is the only renderer on Linux (there is no `partial` GPU cell — the
partial adoption model doesn't apply to a self-drawing GPU renderer). See the
main [README](../README.md#native-linux-target) for what the app itself does,
and [docs/desktop_wasm_implementation_notes.md](../docs/desktop_wasm_implementation_notes.md)
for how the wasm cell works.

## Configs

| Flag | Effect |
| --- | --- |
| `--config=map` | links swift_map (OpenGL) → the `Map` tab renders real OpenStreetMap tiles (swift_map is a dev dependency, example-apps-only; placeholder pane without it) |
| `--config=release` | `-c opt` (the wasm cell's reactor stays interpreted `.wasm` under WasmKit; WAMR's `.aot` tier was removed in 0.38) |
| *(none)* | debug loop: placeholder maps |

## Prerequisites

Both cells are **built on a Linux host** with rules_swift's host Swift toolchain
(the swift.org `ubuntu24.04` standalone toolchain, fetched by Bazel). The C
renderer links the system SDL2 / SDL2_ttf / Mesa GL / libcurl — install the dev
packages plus a C toolchain (clang; rules_swift's Linux toolchain rejects gcc):

```sh
# Debian/Ubuntu
sudo apt install build-essential clang libsdl2-dev libsdl2-ttf-dev libgl1-mesa-dev \
    libcurl4-openssl-dev libwebkit2gtk-4.1-dev   # webkit is optional (embedded WebView)

# Arch / SteamOS
sudo pacman -S base-devel clang sdl2 sdl2_ttf mesa libglvnd curl webkit2gtk-4.1
```

The workspace `.bazelrc` sets `CC=clang` on Linux hosts automatically. On
Arch/SteamOS also symlink the ncurses soname `swiftc` links against:
`sudo ln -sf libncursesw.so.6 /usr/lib/libncurses.so.6`.

## Running the compiled cell

```sh
bazel run //examples/linux/example_full_opengl_compiled_linux_application
```

An SDL2 window comes up with the responsive shell (three-pane split when wide,
tab bar when narrow), drawn on the GPU with OpenGL.

From a **Windows** machine, run it inside WSL2 — WSLg shows the window on your
Windows desktop (see [Under WSL](#under-wsl) below for the display-env caveat
when running as root):

```powershell
wsl -d Ubuntu-24.04 -- bash -lc "cd ~/src/isomer && bazelisk run //examples/linux/example_full_opengl_compiled_linux_application"
```

## Running the wasm cell

Unlike Windows, the SwiftWasm toolchain runs on Linux, so the reactor **is
bundled** — the wasm cell builds `example_full.wasm` as a data dependency and
runs standalone:

```sh
bazel run //examples/linux/example_full_opengl_wasm_linux_application
```

The `run_linux_wasm.sh` wrapper points `LD_LIBRARY_PATH` at the swift.org runtime
and passes the bundled reactor as the first argument; the ELF loads those bytes
under WasmKit and draws the decoded tree through the same OpenGL renderer. The first
build cross-compiles the reactor via SwiftWasm (a few minutes); later builds are
incremental.

### Under WSL

The app is a GUI app rendered through WSLg (on Mesa **llvmpipe** software GL). As
the default WSL user this works out of the box; as `-u root` you must set the
display env, which root's shell doesn't inherit:

```bash
wsl -d Ubuntu-24.04 -u root -- bash -lc "cd ~/src/isomer && DISPLAY=:0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir bazelisk run //examples/linux/example_full_opengl_wasm_linux_application"
```

## Hot reload

The reactor is delivered over plain HTTP, so the app never runs a compiler
itself and one server can drive several apps at once — including a Linux and a
Windows app **simultaneously**. Start the server (it shells out to `bazel build`
to recompile the reactor on each edit):

```sh
bazel run //shared/hot_reload:hot_reload_server
```

It watches `examples/shared/example_application/*.swift`, rebuilds `example_full.wasm` on
every edit, and serves it on `http://0.0.0.0:8787` (`GET /version`, `GET /wasm`).
Launch the wasm cell wired to it and edit any source file in
`examples/shared/example_application/` — the running window re-renders without restarting:

```sh
ISO_HOT_RELOAD_SERVER=http://localhost:8787 \
  bazel run //examples/linux/example_full_opengl_wasm_linux_application
```

With the server set, the cell loads the initial reactor from it (falling back to
the bundled one if unreachable) and polls for rebuilds. Config env vars (server
side): `ISO_HOT_RELOAD_PORT` (default `8787`), `ISO_HOT_RELOAD_TARGET` (default
the full example reactor), `ISO_HOT_RELOAD_WATCH` (default
`examples/shared/example_application`).
