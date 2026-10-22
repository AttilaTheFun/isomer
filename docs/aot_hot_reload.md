# AOT, hot reload and CI simulator shells

What a dynamically delivered bundle runs on, where ahead-of-time code fits,
and how the same machinery turns Mac CI runners into thin "shell" executors.
(Native-code reload tiers — a server-compiled artifact on macOS, an
in-process compiler in the simulator and on Android — were removed in 0.35;
every reloaded bundle is interpreted now. WAMR, and with it the packaged
ahead-of-time tier below, was removed in 0.38: every bundle, packaged or
reloaded, runs on WasmKit's interpreter.)

## The tiers

| Bundle | Artifact | Engine |
|---|---|---|
| hot-reloaded / dynamically delivered | plain `.wasm` (`/wasm`) | the registered engine's interpreter: WasmKit (`WasmKitRuntime`) unless the app registers another |
| packaged (every platform, debug and release) | plain `.wasm` | the same |

`WasmRuntimeRegistry.make(for:)` makes the registered engine for every
bundle.

Until 0.38 the packaged tiers were WAMR's: a wamrc `.aot` under `--define
wamr_aot=1` (Android, desktop) and an embedded XIP `.aot` in the signed
`__TEXT` on an iOS device. wamrc was never in the reload loop (lowering the
18 MB example reactor took ~9 min single-threaded even at
`--opt-level=0`).

## The pieces

- **Server** (`HotReloadServer.swift`: the macOS one in
  `examples/apple/example_partial_wasm_macos_application`, the Linux peer in
  `shared/hot_reload`): watches the feature's sources, rebuilds the reactor,
  and serves `/version` (a build counter), `/wasm` (the bytes) and
  `/clients` (who polled recently).
- **Client** (`AppBundleProvider`, apple/libraries/wasm_view): with
  `ISO_HOT_RELOAD_SERVER` set it polls `/version` and fetches `/wasm` on
  each bump; with `ISO_WASM_PATH` it watches a file instead. Either shadows
  the packaged bundle.
- **Android**: the host renders an animating reactor once per display frame
  (Choreographer, in WasmView.kt's `scheduleRender`); posted as plain
  messages, an animating reactor rendered three or four times a displayed
  frame. `adb shell setprop debug.isomer.wasm.perf
  1` logs where a second's wasm calls went.

## CI: cached shells + injected features

The Mac-builder bottleneck: only linking + bundling *needs* macOS. The shell
model splits the work:

1. **Shell** (Mac, cacheable): the simulator app with its compiled native
   components and `WasmView`. Rebuilds only when *shell* inputs change —
   feature code is NOT an input. Cache the `.app` by the hash of its deps.
2. **Feature** (Linux RBE): wasm32 reactors cross-compile on Linux — the
   toolchains are already registered (ubuntu exec toolchains for the wasm32
   platform transition). Artifact: plain `.wasm`.
3. **Test run** (Mac, thin): boot sim → install cached shell → launch with
   `SIMCTL_CHILD_ISO_HOT_RELOAD_SERVER` pointed at a trivial file server (or
   `SIMCTL_CHILD_ISO_WASM_PATH` + `simctl` file push) → the shell interprets
   the reactor → assert on `ISO_DUMP_TREE` output / screenshots.

The Mac runner never compiles Swift for a feature change — it executes a
prebuilt shell and feeds it Linux-built bytes.
