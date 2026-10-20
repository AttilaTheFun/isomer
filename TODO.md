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
