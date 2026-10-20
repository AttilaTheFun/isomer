# AGENTS.md — swift_gpu

> **Part of the isomer repository since 2026-10-02.** This was a repository
> and Bazel module of its own; it is now the `swift_gpu/` directory of the one
> `isomer` module. Labels are `//swift_gpu/...` from the repository root
> (`@isomer//swift_gpu/...` from another module), dependencies and toolchains are in
> the root `MODULE.bazel`/`.bazelrc`, and a consumer pins isomer, not this.
> Where the text below says "this repo", read "this directory"; the layering
> rule is unchanged (this directory depends on `//swift_ffi` only, never on swift_map or the SwiftUI libraries).

Context for AI agents (and new humans). Last updated 2026-07-07. If this
contradicts the code, trust the code and update this file.

## What this repo is

The GPU abstraction between swift_ffi and swift_map/isomer (see
README for the layer diagram). Private repo github.com/AttilaTheFun/
swift_gpu. THE rule this directory enforces: SwiftGPU's direct GPU calls
live here — Metal in swift_gpu/metal (MetalGPUDevice: one source for
Apple's Metal and, since 0.31, Isomer's) and swift_gpu/apple (the MTKView
surface), GL symbols in swift_gpu/android and linux, D3D in windows. In a
browser the Metal device runs on Isomer's Metal (//metal), whose executor
(metal/runtime/isomer_metal_webgpu.js) is the only navigator.gpu code.
Only swift_map and isomer's SwiftGPURenderer may `import SwiftGPU`.

## Hard-won gotchas

- The textured pipeline is PREMULTIPLIED-alpha blended in every backend:
  host-rasterized text/shadow textures composite through it, and without
  blending their transparent backgrounds render black. Opaque content is
  unaffected. Hosts must premultiply (canvas getImageData is straight
  alpha; Android bitmaps and ImageIO premultipliedLast already are).
- GLES binds GL via `@_extern(c)` (copts -enable-experimental-feature
  Extern) + linkopts -lGLESv2 — no NDK headers or module maps. The host
  GLSurfaceView owns EGL; every call happens on the GL thread;
  contextLost() rebuilds programs lazily and consumers must drop texture
  handles.
- The web (0.31): swift_gpu/wasm is MetalGPUDevice over Isomer's Metal
  with MetalWebSurface drawing each frame into the page's canvas
  (IsomerMetalLayer). Sites stage @isomer//metal/runtime:runtime_js and
  call `(await createIsomerMetalHost(canvas)).connect(bridge)` before
  starting (isomer_web_app's boot.js does). The GPU renderer's output is
  pixel-identical to the WebGPU device it replaced (GPUWebHost,
  swift_gpu_webgpu.js, now gone).
- drawRects expands instances on the CPU (expandRectInstances, 6
  stride-12 vertices per rect) so ES2 — no instancing — shares one path;
  strokes grow the quad by border/2. Metal clamps scissors to the
  attachment (validation), GL flips scissor origin to bottom-left.
- Metal setVertexBytes caps at 4 KB; larger batches go through
  makeBuffer (setVertexData handles it). On the web both end up in the
  stream's arena or a buffer of their own, at 256-byte offsets.
- swift_ffi's aspect is transitive and its glue imports every module
  that declared exports (sourceModules in the IR) — that's what lets
  this repo ship its own bridge surface.
- rules_swift pin: in the root MODULE.bazel.

## Verify

bazel test //swift_gpu/tests:metal_backend_tests   # offscreen pixel asserts
bazel build //swift_gpu/android:swift_gpu --platforms=//tools/platforms:android_arm64
bazel build //swift_gpu/wasm:swift_gpu --platforms=//tools/platforms:wasm32
bazel run //swift_gpu/windows:directx_backend_check  # on a Windows host
Real-world verification rides the consumers: swift_map (map_snapshot /
emulator / cdp.py) and isomer's example app under the swiftGPU
low-level binding.
