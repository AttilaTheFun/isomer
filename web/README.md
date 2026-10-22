# Web targets

The app ships as a wasm bundle the browser JIT-compiles; the renderer is
pluggable — **React** (DOM components) or the self-drawing **SwiftGPU**
(WebGPU). Every app is one `bazel run`: a dev server starts and the browser
opens itself (append `-- --no-open` to suppress).

| App | `bazel run` target | Renderer |
| --- | --- | --- |
| full · React | `//examples/web/example_full_react_web_application` | React (DOM) |
| full · WebGPU | `//examples/web/example_full_webgpu_web_application` | SwiftGPU (WebGPU) |
| partial · React | `//examples/web/example_partial_react_web_application` | one feature embedded in a React page |
| partial · WebGPU | `//examples/web/example_partial_webgpu_web_application` | one feature drawn by SwiftGPU |

Each app also declares a `<name>_site` target (the static site directory) used
by the Electron wrappers — see
`//examples/electron/...` for the desktop shells, including
`:example_windows_package`, which zips the site with the Windows x64 Electron
runtime for machines without a toolchain.

The renderer binding is a **URL query** (`?renderer=react` vs the SwiftGPU
default) — the run targets pass the right one; switch live by editing the URL.

## Configs

| Flag | Effect |
| --- | --- |
| `--config=map` | links swift_map (WebGPU) → the `Map` tab renders real OpenStreetMap tiles (dev dependency, example-apps-only; placeholder pane without it) |

The wasm reactors here run in the *browser's* engine (the native hosts' is
WasmKit) — the browser JIT is the optimizer; `--config=release` is `-c opt`.
