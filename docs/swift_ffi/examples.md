# The example matrix

The examples are the repo's living integration tests *and* the template for
how a consumer should lay out their own project. One annotated
`swift_library` — [`//swift_ffi/examples/shared/greeter`](../../swift_ffi/examples/shared/greeter) —
exercises the full bridge surface (functions, structs, interfaces in both
directions, `throws`, `async`, bytes) and is delivered **unchanged** by every
cell in a platform × mode matrix.

## Modes

- **compiled** — the greeter linked natively and called over its generated
  C/JNI ABI. No interpreter anywhere.
- **wasm** — the greeter compiled to a WebAssembly reactor and run under an
  engine: [WAMR](https://github.com/bytecodealliance/wasm-micro-runtime)
  driven from C (`//swift_ffi/runtime/c_host_wamr`) everywhere except the
  web, where the browser itself is the engine. No compiled Swift on the host.

## The matrix

Cells are named `//swift_ffi/examples/<platform>/example_<platform>_<mode>_application`.

| Platform | `compiled` | `wasm` | wasm engine |
| --- | :---: | :---: | --- |
| linux   | ✓ | ✓ | WAMR (C host) |
| windows | ✓ | ✓ | WAMR (C host) |
| android | ✓ | ○ | WAMR (via JNI) |
| ios     | ✓ | ○ | WAMR |
| macos   | ○ | ○ | WAMR |
| web     | — | ✓ | the browser's own WebAssembly |

**✓** runnable today · **○** same shape, not yet wired · **—** not applicable
(the browser runs Swift only as wasm).

You can `bazel run` a platform cell only on that OS — windows on Windows,
linux on Linux, android/ios on a Mac — while web runs from any host:

```sh
# Linux (from a Linux host / WSL):
bazel run //swift_ffi/examples/linux/example_linux_compiled_application
bazel run //swift_ffi/examples/linux/example_linux_wasm_application

# Windows (from a Windows host):
bazel run //swift_ffi/examples/windows/example_windows_compiled_application
bazel run //swift_ffi/examples/windows/example_windows_wasm_application

# Web (from any host):
bazel run //swift_ffi/examples/web/example_web_wasm_application

# Android (macOS/arm64, hermetic emulator) and iOS (Mac, simulator):
bazel run //swift_ffi/examples/android/example_android_compiled_application
bazel run //swift_ffi/examples/ios/example_ios_compiled_application
```

## What each verified cell demonstrates

- **web** — the generated TypeScript + wasm reactor, typechecked by
  `ts_project` (`tsc --strict`, including the *generated* .ts), bundled by
  rules_esbuild, opened in a hermetic Electron window (macOS/arm64).
  `:greeter_web_test` is a `js_test` running the compiled ESM under the
  hermetic Node with assertions: scalars, Unicode string round trip, counter
  lifecycle, idempotent close, use-after-close throws.
- **android** — a real rules_android APK (`kt_android_library` consuming the
  generated Kotlin) on the hermetic emulator. Verified: string copy, scalars,
  interface handle via `use { }`.
- **ios** — a plain SwiftUI app (simulator) importing the annotated library
  *directly*: on Apple platforms there is no bridge and the macros are inert.
  `:example_ios_compiled_application_project` generates an Xcode project via
  rules_xcodeproj.
- **linux / windows, both modes** — the same greeter surface (`greeting`,
  `add`, `isEven`, `checksum`) printed identically whether natively linked
  (compiled) or run as a reactor under WAMR with no Swift on the host (wasm).

## Shared building blocks (`examples/shared/`)

- `greeter` — the one annotated `swift_library`, plus its generated C-mode
  glue (`greeter_c`), C header, c-host bindings, and `.wasm` reactor.
- `greeter_compiled_host` — the C driver behind the desktop compiled cells;
  each platform application is a thin `main` over it.
- `greeter_wasm_host` — the C driver behind the desktop wasm cells (reactor
  under WAMR). The generated c-host header's functions are `static`, so this
  library is the single translation unit that includes it.
- `greeter_host` — the `swift_wasm_library` building block: native-Swift host
  bindings + reactor, compile-checking the `swift-host-wasm` generator kind
  over the full surface.
- `greeter_aot_bench` — cold-start benchmark: the reactor as interpreted
  `.wasm` vs a wamrc-produced native `.aot` over the same C host. Requires
  `--define wamr_aot=1` (links the AOT loader and builds `wamrc`).

## Operational notes

- The hermetic Android emulator (arm64-v8a, API 34) and Electron are declared
  at the bottom of `MODULE.bazel`; no host `ANDROID_HOME`/Node is used.
- **Emulator cold boot**: the first `adb install` can fail with
  "Broken pipe" even after boot/pm-ready checks (the system server can
  restart mid-boot). Rerunning succeeds; wrap installs in a retry loop if
  scripting.
- A change to the generator or a runtime isn't done until the affected cells
  still build — and run, where your host OS allows. On macOS,
  `bazel build //swift_ffi/examples/...` covers the web, Android, iOS, and shared
  targets.
