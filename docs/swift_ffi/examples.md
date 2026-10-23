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
  engine: the browser's on the web. Native wasm cells would run it under
  [WasmKit](https://github.com/swiftwasm/WasmKit) through the swift-host
  bindings (`greeter_host`), as Isomer's hosts do. The Linux and Windows
  wasm cells drove [WAMR](https://github.com/bytecodealliance/wasm-micro-runtime)
  from C (`//swift_ffi/runtime/c_host_wamr`) and were removed with it in
  0.38 (WasmKit has no C API).

## The matrix

Cells are named `//swift_ffi/examples/<platform>/example_<platform>_<mode>_application`.

| Platform | `compiled` | `wasm` | wasm engine |
| --- | :---: | :---: | --- |
| linux   | ✓ | ○ | WasmKit (Swift host) |
| windows | ✓ | ○ | WasmKit (Swift host) |
| android | ✓ | ○ | WasmKit (Swift host) |
| ios     | ✓ | ○ | WasmKit (Swift host) |
| macos   | ○ | ○ | WasmKit (Swift host) |
| web     | — | ✓ | the browser's own WebAssembly |

**✓** runnable today · **○** same shape, not yet wired · **—** not applicable
(the browser runs Swift only as wasm).

You can `bazel run` a platform cell only on that OS — windows on Windows,
linux on Linux, android/ios on a Mac — while web runs from any host:

```sh
# Linux (from a Linux host / WSL):
bazel run //swift_ffi/examples/linux/example_linux_compiled_application

# Windows (from a Windows host):
bazel run //swift_ffi/examples/windows/example_windows_compiled_application

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
- **linux / windows, compiled** — the greeter surface (`greeting`, `add`,
  `isEven`, `checksum`) printed by a C `main` over the natively linked
  library. (Until 0.38 a wasm cell printed the same from a reactor under
  WAMR, with no Swift on the host.)

## Shared building blocks (`examples/shared/`)

- `greeter` — the one annotated `swift_library`, plus its generated C-mode
  glue (`greeter_c`), C header, c-host bindings (for a C host that brings its
  own engine), and `.wasm` reactor.
- `greeter_compiled_host` — the C driver behind the desktop compiled cells;
  each platform application is a thin `main` over it.
- `greeter_host` — the `swift_wasm_library` building block: native-Swift host
  bindings + reactor, compile-checking the `swift-host-wasm` generator kind
  over the full surface.

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
