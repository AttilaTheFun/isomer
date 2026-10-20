# Android example: migrate to `rules_android` + `rules_kotlin` — implementation plan

> Self-contained handoff. Written 2026-06-24 so the conversation can be compacted
> and the work picked up fresh. Everything needed to execute is here.

## Goal & two-phase strategy

We want a **proper, real-world** Android example for the rules_swift Android PR
(#1818) that uses `rules_android` + `rules_kotlin` (what people actually ship
with), instead of the bespoke `android_apk` pipeline isomer uses today.

1. **Phase 1 — prove it on isomer's real app.** Migrate
   `//examples/android/example_application` from the hand-rolled `android_apk`
   to `rules_android` (`android_binary`) + `rules_kotlin` (`kt_android_library`).
   Verify the APK builds **and runs on the emulator** (the full UI renders).
   Do this on a **branch**; `main` stays on the working bespoke pipeline.
2. **Phase 2 — extract a minimal example into rules_swift.** Once phase 1 works,
   branch off the rules_swift `android-support` branch and add a small greeter
   APK example (rules_android + rules_kotlin + dev deps) using the same pattern.
   Show keith the delta on PR #1818; if the dep weight is too much for rules_swift,
   publish it as a standalone example repo instead.

Rationale: keith pushed back (rightly) that the toy `.so`-only example isn't
compelling; a runnable app that shows Swift `Greeter` text on screen is. But a
real APK pulls in `rules_android` + a Maven graph, so we validate on a real app
first and present it as an opt-in delta.

---

## Current state (repos, branches, commits)

- **isomer** (this repo): `main` @ `7e6ff02`. Clean cc-toolchain Android
  wiring; APK built today by the **bespoke** `android_apk` rule. `git_override`s
  rules_swift → `integration-all` (`25ab8ee0`) and uses stock
  `hermetic_android_toolchains` `0.1.1`.
- **rules_swift** (`~/Developer/rules_swift`, origin = `AttilaTheFun`,
  upstream = `bazelbuild`):
  - `android-support` @ `6c1b007b` = **PR #1818**, one clean commit, the
    cc-toolchain design (see next section). Phase 2 branches off this.
  - `integration-all` @ `25ab8ee0` = combined wasm+android clean branch that
    isomer consumes.
  - `wasm-support` (#1817), `windows-support` (#1819).
- **hermetic_android_toolchains** (`~/Developer/hermetic_android_toolchains`,
  origin = `AttilaTheFun`, upstream = `keith`): BCR **0.1.1**. Provides
  `@androidndk` (NDK cc toolchains) and `@androidsdk` (the Android SDK).
  `examples/basic_app` is keith's reference `rules_android` app — **mirror it.**

---

## How Swift→Android works now (the cc-toolchain design) — required background

rules_swift (on `android-support`) does **not** manage the NDK. It ships only the
Swift Android toolchain. C/C++ compilation + linking come from a separately
registered Android cc toolchain (`@androidndk//:all`), and the Swift toolchain
reads that toolchain's sysroot **at analysis time**:
- `swift/toolchains/swift_toolchain.bzl` `_resolve_sdkroot` derives the sysroot
  from `cc_toolchain.all_files` (rules_android_ndk's `CcToolchainInfo.sysroot`
  reports the clang dir, not the sysroot).
- For Android, the swift link adds `--sysroot=<derived>` and stages
  `libc++_shared.so` (selected from `cc_toolchain.all_files`) into the link,
  because the swift link bypasses the cc toolchain's runtime-lib features.
- `swift/toolchains/android_runtime_lib.bzl` exposes `select_android_runtime_lib`
  — a rule that selects `libc++_shared.so` from the resolved cc toolchain for APK
  packaging. Build it under an Android platform.

**Consumer wiring (isomer, already on `main`):**
- `bazel_dep(hermetic_android_toolchains, 0.1.1)`, the `android` extension with
  `android.sdk(version="35", build_tools_version="35.0.0")` +
  `android.ndk(version="r27c", api_level=28)`, `use_repo(android, "androidndk")`,
  `register_toolchains("@androidndk//:all")`.
- The Swift JNI `.so`: `swift_binary(linkshared)` → `transition_binary` to
  `//tools/platforms:android_arm64`. libc++: `select_android_runtime_lib` →
  `transition_binary`. (Both already in the app BUILD; keep them.)

**This part does not change in the migration.** Only the APK *assembly* changes
(bespoke `android_apk` → `android_binary`).

---

## What's being replaced (the bespoke pipeline)

- `tools/android/defs.bzl`: `android_apk` rule (kotlinc → d8 → aapt2 → jar →
  zipalign → apksigner) + `apk_install_run`. Takes `native_libs` (target→abi file
  map — copies `.so` files straight into `lib/<abi>/`), `kotlin_srcs`, `manifest`,
  `assets`.
- `tools/android/extensions.bzl`: `android_tools` extension `http_archive`s
  `hermetic_jdk` (Temurin 21), `kotlin_compiler` (2.1.20), `android_build_tools`
  (r35), `android_platform_jar` (35), `android_platform_tools` (35: adb), plus the
  emulator + system image.
- `tools/android/debug.keystore`.

Keep `tools/android` for the **emulator** (`bazel run //tools/android/emulator`)
and possibly adb; only the APK-assembly rule is superseded. The emulator run
flow is what we'll use to verify e2e.

### The app being migrated
`examples/android/example_application/`:
- `BUILD.bazel` (captured below), `AndroidManifest.xml`, `jni_exports.lds`.
- `kotlin/dev/isomer/example/*.kt` — 9 files: `MainActivity`, `NativeBridge`,
  `CellCanvasRenderer`, `HostViewManager`, `NativeListManager`,
  `NativeScrollManager`, `PressFeedbackView`, `UIRenderer`, `IsomerView`.
  Real Android usage: `GLSurfaceView`, `BitmapFactory`, `HttpURLConnection`,
  kotlin stdlib/coroutines-free threads.
- `NativeBridge` does `System.loadLibrary("exampleapp")`, declares ~15 `external`
  downcalls and ~15 `@JvmStatic` upcalls (called from Swift via cached method IDs).
- Assets: `//examples/shared/example_application:assets`.

Current app BUILD (the `swift_binary`/`transition_binary`/`select_android_runtime_lib`
targets STAY; the `android_apk` + `apk_install_run` get replaced):

```python
swift_binary(name = "exampleapp", srcs = ["//examples/shared/example_application:srcs"],
    copts = ["-enable-experimental-feature", "Extern", "-parse-as-library"],
    linkopts = ["-Xlinker", "--version-script=$(location jni_exports.lds)"],
    additional_linker_inputs = ["jni_exports.lds"], linkshared = True,
    module_name = "ExampleApplication", tags = ["manual"],
    deps = ["//android/libraries/swift_ui", "//android/libraries/swift_ui:isomer_bridge"])
transition_binary(name = "app_so", binary = ":exampleapp", platform = "//tools/platforms:android_arm64")
select_android_runtime_lib(name = "libcxx_shared_lib", tags = ["manual"], triple = "aarch64-linux-android")
transition_binary(name = "libcxx_shared", binary = ":libcxx_shared_lib", platform = "//tools/platforms:android_arm64")
# REPLACE the two below:
android_apk(name = "example_application_apk", assets = ["//examples/shared/example_application:assets"],
    kotlin_srcs = glob(["kotlin/**/*.kt"]), manifest = "AndroidManifest.xml",
    native_libs = {":app_so": "arm64-v8a", ":libcxx_shared": "arm64-v8a"})
apk_install_run(name = "example_application", activity = "dev.isomer.example/.MainActivity", apk = ":example_application_apk")
```

---

## Phase 1 — isomer migration (do on a branch)

```sh
cd ~/Developer/isomer
git checkout -b android-rules-migration
```

### Step 1 — MODULE deps (mirror keith's `basic_app` MODULE.bazel)
Reference: `~/Developer/hermetic_android_toolchains/MODULE.bazel`.
Add:
```python
bazel_dep(name = "rules_android", version = "0.7.3")
bazel_dep(name = "rules_java", version = "9.3.0")
bazel_dep(name = "rules_kotlin", version = "<latest bzlmod-compatible>")  # confirm version
bazel_dep(name = "rules_jvm_external", version = "7.0")

maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "rules_android_maven",
    aar_import_bzl_label = "@rules_android//rules:rules.bzl",
    artifacts = [],
    known_contributing_modules = ["rules_android"],
    lock_file = "//:rules_android_maven_install.json",
    repositories = ["https://maven.google.com", "https://repo1.maven.org/maven2"],
    use_starlark_android_rules = True,
)
use_repo(maven, "rules_android_maven")
```

### Step 2 — Maven pin (generates a checked-in lock file)
```sh
REPIN=1 bazel run @rules_android_maven//:pin
```
Commit `rules_android_maven_install.json`. (This needs network; rules_android
resolves its Maven graph. Known-fiddly under bzlmod — if it fails, compare
versions against keith's working `basic_app`.)

### Step 3 — Point rules_android at the existing `@androidsdk`
We already declare `android.sdk(...)` for `@androidndk`, which creates
`@androidsdk`. Mirror keith's `override_repo` so rules_android uses it:
```python
use_repo(android, "androidndk", "androidsdk")          # add androidsdk
rules_android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension")
override_repo(rules_android_sdk, "androidsdk")
register_toolchains("@androidndk//:all", "@androidsdk//:all")
```
(See keith's MODULE.bazel lines ~43-70 for the exact shape. `override_repo` is
from the bazel `module_ctx`/`use_repo` API — confirm import.)

### Step 4 — rules_kotlin toolchain
Register the rules_kotlin toolchain (e.g. `register_toolchains` for the default
`@rules_kotlin//kotlin/internal:default_toolchain`, or call the
`kt_register_toolchains` analog). Confirm the current rules_kotlin bzlmod setup.

### Step 5 — BUILD migration
Replace `android_apk` + `apk_install_run` with:
```python
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("@rules_android//rules:rules.bzl", "android_binary")
load("@rules_cc//cc:defs.bzl", "cc_import")

# Wrap the Swift JNI .so + libc++ as cc_imports so android_binary packages them
# into lib/<abi>/. (swift_binary(linkshared) exposes its .so via DefaultInfo, not
# CcInfo, so android_binary won't pick it up directly — this is the fiddly bit.)
cc_import(name = "exampleapp_so", shared_library = ":app_so")        # may need a wrapper; see note
cc_import(name = "libcxx_so", shared_library = ":libcxx_shared")

kt_android_library(
    name = "app_lib",
    srcs = glob(["kotlin/**/*.kt"]),
    custom_package = "dev.isomer.example",
    manifest = "AndroidManifest.xml",
    assets = ["//examples/shared/example_application:assets"],
    assets_dir = "...",          # confirm against the assets layout
    deps = [":exampleapp_so", ":libcxx_so"],
)

android_binary(name = "app", manifest = "AndroidManifest.xml", deps = [":app_lib"])
```

**THE BIGGEST UNKNOWN — getting the Swift `.so` into `android_binary`:**
- `swift_binary(linkshared)` provides `DefaultInfo` with the `.so`, **not** a
  `CcInfo` dynamic library, so `android_binary`'s native-lib collection won't see
  it. `cc_import(shared_library = ":app_so")` should wrap it, but `:app_so` is a
  `transition_binary` (built in the android config) — the `cc_import` must resolve
  the `.so` in the right config. If `cc_import` of a transitioned target is awkward,
  fallbacks:
  1. A tiny custom rule that takes the `.so` `File` and returns `CcInfo` with it as
     a `dynamic_library` (via `cc_common.create_library_to_link`).
  2. Use the `.so` `File` directly + rules_android's native-lib attr if one exists
     in 0.7.3 (check `android_binary`'s attrs).
  3. Worst case: keep a `genrule` laying out `jniLibs` and feed it to
     `android_binary` via a supported mechanism.
- `libc++_shared.so`: same treatment. (rules_android_ndk's `dynamic_runtime_lib`
  is empty, so the cc toolchain won't auto-bundle libc++ — must be explicit.)
- Keep `jni_exports.lds` on the `swift_binary` (the `--version-script` that keeps
  the `@_cdecl("Java_…")` symbols in `.dynsym`; without it `System.loadLibrary`
  → `UnsatisfiedLinkError`). It's already wired; don't drop it.

### Step 6 — adb install/run
Replace `apk_install_run` with rules_android's `mobile-install`, **or** keep a
thin custom `sh_binary` adb wrapper (isomer's `apk_install_run` uses
`@android_platform_tools//:adb`) pointed at the new `:app` APK output
(`bazel-bin/.../app.apk` or the `android_binary` `apk` output group).

### Step 7 — Validate e2e
```sh
bazel build //examples/android/example_application:app          # APK builds
bazel run //tools/android/emulator                                 # boot emulator (existing)
# install + launch, confirm the UI renders (the Pokédex/Apps list etc.)
```
The emulator flow already exists in `tools/android/`. Success = the real UI
renders, same as `main`'s bespoke build does today.

### Phase 1 fiddly bits (expect iteration)
1. Maven pin under bzlmod.
2. rules_android + `@androidsdk` (`override_repo`) wiring.
3. **Swift `.so` → `android_binary`** (the cc_import/config issue above) — most
   likely to need a custom CcInfo-wrapping rule.
4. rules_kotlin compiling the 9 Kotlin files (android framework + stdlib).
5. Assets handling via `kt_android_library`/`android_binary` (the app reads
   bundled assets at runtime — must end up in the APK's `assets/`).

---

## Phase 2 — rules_swift example branch (off `android-support`)

```sh
cd ~/Developer/rules_swift
git checkout android-support           # @ 6c1b007b (or latest)
git checkout -b android-example-app
```

The greeter example already exists at `examples/cross_compilation/` and
`examples/cross_compilation/android_app/`:
- `Sources/Greeter/Greeter.swift`, `Sources/SwiftJNI/SwiftJNI.swift`
  (`@_cdecl("Java_com_example_swiftjni_NativeBridge_greetingFromSwift")`).
- `android_app/java/com/example/swiftjni/{MainActivity,NativeBridge}.kt`
  (MainActivity sets `NativeBridge.greetingFromSwift()` into a `TextView`),
  `AndroidManifest.xml`.
- `BUILD.bazel` builds `:libSwiftJNI.so` via the platform transition.

Add (mirroring whatever worked in phase 1, minimal):
1. A real `android_binary` + `kt_android_library` for the greeter app
   (`MainActivity` + `NativeBridge`), packaging `libSwiftJNI.so` +
   `libc++_shared.so` (`select_android_runtime_lib`).
2. Dev MODULE deps in rules_swift: `rules_android`, `rules_kotlin`, `rules_java`,
   `rules_jvm_external` + the Maven pin + `@androidsdk` wiring (all
   `dev_dependency = True`; `@androidsdk` already partly wired since we declare
   `android.sdk` for `@androidndk`).
3. A `build_test` so CI builds the APK.
4. Update `examples/cross_compilation/README.md` + `android_app/README.md` to
   point at the real target (drop the "documented recipe" framing).

**Decision to surface to keith** (he's reviewing #1818): a runnable APK example
adds `rules_android` + a Maven lock file to rules_swift's dev deps/CI. Present it
as a **separate commit / opt-in delta** so he can take it or leave it. If too
heavy for rules_swift, publish as a standalone `rules_swift_android_example` repo.

---

## Gotchas learned this session (don't rediscover)

- `swift_binary(linkshared)` → `.so` via `DefaultInfo`, **not** `CcInfo`. Wrap for
  `android_binary`.
- rules_android_ndk's `dynamic_runtime_lib_<target>` is **empty**, so the cc
  toolchain never bundles `libc++_shared.so`; it must be packaged explicitly
  (that's what `select_android_runtime_lib` is for).
- JNI symbols: the static Swift runtime links with `-Wl,--exclude-libs,ALL`, which
  demotes `@_cdecl` exports to local → `UnsatisfiedLinkError`. The
  `jni_exports.lds` version script (`global:` list) restores them. Keep it.
- The android target is `//tools/platforms:android_arm64` (arm64-v8a). The
  emulator image is arm64 (AOSP default, GPU-enabled).
- rules_swift PR #1818 = `android-support`; its CI Test job is green (the only
  red was a transient swift.org download timeout). Don't confuse with the
  bzl_library `find_cc_toolchain_bzl` fix (already in).

## Phase 1 results — DONE (what actually worked)

Branch `android-rules-migration`, commit `00bc9d4`. The APK builds and the full
UI renders on the emulator, parity with `main`. Resolved every fiddly bit:

- **Versions:** rules_android `0.7.3`, rules_java `9.3.0`, rules_kotlin `2.2.2`
  (the graph forces 2.2.2; its `kt_android_library` is a real rule on
  rules_android's `android_library`), rules_jvm_external `7.0`.
- **Maven pin:** needed a root `//BUILD.bazel` (so the `//:..._install.json`
  label is a package) and a valid seed lock (copied keith's, then
  `REPIN=1 bazel run @rules_android_maven//:pin`). The maven.google.com 404
  warnings during fetch are harmless (artifacts resolve from repo1).
- **`@androidsdk`:** `use_repo(android, "androidndk", "androidsdk")` +
  `override_repo(rules_android_sdk, "androidsdk")` +
  `register_toolchains("@androidsdk//:all")`.
- **`.bazelrc`:** `--android_platforms=@rules_android//:arm64-v8a` (drives the
  per-ABI native split; the lib dir is named after the platform, so use the
  ABI-named `@rules_android//:arm64-v8a`, whose `cpu:arm64` is an alias of
  `aarch64` — matches `//tools/platforms:android_arm64`) and
  `--java_runtime_version=remotejdk_17` (+ tool/language variants) so
  rules_android's Java actions use a hermetic JDK, not `local_jdk`.
- **The Swift `.so` → `android_binary` (the big unknown):** solved cleanly with
  `cc_library(srcs = [":app_so"])` — a prebuilt `.so` in a cc_library's srcs
  becomes a `CcInfo` dynamic library, which `android_binary`'s native split
  collects (cc_import is **not** in `android_binary.deps`' allow_rules;
  cc_library is). Same for libc++ via `cc_library(srcs = [":libcxx_shared"])`.
  The cc_libraries go **directly in `android_binary.deps`** (not buried in the
  kt_android_library) so the split sees their `CcInfo`. The transitions keep
  the `.so` arm64 regardless of the split's config.
- **Assets:** the app opens images by flat basename, but the source PNGs are a
  nested xcassets tree. New `flat_assets` rule (in `tools/android/defs.bzl`)
  emits a `flat_assets/` TreeArtifact of flat-named copies; `kt_android_library`
  takes `assets=[":flat_assets"], assets_dir="flat_assets"` (rules_android's
  busybox handles a directory asset whose path ends with the assets_dir).
- **Run target:** `android_binary`'s default output is multi-file, so reference
  the implicit `:example_application_apk.apk` for `rlocationpath` consumers
  (`apk_install_run`, `run_all`).
- **Emulator note:** rules_android signs with its own debug key, which differs
  from the bespoke `tools/android/debug.keystore` — `adb uninstall` any
  previously-installed (bespoke-signed) copy first (INSTALL_FAILED_UPDATE_INCOMPATIBLE).
- Verified: `lib/arm64-v8a/{libexampleapp.so,libc++_shared.so}`, 15 JNI
  `Java_dev_isomer_example_NativeBridge_*` exports in `.dynsym`, flat
  `assets/*.png`, merged manifest (package + `MainActivity`), UI renders.

## Phase 2 results — DONE

rules_swift branch `android-example-app` (off `android-support` `6c1b007b`), one
clean delta commit `86683826`. The greeter example now builds a **real, runnable
APK** instead of a documented recipe, and it runs on the emulator showing
"Hello from Swift, Android!".

- `examples/cross_compilation/android_app/BUILD.bazel` (new): `android_binary` +
  `kt_android_library` + the two `cc_library` `.so` wrappers +
  `select_android_runtime_lib`/`transition_binary` for libc++ + a `build_test`.
  Everything tagged `manual` (excluded from the `//examples/...` wildcard).
- MODULE.bazel: `rules_android`/`rules_java`/`rules_kotlin`/`rules_jvm_external`
  all `dev_dependency = True`; Maven pinned to `//:rules_android_maven_install.json`;
  `@androidsdk` wired via `override_repo`. protobuf stays at 34 (no conflict).
- `.bazelrc`: a scoped `--config=android_example` (arm64 `--android_platforms` +
  hermetic remote JDK) so the rest of rules_swift's build is untouched.
- CI: the `macos_cross_compilation` task gains `--config=android_example` and the
  `app_build_test` target.
- READMEs rewritten to point at the runnable target (dropped the recipe framing).
- Note: the greeter's `@_cdecl` lives in the `swift_binary`'s own source, so its
  JNI symbol stays exported without a version-script (unlike isomer, whose
  JNI entry points come from a static-archive dep — hence its `jni_exports.lds`).

The delta is self-contained and reviewable as a single commit to show keith.

## Validation checklist
- [x] Phase 1: `bazel build //examples/android/example_application:example_application_apk`
- [x] Phase 1: APK installs + the full UI renders on the emulator (parity with `main`)
- [x] Phase 1: commit on `android-rules-migration`, leave `main` untouched
- [x] Phase 2: rules_swift example `android_binary` builds + `build_test` passes
- [x] Phase 2: greeter APK shows "Hello from Swift, Android!" on screen
- [x] A note to rules_swift's maintainers about the example and the added dev deps
