# Platform modules: an app pays for the platforms it builds

The goal (2026-11-18): an app on Isomer should pay only for the
dependencies of the platforms it builds, beside rules_swift and
rules_swift_package_manager, which every Isomer app needs (it is all
Swift). This is the audit of what isomer's module asks of its consumers,
platform by platform, the layout that follows from it, and what 0.58 does
of it: the Apple half is the `isomer_apple` module (0.58), Android's the
`isomer_android` module (0.59).

## What a consumer pays for

Bazel charges a consumer for a module's dependencies in four ways, of very
different weight:

1. **Its module graph.** Every non-dev `bazel_dep` of every module in the
   graph is resolved (each MODULE.bazel fetched from its registry), and
   Minimal Version Selection gives the whole build the highest version any
   module asks for: a dependency raises the consumer's own choice, and
   brings its own dependencies along. This is what the goal is about.
2. **Registered toolchains.** A non-dev `register_toolchains` in any module
   is in every build's toolchain resolution: its package is loaded, and a
   toolchain it selects is fetched.
3. **Module extensions and repository rules.** Evaluated only when one of
   their repositories is needed: isomer's `http_archive`s (WasmKit,
   Binaryen, WABT's sources, Chrome for Testing, WasmEdge) and extensions
   (Electron, Android's emulator and tools) cost nothing in a build that
   doesn't use them.
4. **Loads.** A `load()` of a repository the loading module can't see fails
   when its file is loaded, used or not; a BUILD file that isn't loaded
   costs nothing. `@isomer//:swift_ui` and its siblings select a platform's
   package, so a build loads that platform's BUILD files alone.

So what matters is the first two: isomer's non-dev `bazel_dep`s, and the
graph each brings. isomer registers no toolchain for its consumers (every
`register_toolchains` in its MODULE.bazel is dev-only: README, "Consuming
isomer"), and none of its overrides reach a consumer (overrides are the
root's alone).

## The audit (isomer 0.57's MODULE.bazel)

Every non-dev directive, by the platform that needs it.

| Directive | Platforms | Why |
| --- | --- | --- |
| `bazel_skylib` 1.9.0, `platforms` 1.1.0 | core | every rule file |
| `rules_swift` 4.3.0.isomer.2 | core | Swift everywhere (also brings apple_support 2.9.1, protobuf 34) |
| `rules_swift_package_manager` 1.26.0, its `swift_deps` (`configure_package`, `use_repo`) | core | Isomer's Swift package (also brings rules_apple 4.3.3, apple_support 1.24.2) |
| `swift_argument_parser` 1.7.0 | core | the bridge generator and analyzer (swift_ffi) |
| `protobuf` 27.0 | core | the wire protos (shared/wire); rules_swift asks for 34 anyway |
| `rules_cc` 0.2.18 | core | C in swift_ffi, the web's and Linux's and Windows' libraries |
| `rules_shell` 0.8.0 | core, Android | the web's server and checks, `apk_install_run` |
| **`rules_apple` 5.3.1.applecross.6** | **Apple** | isomer_application's `ios_application`/`macos_application`, swift_map's Apple example apps and XCFramework (the only loads of it) |
| **`apple_support` 2.11.0** | **Apple** (and a Mac host) | nothing loads it; rules_applecross asks for 2.11.0. Declared before rules_cc so its C toolchain ranks above rules_cc's on a Mac, which any build on a Mac needs (the build's own Swift tools) |
| `hermetic_android_toolchains` 0.5.0.isomer.1 | Android | only to raise every consumer to the patched version (MVS): its extension is the root's |
| `rules_android` 0.7.3, `rules_java` 9.3.0, `rules_kotlin` 2.2.2 | Android | `isomer_android_app` and the rest of tools/android, android/libraries, swift_ffi's `kt_swift_library` (rules_kotlin) |
| `rules_java`'s `toolchains` extension (`remote_java_tools`) | Android | rules_android's Java actions |
| `//android/maven:extensions.bzl` (`isomer_android_maven_set`) | Android | Isomer's AndroidX or the app's (docs/android_maven.md) |
| `//tools/android:extensions.bzl` (build tools, emulator, platform jar and tools, system image, JDK, kotlinc) | Android (and tests), the web's Electron packaging (the JDK) | the emulator runner, the Level 4 templates' tools; lazy |
| `wabt` 1.0.37 | wasm hosting | mixed mode's wasm2c and wat2wasm, built from source (tools/wasm/mixed.bzl) |
| `binaryen_*`, `wabt_sources` (`http_archive`) | wasm hosting | mixed mode; lazy |
| `wasmkit` (`http_archive`) | every native host that runs reactors (Apple, Android, Linux, Windows) | `WasmKitRuntime`; lazy |
| `//tools/wasm:extensions.bzl` (Electron) | web (Electron) | lazy |
| `chrome_linux_*` (`http_archive`) | tests | //tools/wasm/wasi_run_browser; lazy |
| `wasmedge_static` (`http_archive`) | tests (an experiment) | //shared/wasm_host:wasmedge_runtime; lazy |
| `register_toolchains`, overrides | none | all dev-only, or the root's alone |

android/maven_module (isomer_android_maven) is Android's alone: isomer,
rules_android 0.7.3, rules_jvm_external 7.1 and its `maven` extension.

### What the consumer entry points load

The repositories each one's `load()` closure names (a repository missing
from the build fails the load, whatever is used):

| Entry point | Loads |
| --- | --- |
| `@isomer//tools/android:defs.bzl` (`isomer_android_app`, `isomer_android_library`, `isomer_android_webview_app`, `apk_install_run`) | bazel_skylib, rules_android, rules_cc, rules_java, rules_kotlin, rules_shell, rules_swift |
| `@isomer//tools/wasm:defs.bzl` (`isomer_web_app`, `wasm_sdk_bundle`, …) | bazel_skylib, rules_cc, rules_shell, rules_swift |
| `@isomer//tools/wasm:mixed.bzl`, `:side_modules.bzl` | rules_cc (rules_swift) |
| `@isomer//tools/application:defs.bzl` | 0.57: the Android set and **rules_apple**; 0.58: the Android set alone; 0.59: the web's (bazel_skylib, rules_cc, rules_shell, rules_swift) |
| `@isomer_apple//:defs.bzl` (0.58) | 0.58: the Android set and rules_apple; 0.59: rules_apple and the web's |
| `@isomer_android//:defs.bzl` (0.59) | the Android set and the web's |
| `@isomer//swift_ffi/rules:kt_swift_library.bzl` | rules_cc, rules_kotlin, rules_swift |
| `@isomer//swift_ffi/rules:rs_swift_library.bzl` | rules_rust (the app's own: not a dependency of isomer) |
| the other swift_ffi rules (`js_swift_wasm_library`, `swift_wasm_reactor`, `cc_swift_library`, …) | rules_cc, rules_swift |
| `@isomer//apple/compiled:defs.bzl`, `@isomer//foundation:defs.bzl` | rules_cc, rules_swift |
| `@isomer//tools/platforms` (platforms, transition) | platforms |
| `@isomer//tools/windows:defs.bzl` (the Windows SDK repository rule) | nothing |

| Labels (BUILD packages, loaded when built) | Loads |
| --- | --- |
| `@isomer//:swift_ui`, `:isomer`, `:foundation` and the like | the platform's package alone, by `select` |
| Android's (android/libraries/…) | rules_android, rules_kotlin, rules_cc, rules_swift |
| the web's, Linux's, Windows', headless, Apple's libraries (apple/libraries/…) | rules_cc, rules_swift (bazel_skylib) |
| swift_map's | per platform, as above; its Apple example apps and XCFramework loaded rules_apple (examples' since 0.58) |

Nothing in isomer loads apple_support or rules_applecross.

### Measured: what a consumer resolves

`bazel mod graph` of two fixtures, an app on Android alone (isomer,
isomer_android_maven, rules_swift, rules_swift_package_manager, the NDK and
SDK) and an app on the web alone (isomer, rules_swift,
rules_swift_package_manager), against each layout:

| isomer | Modules (either app) | What changed |
| --- | --- | --- |
| 0.57 | 53 | rules_apple 5.3.1.applecross.6, apple_support 2.11.0, rules_applecross, llvm, xctestrunner, libxml2, mimalloc, windows_support, zlib-ng, zstd; rules_go 0.62, gazelle 0.51, rules_cc 0.2.26 |
| 0.58 (isomer_apple) | 45 | rules_apple 4.3.3 and apple_support 2.9.1 (rules_swift_package_manager's and rules_swift's), no rules_applecross graph; rules_go 0.60, gazelle 0.50, rules_cc 0.2.25 |
| 0.59 (isomer_android) | 39 (the web app) | hermetic_android_toolchains, rules_android_ndk, rules_robolectric, abseil-py, bazel_worker_api, bazel_worker_java gone; rules_android 0.7.3 → 0.1.1, rules_kotlin 2.2.2 → 1.9.6, rules_java 9.3.0 → 9.1.0, rules_jvm_external 6.9 → 6.7 (measured on the web app's fixture: six fewer modules than 0.58's, as projected) |
| and without `wabt` (an isomer_web) | 38 | wabt |

The floor, what rules_swift and rules_swift_package_manager bring by
themselves, is most of the rest: rules_apple 4.3.3, apple_support,
rules_android 0.1.1, rules_kotlin 1.9.6, rules_java, rules_jvm_external,
rules_go, gazelle, rules_python, protobuf 34, abseil-cpp. rules_android and
rules_kotlin come with protobuf's and rules_swift_package_manager's graphs
whatever isomer does: what isomer adds for Android is the versions, and
the NDK's modules.

## The layout

| Module | Directory | Carries | Status |
| --- | --- | --- | --- |
| `isomer` | `.` | the Swift package, the platforms' Swift libraries, swift_ffi, the web's rules; bazel_skylib, platforms, rules_swift, rules_swift_package_manager, rules_cc, rules_shell, protobuf, swift_argument_parser, apple_support at rules_swift's version | (core) |
| `isomer_apple` | `apple/module` | rules_apple 5.3.1.applecross.6, rules_applecross, apple_support 2.11.0, isomer_application with the iPhone's and the Mac's apps | 0.58 |
| `isomer_android` | `android/module` | rules_android 0.7.3, rules_java 9.3.0, rules_kotlin 2.2.2, hermetic_android_toolchains 0.5.0.isomer.2; Android's macros and rules (tools/android's defs.bzl), `kt_swift_library`, swift_ffi's Kotlin runtime, the Kotlin targets of android/libraries; `ANDROID` for isomer_application. isomer_android_maven stays beside it | 0.59 |
| `isomer_web` | — | not worth a module: wabt alone (above); mixed mode's tools could be prebuilt `http_archive`s instead (lazy), Binaryen's are already | not proposed |
| `isomer_linux`, `isomer_windows` | — | nothing to carry: their libraries need rules_cc and rules_swift alone, the Windows SDK is a repository rule | not proposed |

Each is released with isomer, at isomer's version, from isomer's tag,
as isomer_android_maven is:

- the module's MODULE.bazel says isomer's committed version (MAJOR.MINOR.0)
  and depends on isomer at it; tools/released_pins.sh (CI's `pins`) checks
  both, for every such module;
- isomer's own builds take it by `local_path_override` (a dev dependency),
  the examples by `local_path_override` too (`../apple/module`), and its
  directory is in .bazelignore;
- the project registry adds it with each release: its tools/add_releases.py
  follows a module released from a directory of isomer's (`WITHIN`:
  `"isomer_apple": ("apple/module", "0.58")`, and `FOLLOWED`) with an empty
  modules/isomer_apple/metadata.json to start from, and add_version.py
  `--stamped --path` sets the entry's module() and its isomer dependency to
  the tag's version. That is a change to the registry made once, as
  isomer_android_maven's was (bazel_registry#57).

### Sizes and what breaks

- **isomer_apple (0.58).** Small: a MODULE.bazel, isomer_application's Apple
  half (260 lines of Starlark, the macro's half that was in
  tools/application/defs.bzl, and its two Swift shell templates), and
  swift_map's two Apple example apps and its XCFramework moved to the
  examples' module (`//swift_map/...` there). For a consumer:
  - an app that loads `isomer_application` and builds the iPhone's or the
    Mac's apps adds `bazel_dep(name = "isomer_apple", version = …)` at
    isomer's version and loads it from `@isomer_apple//:defs.bzl`; the same
    arguments, the same targets. isomer's own `isomer_application` refuses
    `ios` and `macos`, saying so, and builds Android and the web by default;
  - an app that loads rules_apple itself (its own `ios_application`)
    already depends on rules_apple, apple_support and rules_applecross and
    registers the bundling toolchains (README, "Upgrading isomer", 0.40):
    nothing changes, and it needs no isomer_apple;
  - an app that relied on isomer for rules_apple 5.3.1.applecross.6 or
    apple_support 2.11.0 without asking for them gets rules_apple 4.3.3 and
    apple_support 2.9.1: it asks for them itself, or depends on
    isomer_apple;
  - `//swift_map/apple/applications/…` and `//swift_map/apple/xcframework`
    are the examples' `//swift_map/…`.
- **isomer_android (0.59).** Smaller than first sized: Android's Swift
  libraries need only rules_cc and rules_swift, so they stay, and only what
  loads rules_android, rules_kotlin or rules_java moved (below). For a
  consumer: every Android app adds the module and changes the loads of
  `@isomer//tools/android:defs.bzl` and
  `@isomer//swift_ffi/rules:kt_swift_library.bzl`, and the five labels that
  moved; `@isomer//:swift_ui`, the flags and every other label stay as they
  are. Saves a web or Apple app the raise of rules_android, rules_kotlin and
  rules_java, and hermetic_android_toolchains' graph.
- **isomer_web, isomer_linux, isomer_windows**: not proposed (above).

### Hard parts

- **One label, every platform.** `@isomer//:swift_ui` (and `:isomer`,
  `:foundation`, `//android/maven:androidx`) select each platform's package
  inside isomer. A package that moves to a platform module can't be named
  from isomer, which doesn't depend on it. The way through, where it is
  needed, is the one isomer_android_maven took: isomer's `select` points at
  a repository an extension of isomer's makes, which the platform module
  fills by a tag carrying its own labels, and which, without the module,
  holds targets that fail saying to add it. Neither platform module needed
  it: Apple's libraries (apple/libraries) are plain Swift, and Android's
  Swift libraries load rules_cc and rules_swift alone, so both stay in
  isomer; only the targets that load rules_apple, rules_android or
  rules_kotlin moved, and nothing in isomer names them.
- **Rule files that load several platforms' rules.** isomer_application
  loaded every platform's macros. In 0.58 the Apple half was isomer_apple's
  macro, calling isomer's for Android and the web; with a second platform
  module that stops composing (an app with Apple and Android would need a
  macro in a module depending on both). So since 0.59 isomer_application
  takes the platforms' halves as values, each module exporting its own
  (isomer_android, below), and no file loads another platform's rules.
- **Toolchain ranking on a Mac.** apple_support's C toolchain must rank
  above rules_cc's local darwin one for the build's own Swift tools on a
  Mac, and toolchains rank in breadth-first order of the module graph:
  isomer keeps apple_support declared before rules_cc, at rules_swift's
  version (2.9.1), so nothing is raised; isomer_apple asks for 2.11.0.
- **rules_swift's `swift` extension** is the root's alone (it takes its tags
  from the last module that uses it), so no platform module can register a
  platform's Swift SDK or toolchains for an app: each app keeps declaring
  them (examples/MODULE.bazel), as it does now. The same goes for
  hermetic_android_toolchains' extension and rules_applecross's bundling
  toolchains (an Apple root registers them: README, "Upgrading isomer",
  0.40).
- **The examples module** consumes every platform: it depends on each
  platform module by `local_path_override`, and is the test that each
  works from outside isomer.
- **isomer_application's web app** is declared whatever `platforms` says
  (the web-view apps bundle its site), and not `manual`: a wildcard build of
  an Android-only app's package builds it too, which needs a wasm SDK
  registered. Build the app's targets by name, or give `isomer_web_app` a
  `tags` to pass `manual` through (a follow-up).

## isomer_apple (0.58)

- apple/module: MODULE.bazel (isomer_apple at isomer's version; apple_support
  2.11.0 before the rest, rules_apple 5.3.1.applecross.6 as
  `build_bazel_rules_apple`, rules_applecross 0.0.3.382f8c3, bazel_skylib,
  rules_swift, isomer), defs.bzl (`isomer_application`), and the web-view
  and remote shells' templates.
- isomer: rules_apple is a dev dependency (swift_ffi's iOS example);
  apple_support is declared at 2.9.1, before rules_cc (above);
  tools/application/defs.bzl is Android's and the web's, and refuses `ios`
  and `macos`, naming isomer_apple.
- examples: `bazel_dep(name = "isomer_apple")` by `local_path_override`; the
  selection probe loads isomer_application from isomer_apple; swift_map's
  Apple apps and XCFramework under `//swift_map/…`.
- Checked in leases: an app on Android alone (the fixture above) resolves
  45 modules, with rules_apple 4.3.3 and no rules_applecross, and builds
  its APKs from isomer's isomer_application; the examples build their
  Apple apps as before (CI's container and container-apple).

## isomer_android (0.59)

What loads rules_android, rules_kotlin or rules_java moved; what loads
rules_cc and rules_swift alone stayed. So Android's Swift libraries
(`@isomer//:swift_ui` on Android, the host, the GPU renderer, WasmView's
engine) are still isomer's, and `@isomer//:swift_ui`'s `select` points at
the same packages: no repository filled by a tag (isomer_android_maven's
way) is needed. Sources the Swift package reads, and the Kotlin sources,
stay where they were.

- android/module (`isomer_android`, at isomer's version):
  - MODULE.bazel: rules_android 0.7.3, rules_java 9.3.0, rules_kotlin
    2.2.2, hermetic_android_toolchains 0.5.0.isomer.2 (to raise an Android
    app to the patched version, as isomer did), bazel_skylib, platforms,
    rules_cc, rules_shell, rules_swift, isomer; isomer's
    `//tools/android:extensions.bzl` (the hand-built APK's and the
    emulator's tools, lazy);
  - defs.bzl: what tools/android/defs.bzl was (`isomer_android_app`,
    `isomer_android_library`, `isomer_android_webview_app`,
    `isomer_android_aar`, `isomer_android_shared_library`,
    `isomer_wasm_android_library`, `apk_install_run`, `flat_assets`,
    `android_apk`), and `ANDROID`, isomer_application's Android half;
  - swift_ffi: `kt_swift_library.bzl` (was swift_ffi/rules') and `:kotlin`,
    swift_ffi's Kotlin runtime over isomer's swift_ffi/runtime/kotlin
    sources;
  - swift_ui: `:compose_compiler_plugin` and `:isomer_platform` (the shared
    platform library), from android/libraries/swift_ui;
  - wasm_view: `:wasm_engine_bindings` and `:engine_native`, from
    android/libraries/wasm_view.
- isomer: rules_android, rules_java, rules_kotlin and
  hermetic_android_toolchains are development dependencies. The
  `android_tools` extension stays isomer's (plain http_archives, lazy: the
  web's Electron packaging runs its JDK); isomer_android a development dependency by
  `local_path_override`, android/module in .bazelignore. The templates, the
  debug keystore, the AAR's assembly, the emulator runner and the flags
  (`--@isomer//tools/android:shared_platform`, `:aar_libcxx_shared`) stay
  in tools/android: they load nothing of Android's. tools/android/defs.bzl
  and swift_ffi/rules/kt_swift_library.bzl stay as stubs whose macros fail,
  naming the new load.
- isomer_application is isomer's again, and takes its platforms as values
  (the doc's earlier proposal): `WEB` (isomer's), `IOS` and `MACOS`
  (isomer_apple's), `ANDROID` (isomer_android's). A value is a struct of
  `name`, `module`, `attrs` (its own arguments, with defaults) and
  `declare(app, platforms, **attrs)`; isomer_application declares the web's
  apps and `<name>_server`, then calls each module's `declare` once with
  the common arguments and the names asked for. So no file loads another
  platform's rules, and an app with every platform has three load lines.
  isomer_apple's `isomer_application` (0.58) fails, naming the new form.
- The examples depend on isomer_android by `local_path_override`; isomer's
  own Android examples (swift_ffi's, swift_map's) load
  `@isomer_android//swift_ffi:kt_swift_library.bzl` through its development
  dependency. tests/sdk_consumer's `cell.bzl` (tools/ci/sdk_smoke writes
  it) loads kt_swift_library from where the cell's isomer has it, and
  `cell.MODULE.bazel` adds isomer_android for 0.59 on.
- tools/released_pins.sh checks android/module's version and isomer
  dependency with the others'.
- The project registry adds isomer_android with each release, as
  isomer_apple's (a `WITHIN` entry, `"isomer_android": ("android/module",
  "0.59")`, and `FOLLOWED`, in its tools/add_releases.py).
