# AGENTS.md — swift_map

> **Part of the isomer repository since 2026-10-02.** This was a repository
> and Bazel module of its own; it is now the `swift_map/` directory of the one
> `isomer` module. Labels are `//swift_map/...` from the repository root
> (`@isomer//swift_map/...` from another module), dependencies and toolchains are in
> the root `MODULE.bazel`/`.bazelrc`, and a consumer pins isomer, not this.
> Where the text below says "this repo", read "this directory"; the layering
> rule is unchanged (this directory depends on `//swift_gpu` and `//swift_ffi` only, never on the SwiftUI libraries).

Context for AI agents (and new humans) working in this repo. Last updated
2026-07-06. If something here contradicts the code, trust the code and
update this file.

## What this repo is

**SwiftMap**: an open-source Swift map renderer for OpenStreetMap raster
tiles. One Foundation-free Swift core (`//swift_map/core`) — tile math,
camera, gestures, fetch/cache policy, frame building — compiled per
platform, with thin GPU renderers and IO hosts on top: Metal (iOS/macOS,
direct Swift), WebGPU (wasm via swift_ffi + JS), OpenGL ES (Android via
swift_ffi + Kotlin JNI), Direct3D 11 (Windows) and desktop GL 3.3 (Linux)
via swift_gpu's native backends — `{windows,linux}/libraries/swift_map`
build the platform `SwiftMap` modules; their example apps (pure-Swift
WinSDK window / SDL2 C host, URLSession fetch, stb decode) run natively:
`bazel run //swift_map/windows/applications/example_directx_windows_application`
(Windows host) / `//swift_map/linux/applications/example_opengl_linux_application`
(Linux host; the sh wrapper sets the Swift runtime path).
docs/architecture.md is the design document; the README covers running
the examples.

## The ecosystem

```
rules_swift  <  swift_ffi  <  swift_gpu  <  swift_map  <  isomer
```

- **rules_swift**: pinned via `git_override` to upstream bazelbuild main
  (`c6cad940…`) — this project's cross-compile PRs are all merged. **Standing
  action: when the next rules_swift release is tagged, replace the
  git_override with a plain `bazel_dep` version** (same swap in swift_ffi
  and isomer).
- **swift_gpu** (`//swift_gpu`): the GPU
  abstraction — ALL rendering goes through it (MapSceneRenderer in
  swift_map/renderer is the repo's only `import SwiftGPU`); hosts keep
  surface/input/fetch-decode/callouts only. Its AGENTS.md documents the
  backends.
- **swift_ffi** (`//swift_ffi`).
  `ts_swift_library` / `kt_swift_library` generate the wasm reactor + TS
  bindings and the JNI .so + Kotlin bindings from the `@ExportedInterface`/
  `@ExportedFunction` bridge surfaces.
- **isomer's SwiftUI libraries** (the rest of the repository) consume this
  directory — the SwiftUI `Map`/`MapCamera`
  (IsomerBridge on Apple, placeholder in the reimplementation core)
  ride this engine. swift_map must never depend on them. Its AGENTS.md documents shared toolchain
  gotchas in depth; this repo's MODULE.bazel/.bazelrc mirror it.

## Build & verify (macOS host)

```sh
bazel test //swift_map/tests:core_tests          # engine unit tests
bazel build //...                                # full wildcard build works
bazel run //swift_map/apple/tools/map_snapshot -- /tmp/map.png   # offscreen Metal + real tiles
bazel run //swift_map/apple/applications/example_metal_macos_application
bazel build //swift_map/apple/applications/example_metal_ios_application --ios_multi_cpus=sim_arm64
bazel run //swift_map/web/applications/example_webgpu_web_application    # append `-- --no-open` args AFTER the built-ins; port is fixed at 8080
bazel run //swift_map/android/applications/example_opengl_android_application  # tails logcat; doesn't exit
```

Headless web verification: `tools/testing/cdp.py <url> <png> wait=8
"eval=window.__smLastFrame.quads.length"` (rm -rf /tmp/iso-cdp-profile if
the page looks stale). Android verification: boot
`bazel run //swift_map/tools/android/emulator -- -no-window`, adb install the
**signed** APK, `adb exec-out screencap -p`; **kill the headless emulator
afterward** (`adb emu kill`) or the user's windowed run appears broken.

## Hard-won gotchas

- **swift_test on macOS**: the xctest bundle resolves XCTest dylibs through
  the `/var/db/xcode_select_link` symlink, which not every machine has, and
  SIP strips DYLD_* env vars under the bash test wrapper. Fix = explicit
  `-Wl,-rpath` linkopts to /Applications/Xcode.app's usr/lib, Frameworks,
  AND PrivateFrameworks (XCTestCore lives there) — see swift_map/tests/BUILD.bazel.
- **Wildcard builds vs iOS**: the iOS example's swift_library compiles for
  the host under `bazel build //...`; its sources are wrapped in
  `#if canImport(UIKit)` so that build is empty rather than broken.
- **cquery for the APK**: `bazel cquery --output=files ..._apk` lists the
  **unsigned** APK first; install the one not matching `_unsigned`.
- **Core is Foundation-free**: libm comes from the
  canImport(Darwin/WASILibc/Android/Glibc) chain; no `String.range(of:)`,
  no String(format:) — hand-rolled replace + number formatting.
- **No frame loop anywhere**: the engine invalidates via
  `setNeedsRender()`; MTKView runs paused + setNeedsDisplay, web coalesces
  into one rAF, Android uses RENDERMODE_WHEN_DIRTY. Anything time-driven
  (future inertia) must schedule its own invalidations.
- **Android threading**: every engine call happens on the GL thread
  (queueEvent / onDrawFrame); GL context loss kills textures, so
  onSurfaceCreated resets the texture cache and re-calls `smStart`.
- **static_site renames the reactor** to `map.wasm` at the site root;
  boot.js takes `wasmURL` explicitly from index.html. The ts bridge target
  is named `map_bridge` so boot.js's `../map_bridge.js` import resolves.
- **OSM tile policy**: identifying User-Agent on Apple/Android fetchers
  (browsers can't override theirs); attribution overlays are required
  (ODbL) and every platform draws one. Don't hammer the public server.
- The rules_android Maven artifact list + lock file are copied verbatim
  from isomer so the lock stays valid; the example app itself uses
  only android.jar APIs (no androidx).
- **Overlays**: annotations = billboarded circle fans generated in SCREEN
  space (anchors CPU-projected through the frame matrix; drawn with the
  frame's `sm` plain-NDC matrix); polygons = ear-clip triangulated ONCE in
  Mercator space, remapped linearly per frame, drawn with `m`. Both cross
  the bridges as stride-6 per-vertex-color triangle lists ("shapes"/"marks")
  plus spec-string setters (smSetAnnotations/smSetPolygons — grammar in
  MapOverlaySpec.swift). Metal overlay draws need a device buffer
  (setVertexBytes caps at 4 KB).
- **Camera projection**: bearing/tilt ship as ONE column-major 4x4 in
  MapFrame (flat screen points -> clip space) so UVs stay
  perspective-correct; never pre-project quads on the CPU. The frame JSON's
  matrix uses a plain-decimal formatter (org.json rejects some exponent
  forms). Visible tiles = corner-unprojected bounding box, spread-capped.
- **XCFramework**: `swift.enable_library_evolution` +
  `swift.emit_swiftinterface` features live on the Apple swift_library;
  distribution/Package.swift wraps the unzipped bazel output as a
  binaryTarget (verified with a scratch SwiftPM consumer).

## Working conventions

- Hermeticity everywhere but Apple (local Xcode). Every tool comes from a
  pinned repository. Keep it that way.
- MODULE.bazel and the .bzl files carry deliberate explanatory comments —
  maintain that density.
