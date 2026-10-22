# Apple targets (iOS + macOS)

Apple's native UI *is* SwiftUI, so the compiled cells link the shared app
against the real thing; the wasm cells run the same app as a reactor (WAMR /
WasmKit) whose `tree.fbs` renders as real SwiftUI via `WasmView` →
`IsomerTreeView`. Every app is one `bazel run`: macOS apps open directly,
iOS apps boot the simulator themselves.

| App | `bazel run` target | SwiftUI delivery |
| --- | --- | --- |
| full · compiled · macOS | `//examples/apple/example_full_compiled_macos_application` | native (real SwiftUI) |
| full · compiled · iOS | `//examples/apple/example_full_compiled_ios_application` | native (real SwiftUI) |
| full · wasm · macOS | `//examples/apple/example_full_wasm_macos_application` | wasm reactor → `IsomerTreeView` |
| full · wasm · iOS | `//examples/apple/example_full_wasm_ios_application` | wasm reactor → `IsomerTreeView` |
| partial · compiled · macOS | `//examples/apple/example_partial_compiled_macos_application` | one SwiftUI feature in a native app |
| partial · compiled · iOS | `//examples/apple/example_partial_compiled_ios_application` | one SwiftUI feature in a native app |
| partial · wasm · macOS | `//examples/apple/example_partial_wasm_macos_application` | one wasm feature in a native app (`WasmView`) |
| partial · wasm · iOS | `//examples/apple/example_partial_wasm_ios_application` | one wasm feature in a native app (`WasmView`) |

Each application also declares a `<name>_project` target that generates an
Xcode project for IDE work.

## Benchmark cells (the minimal "Tap me" counter, iOS on-device)

The cells behind [docs/benchmarks.md#ios](../docs/benchmarks.md#ios). All share
ONE bundle id (`com.LoganShire.IsomerExamples` — free personal teams allow few app
ids), so install one at a time; build with `--ios_multi_cpus=arm64 -c opt`.
Adding `--define=wamr_aot=1` builds the wasm cells **hybrid**: a
`wamrc --xip` AOT image linked into the signed `__TEXT` segment executes in
place by default (iOS forbids dynamically *loaded* executable pages — a `.aot`
file loaded at runtime is killed — but embedded XIP code is signed native
text), and the bundled `.wasm` runs on WAMR's interpreter under
`ISO_FORCE_INTERP=1` (the dynamically-deliverable hotfix tier). Bench mode:
launch with the `ISO_BENCH=1` environment (devicectl:
`DEVICECTL_CHILD_ISO_BENCH=1`); results land in `Documents/bench.json`.
Anchors (uniform across all cells + RN/Valdi, stamps by native in-process
code): startup = process init → the first content frame laid out and handed
off for rendering; tap = trigger receipt → the update laid out and submitted
(post-CA-commit runloop observer / manual Metal draw-commit) — no
frame-timing anchors. See docs/benchmarks.md#ios.

| Cell | target |
| --- | --- |
| native SwiftUI (baseline) | `//examples/apple/tap_counter_native_ios_application` |
| UUI compiled + SwiftUI | `//examples/apple/tap_counter_compiled_ios_application` |
| UUI compiled + Metal (SwiftGPU, self-drawing) | `//examples/apple/tap_counter_metal_compiled_ios_application` |
| UUI wasm + SwiftUI (AOT hybrid with `--define=wamr_aot=1`) | `//examples/apple/tap_counter_wasm_ios_application` |
| UUI wasm + Metal (SwiftGPU; AOT hybrid with `--define=wamr_aot=1`) | `//examples/apple/tap_counter_metal_wasm_ios_application` |

Provisioning bootstrap (once per 7 days on a free team): build any Xcode
project with the shared bundle id against the device (`xcodebuild
-allowProvisioningUpdates -allowProvisioningDeviceRegistration`) — the
Xcode-managed profile it mints is what the bazel `local_provisioning_profile`
targets pick up. First install requires trusting the developer on-device.

## Configs

| Flag | Effect |
| --- | --- |
| `--config=map` | links swift_map (Metal) → the `Map` tab renders real OpenStreetMap tiles (dev dependency, example-apps-only; placeholder pane without it) |
| `--config=release` | `-c opt`; wasm reactors ship as a wamrc `.aot` loaded from disk — **macOS only**: iOS forbids dynamically loaded executable pages (the `.aot` is killed on load) |
| `--define=wamr_aot=1` (iOS) | wasm cells embed a `wamrc --xip` AOT image in the signed `__TEXT` segment (executes in place — the iOS-legal AOT) and keep the `.wasm` interpreter fallback behind `ISO_FORCE_INTERP=1` |

Builds need the local Xcode (everything else is hermetic). On-device iOS runs
are gated by code signing — the benchmark numbers in
[docs/benchmarks.md](../docs/benchmarks.md#ios) await a provisioned device;
simulator observations are noted there.
