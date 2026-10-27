# TODO

Open items that are not yet tracked in code or docs.

## Toolchain

- **Upstream the WASI-threads work into swift.** The `wasm32-wasip1-threads`
  global-executor change (a pthread-pool `WASIGlobalExecutor` so
  async/TaskGroup fan out on real cores) lives on our branch as
  swiftlang/swift PR #90715 (base `main`), with the companion rules_swift
  PR #1860 for the threads `{target_triple}`. Land #90715, then the
  `release/6.4.x` cherry-pick, then bump swiftwasm-build's base tag.
  Context: memory notes "wasi-threads Swift wasm" / "wasi-threads
  concurrency upstream"; docs/benchmarks.md (Parallelism section).

## Hermetic builds (tabled)

- **Swift 6.4.0 everywhere.** Isomer pins Swift 6.3.2 for its host, wasm
  and Android toolchains. Moving all of them to 6.4.0 (the Swift that built
  Xcode 27.0's SDKs) means:
  - rules_swift 4.x, with the two patches in tools/patches ported (a new
    registry version);
  - rules_apple 5.x and apple_support 2.10, with rules_applecross's patches;
  - the swift-foundation fork on 6.4.0;
  - the wasi-threads SDK for 6.4;
  - swift-syntax 604;
  - the Playground's on-device compilers.

  rules_applecross alone doesn't need it: it brings swift.org's 6.4.0 for
  the Apple targets only, beside 6.3.2.
- **Building on a Mac without Xcode.**
  - rules_applecross stages the SDKs from the SDK archive on a Mac with no
    Xcode (its #213).
  - Bazel's XcodeLocalEnvProvider still looks up an installed Xcode
    (xcode-locator, then `xcrun --sdk … --show-sdk-path`) for every action
    that names XCODE_VERSION_OVERRIDE or APPLE_SDK_PLATFORM. Linux hosts
    skip it.
  - Bundling on a Mac runs Xcode's own tools, while the clean-room
    actool, ibtool and codesign exist only as Linux builds.
  - The exec configuration's host tools (swift-syntax and the macros,
    swift_ffi's generator, flatc, protoc) need a C/C++ toolchain and a
    macOS SDK: perhaps the staged MacOSX.sdk with the hermetic `llvm`
    clang.
  - The Linux-native targets, built from a Mac, need a Linux sysroot.
  - To check first: nested virtualization, so that a macOS VM runs the
    Linux-container build itself.

## Consuming the SwiftUI module from packages

- **Apple framework for the `SwiftUI` module.** A SwiftPM package whose
  sources `import SwiftUI` (e.g. MessagesUI) currently reaches our module
  on wasm/Android/Linux/Windows only through rules_swift_package_manager's
  `target_deps` hook, which rewrites the generated package target's
  dependencies to add `@isomer//:swift_ui`. That requires the
  ability to rewrite a package's dependency graph; a prebuilt framework
  (static or dynamic, an xcframework per platform slice) is just a linker
  flag, so any build system could link it. Decide static vs dynamic, how
  the per-platform host modules (IsomerBridge, SwiftUIExtensions, the
  skim Foundation) ship alongside, and whether the module name `SwiftUI`
  can coexist with the system framework on Apple targets (it should never
  be linked there — the system SwiftUI is the drop-in).

- **Pure SwiftPM (and other build systems) for swift_ffi.** On the Swift
  side all the C-ABI codegen is done by the `@ExportedInterface` /
  `@ExportedFunction` macros, so a package only needs the macro plugin and
  the runtime library. The analyzer + generator (TypeScript, Kotlin, C++,
  Rust, C hosts) are a separate CLI today, driven by the Bazel aspect;
  expose them as a SwiftPM build-tool plugin (and a plain CLI invocation)
  so a package can produce its bindings without Bazel, then add
  integrations for other build systems — a Gradle plugin for the Kotlin
  facade + JNI adapter, an npm/tsc step for the web bridge.
