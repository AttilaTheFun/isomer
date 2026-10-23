# Android targets

Every app is one `bazel run` — `apk_install_run` builds the APK, boots the
hermetic emulator if no device is attached (`bazel run //tools/android/emulator`
runs it standalone), installs, launches, and streams logcat. All commands below
also take a real device via plain `adb` (`ANDROID_SERIAL=<serial>`).

Android has **two pluggable renderers** — the Jetpack **Compose** interpreter
(the platform's component system) and the self-drawing **SwiftGPURenderer**
(OpenGL ES bound at the SwiftGPU level). Compose draws under **both
runtimes** (compiled Swift `.so`, or a wasm reactor under WasmKit); the GPU
renderer draws compiled Swift (its wasm cell, `WasmGpuView` over WAMR, went
with WAMR in 0.38). See
[docs/benchmarks.md](../docs/benchmarks.md) for the measured matrix.

## Example apps (the full 7-tab catalog)

| App | `bazel run` target | Runtime | Renderer |
| --- | --- | --- | --- |
| full · compiled | `//examples/android/example_full_compiled_android_application` | Swift `.so` | Compose (default) · GPU — switchable, see below |
| full · wasm | `//examples/android/example_full_wasm_android_application` | WasmKit | Compose interpreter (`WasmView`) |
| full · native reference | `//examples/android/example_full_native_android_application` | Kotlin | hand-written Compose (parity reference) |
| partial · compiled | `//examples/android/example_partial_compiled_android_application` | Swift `.so` | one SwiftUI feature embedded in a native app |
| partial · wasm | `//examples/android/example_partial_wasm_android_application` | WasmKit | one wasm feature embedded in a native app (`WasmView`) |

The compiled app's renderer is chosen **at launch** (the APK carries all three);
after `bazel run` once, relaunch with:

```sh
adb shell am start -S -n dev.isomer.example/.MainActivity --es renderer jetpackCompose  # default
adb shell am start -S -n dev.isomer.example/.MainActivity --es renderer openGL
```

## Benchmark cells (the minimal "Tap me" counter)

The behavior-identical counter cells behind the numbers in
[docs/benchmarks.md](../docs/benchmarks.md) (the RN/Valdi twins live in their
own repos — see that doc). Build these with `--config=release`.

| Cell | `bazel run` target | Launch variants (`adb shell am start …`) |
| --- | --- | --- |
| native Compose (baseline) | `//examples/android/tap_counter_native_android_application` | — |
| compiled × {Compose, GPU} | `//examples/android/tap_counter_compiled_android_application` | `--es renderer jetpackCompose\|openGL` |
| wasm × Compose | `//examples/android/tap_counter_wasm_android_application` | `--ez offMainInit true` (init-threading A/B) |

Benchmark protocol (uniform ART state, realistic presses, the frame-accurate
`[content-frame]` startup signal) is documented in
[docs/benchmarks.md](../docs/benchmarks.md#android) — in particular, force
`cmd package compile -m speed -f <pkg>` on every app before measuring.

## Configs

| Flag | Effect |
| --- | --- |
| `--config=release` | `-c opt` (wasm reactors ship as interpreted `.wasm` under WasmKit; WAMR's `.aot` tier was removed in 0.38) |
| `--config=map` | links swift_map into the SwiftUI modules → the `Map` tab renders real OpenStreetMap tiles (swift_map is a dev dependency, example-apps-only; without the flag `Map` shows a placeholder pane) |
| *(none)* | debug loop: placeholder maps |

Renderer (`--es renderer …`) and init-threading (`--ez …`) switches are intent
extras, not build flags: one APK, chosen at launch.
