# swift_gpu Linux backend (OpenGL) — implementation guide

Status: **stub — not implemented**. This directory is the home for the
Linux OpenGL backend. This document is the handoff spec.

## What to build

A `GLGPUDevice` conforming to the SwiftGPU API in
`//swift_gpu/core:GPUDevice.swift`, compiled as the `SwiftGPU` module for
Linux (a `swift_library` named `swift_gpu`, `module_name = "SwiftGPU"`,
srcs = backend + `//swift_gpu/core:srcs`, `target_compatible_with =
["@platforms//os:linux"]`).

**Start by copying the Android backend** — it is ~95% of this job:

- `swift_gpu/android/GLES.swift` — the `@_extern(c)` GL declarations
  (copts `-enable-experimental-feature Extern`). Desktop GL exports the
  same symbols; change `linkopts = ["-lGLESv2"]` to `["-lGL"]`. The
  GLSL 100-style shaders (`attribute`/`varying`, `precision mediump`)
  compile on desktop GL in compatibility contexts; if the host creates a
  core-profile context instead, prefix the shaders with `#version 120`
  semantics or request a compatibility context (simplest: have the host
  request GLES2 or a compat context via SDL_GL attributes).
- `swift_gpu/android/GLESGPUDevice.swift` — device, programs, textures,
  the three draw paths, scissor (remember GL's scissor origin is
  BOTTOM-LEFT: the backend flips using the surface height, already
  implemented), context-loss handling (less relevant on desktop, keep the
  API for symmetry).

The API contract (strides, blending, SDF shader, transform semantics) is
documented in `swift_gpu/core/GPUDevice.swift` and in
`swift_gpu/windows/README.md`'s "API contract" section — identical here.

## Surface/context ownership

The HOST owns the window + GL context (isomer's Linux shell uses
SDL2 — see `isomer/linux/libraries/swift_ui/`); the backend assumes
the context is current on the calling thread, exactly like the Android
backend assumes the GLSurfaceView's GL thread. `beginFrame(widthPx:
heightPx:clear:)` sets viewport + clear; `endFrame()` leaves the swap to
the host (SDL_GL_SwapWindow), mirroring GLSurfaceView.

## After the backend: migrate the consumers

1. `isomer/linux` — same recipe as Android's migration
   (`isomer/android/libraries/swift_ui/AndroidBridge.swift` is the
   reference): the Linux host implements `rasterize(spec) -> [UInt8]`
   ([w u32 LE][h u32 LE][premultiplied RGBA]) — Pango/Cairo is the natural
   rasterizer on Linux (cairo surfaces are premultiplied ARGB: swizzle to
   RGBA when packing) — the bridge wraps the host in `SwiftGPURenderer`
   for low-level bindings, and the legacy GL draw path in the host is
   deleted. Keep the wantsRender/animation continuation when short-
   circuiting the old draw-list path (see the Android UIRenderer gotcha).
2. `swift_map` — a Linux host (SDL window + input + FoundationTileFetcher,
   which already compiles on Linux + image decode via libpng/stb to RGBA)
   reusing `MapSceneRenderer` unchanged.

## Verification (on the Linux machine)

- An offscreen pixel test mirroring
  `swift_gpu/tests/MetalBackendTests.swift` via a framebuffer object +
  `glReadPixels` (note glReadPixels returns bottom-up rows: flip before
  asserting).
- Then isomer's example app under the low-level binding and the
  swift_map example, visually.

## Gotchas collected from the other backends

- Premultiplied blending on drawTextured is NOT optional (black-box text
  otherwise); drawColor is straight-alpha; drawRects blends like
  drawColor.
- `expandRectInstances` (core) does the SDF instance expansion — reuse it;
  ES2-style client-side vertex arrays are fine at these sizes.
- Linux builds need clang (`build:linux --repo_env=CC=clang` — see
  isomer's .bazelrc notes) and build natively on the Linux host;
  keep `target_compatible_with` Linux so macOS wildcard builds skip this
  package.
