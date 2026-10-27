# TODO

Open items that are not yet tracked in code or docs.

## Upstream releases, no forks

The goal: every dependency at an upstream tagged release (a BCR version, a
SwiftPM version, a swift.org toolchain), with no forks, no patches and no
git or archive overrides. Each change we carry goes upstream, and its fork
or patch goes when a release has it. The project's registry
(AttilaTheFun/bazel_registry) then holds only the project's own modules.
What is carried today (on main, and with #39's rules_applecross):

- **rules_swift**: the registry's 3.6.1.isomer.1 (4.1.0.isomer.2 with #39).
  It is upstream plus:
  - rules_swift#1860, open: a metadata-driven wasm SDK and its threads
    variant;
  - two patches of ours, not yet sent upstream (tools/patches):
    `rules_swift_wasm_threads_beside.patch` (two `swift.wasm_sdk` tags) and
    `rules_swift_wasm_clang_resource_dir.patch` (the SDK's clang headers
    for C compiled for wasm).

  #39 also holds it above the 4.2.2 that rules_applecross asks for.
- **The threads Swift SDK** for wasm: AttilaTheFun/swift's build of 6.3.2
  (branch threads-sdk-6.3.2) with swiftlang/swift#92018. That PR merged on
  2026-10-09 (#90715 was closed in its favour), as did
  swift-platform-executors#33. The fork goes when a swift.org release
  carries them and publishes a wasip1-threads SDK.
- **swift-foundation**: the registry's 6.3.2.isomer.1, AttilaTheFun's fork
  (branch `isomer`). Its fixes for WASI and Android go upstream. What only
  Isomer needs (its declarations made internal, so the `Foundation` module
  stays a subset of Apple's) needs a form upstream would take, such as a
  build setting, or a home outside the fork.
- **WasmKit**: AttilaTheFun/WasmKit at a commit (an `http_archive` with our
  BUILD file), carrying:
  - the engine work: guard pages on iOS, and the dispatch fusions;
  - two patches (tools/patches): Android's software bounds checks, and
    MSVC's C without clang's atomics.

  All of it goes to swiftwasm/WasmKit; then a tagged release, as a module
  or a SwiftPM package.
- **flatbuffers**: two patches, `flatbuffers_foundation_wasi.patch` and
  `flatbuffers_swift_vectors.patch`, go to google/flatbuffers.
  `rules_foreign_cc` is held at 0.15.1, because the 0.10.1 that grpc asks
  for doesn't load on Bazel 9.
- **rules_swift_package_manager**: the examples' Windows patch.
- **With #39** (Apple targets built on Linux):
  - rules_apple 5.3.1 with seven of rules_applecross's patches, and
    apple_support 2.10.1 with one, which rules_applecross is taking
    upstream;
  - rules_applecross itself at a commit, until it has a release in the
    BCR;
  - hermetic_android_toolchains with
    `hermetic_android_toolchains_linux_any_cpu.patch`.

## Swift, not Python

The tools should be Swift wherever Swift can do the job, with no Python in
the repository: executable targets (`swift_binary`, or a package's `swift
run`), CoreGraphics and ImageIO for images.

- **Run by Bazel** (`py_binary`, on rules_python 2.0.2's hermetic Python
  3.12):
  - swift_ffi's `export_list.py` (a reactor's exports);
  - tools/wasm's `icu_data.py`, `sdk_exports.py` and `serve.py` (the web
    apps' `bazel run`, swift_map's too), and its `site_imports_test.py`;
  - the Playground's `dev_compile_server.py`;
  - the network probe's `network_check.py`.

  With these in Swift, rules_python and its toolchain leave MODULE.bazel.
- **Run by hand or by agents:**
  - the release proof (`tools/proof/proof.py`);
  - the headless Chrome driver (`tools/testing/cdp.py`, and swift_map's
    copy);
  - the parity reports (`tools/parity`);
  - the SwiftUI audit (`tools/swiftui_audit`, nine scripts);
  - `tools/foundation/check_link.py` and `tools/symbols/generate.py`;
  - the version stamps (`examples/tools/stamp_storybook.py`, the
    Playground's `stamp.py` and `template_history.py`);
  - the Playground's e2e runner (`tests/e2e/run.py`);
  - the pixel benchmark.

## No Node

Node never runs in an Isomer app. It is in the build and the tests (rules_nodejs
6.7.5's hermetic Node; never npm), and it can go too:

- **TypeScript.** swift_ffi's `ts_swift_library` compiles the generated web
  bindings with `tsc` 5.8.3, through aspect_rules_ts and aspect_rules_js. If
  swift_ffi generated JavaScript itself (with a `.d.ts` for typed callers),
  `tsc` would go.
- **esbuild** bundles the Metal web tests and swift_ffi's web example, run
  through aspect_rules_esbuild's Node launcher. Serving those as plain ES
  modules, as the web runtime already is, removes it.
- **Tests run in Node:** tests/web_files (`file_system_test`, `blocks_test`),
  tests/web_network (`network_test`) and swift_ffi's web example. They could
  run in headless Chrome, the browser the code is for.
- **Dev tools in Node:** tools/testing's `cdp_shot.js`, `cdp_eval.js`,
  `run_files_check.js`, `run_network_check.js` and `network_server.js`, and
  tools/metal's `run_metal_check.js` and `validate_wgsl.js`. They would be
  Swift, with the Chrome driver (`cdp.py`, above).

With all of them gone, rules_nodejs, aspect_rules_js, aspect_rules_ts and
aspect_rules_esbuild leave MODULE.bazel. Electron's `main.js` runs in
Electron's own Node, part of the Electron app rather than the build.

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
