# Toolchain pins and build gotchas

Why each pin in `MODULE.bazel` is what it is, and the build-system failure
modes that cost real debugging time. The comments in `MODULE.bazel` and
`.bazelrc` are the authoritative, always-current rationale — this doc is the
narrative index over them. If they disagree, trust the files and update this
doc.

## Pins and why

- **Bazel 9.1.1** (`.bazelversion`) — rules_swift main uses `include()`,
  which breaks Bazel 8 consumers.
- **rules_swift 3.6.1 + `git_override`** — all of the Swift-SDK
  cross-compilation work is merged upstream (#1817 wasm, #1818 Android,
  #1819 Windows, #1820 linkshared, #1821 SDK framework, #1859 Android
  API-level triple). The override currently points at the branch for
  [bazelbuild/rules_swift#1860](https://github.com/bazelbuild/rules_swift/pull/1860)
  (metadata-driven wasm SDK + the wasip1-threads variant); switch it back to
  bazelbuild main when #1860 merges, and drop the override entirely at the
  next rules_swift release.
- **`apple_support` before `rules_cc`** in `MODULE.bazel` — ordering gives
  apple_support's cc toolchain resolution priority over rules_cc's
  `local_config_cc` darwin toolchain, which lacks `CC_TARGET_TRIPLE` and
  breaks the Xcode Swift toolchain ("Invalid target triple: local").
- **swift-syntax 603.0.2** (BCR) — matches the swift.org 6.3.2 frontend's
  compiler-plugin protocol (602 had plugin-protocol issues).
  swift_argument_parser 1.7.0 for the analyzer/generator CLIs.
- **Android**: hermetic_android_toolchains 0.1.1 (NDK r27c, API 28 →
  `@androidndk`; SDK 35 → `@androidsdk`), rules_android 0.7.3,
  rules_kotlin 2.2.2, rules_jvm_external 7.0. The Swift Android toolchain
  links through `@androidndk//:all` with libc++ static, so an APK ships only
  the bridge `.so`. The maven lock file is checked in; update with
  `REPIN=1 bazel run @rules_android_maven//:pin`.
- **TypeScript**: the aspect stack — aspect_rules_js (`js_test` on the
  hermetic rules_nodejs toolchain), aspect_rules_ts (`ts_project`, tsc's version
  written in MODULE.bazel for the rules_ts extension), aspect_rules_esbuild
  (bundling, own esbuild toolchain). There are no npm packages: the isomer
  module must not use rules_js's `npm` extension (flatbuffers hands it a tag
  rules_js 3 rejects), so the web example declares the Node APIs it uses in
  `node.d.ts`.
- **WasmKit** (MODULE.bazel's `wasmkit`, the AttilaTheFun/WasmKit fork,
  built by `tools/wasmkit/BUILD.wasmkit.bazel`) is the engine Isomer's native
  hosts and `//tools/wasm/wasi_run` run reactors and WASI commands on. WAMR,
  vendored as `@wamr` with wamrc built against the BCR `llvm` module until
  0.38, is gone, and the `llvm` dependency with it.
- The hermetic Android emulator image and Electron are declared at the bottom
  of `MODULE.bazel`.

Everything is hermetic except Apple's local Xcode: no host JDK, Node, or
`ANDROID_HOME` is consulted.

## Gotchas

- **`--strategy=SwiftCompile=local`** (`.bazelrc`) is required, not an
  optimization. The macro plugin is built by the Xcode toolchain but loaded
  by the swift.org cross-compile frontend; inside a sandbox it can't reach
  its runtime dylibs and macro expansion fails with
  "produced malformed response".
- **`ts_project` invoked from a consumer repo** (i.e. by our
  `ts_swift_library` macro running in *their* workspace):
  1. The `tsconfig` must be the **inline dict** in `swift_ffi.bzl` — a shared
     tsconfig *file* moves tsc's project root to that file's directory and it
     finds "No inputs". The dict needs `"lib": [..., "esnext.disposable"]` or
     `Symbol.dispose` fails as TS2550.
  2. `tsc` / `tsc_worker` / `validator` must be passed as
     `Label("@npm_typescript//:…")` so they resolve in *swift_ffi's* repo
     mapping — `ts_project`'s string defaults resolve in the caller's repo
     and fail with "@@npm_typescript not found". This is also why
     aspect_rules_ts/js, rules_nodejs, rules_kotlin, and the rules_ts
     extension are **non-dev** dependencies.
- **ESM under `nodenext`**: consumer `.ts` imports the generated module as
  `./greeter_web.js` (compiled-neighbor convention). The package's
  `package.json` (`"type": "module"`) must be in `ts_project.srcs` — or tsc
  classifies the files as CJS and rejects top-level `await` — and in
  `js_test.data`, or Node does the same at runtime.
- **The TS runtime is staged with `genrule cp -L`**, not skylib `copy_file`:
  copy_file emits symlinks, which aspect esbuild's sandbox plugin rejects.
  Pass `runtime = False` to `ts_swift_library` for a second bridge in the
  same package.
- **Stale outputs**: resolve output paths with
  `bazel cquery --output=files <target>`, never `find -L bazel-bin` —
  old-configuration outputs linger and will mislead you.
- **Emulator cold boot** can drop the first `adb install` ("Broken pipe")
  even after boot checks; see [examples.md](examples.md).
