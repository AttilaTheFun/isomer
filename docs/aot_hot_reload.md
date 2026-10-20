# AOT, hot reload and CI simulator shells

What a dynamically delivered bundle runs on, where ahead-of-time code fits,
and how the same machinery turns Mac CI runners into thin "shell" executors.
(Native-code reload tiers — a server-compiled artifact on macOS, an
in-process compiler in the simulator and on Android — were removed in 0.35;
every reloaded bundle is interpreted now.)

## The tiers

| Bundle | Artifact | Engine |
|---|---|---|
| hot-reloaded / dynamically delivered | plain `.wasm` (`/wasm`) | the registered engine's interpreter: WAMR by default, WasmKit where the app registers it (Apple) |
| packaged, release (Android, desktop) | wamrc `.aot` (`--define wamr_aot=1`) | WAMR's AOT loader |
| packaged, iOS device | embedded XIP `.aot` (`embedded_xip_aot`, in the signed `__TEXT`) | WAMR, in place (`iso_wamr_create_in_place`, `WamrRuntime.embeddedImage`) |

`WasmRuntimeRegistry.make(for:)` makes the registered engine for every
bundle; WAMR tells `\0asm` from wamrc's `\0aot` itself.

**wamrc is not in the reload loop**: lowering the 18 MB example reactor takes
~9 min single-threaded even at `--opt-level=0`. wamrc `.aot` is the packaged
release tier, where compile time is a build cost, not an edit-loop cost.

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
  (Choreographer), and not at all for a render asked for inside an event's
  handler, which the event's own render answers (`gate_schedule` in
  iso_wamr.c); posted as plain messages, an animating reactor rendered three
  or four times a displayed frame. `adb shell setprop debug.isomer.wasm.perf
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
