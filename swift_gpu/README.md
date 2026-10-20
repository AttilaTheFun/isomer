# SwiftGPU

A friendly, abstracted GPU API for cross-platform Swift — the graphics
layer of the stack:

```
rules_swift  <  swift_ffi  <  swift_gpu  <  swift_map  <  isomer
```

One `SwiftGPU` module per platform wraps the native graphics API. Every
direct GPU call in the ecosystem lives here (including the JS WebGPU
executor); consumers program against `GPUDevice`/`GPURenderPass` and may
not touch a graphics API themselves.

| Platform | Backend | How |
| -------- | ------- | --- |
| iOS / macOS | Metal | direct (MTKView surface + offscreen render-to-bytes) |
| Android | OpenGL ES 2 | direct C calls via `@_extern(c)` on the host's GL thread |
| Web (wasm) | WebGPU | commands bridged via swift_ffi to `runtime/swift_gpu_webgpu.js` |
| Windows | Direct3D 11 | flat C shim (`sgpu_d3d11.cpp`), Swift binds via `@_extern(c)` — see [swift_gpu/windows/](swift_gpu/windows/README.md) |
| Linux | OpenGL | planned — implementation guide in [swift_gpu/linux/](swift_gpu/linux/README.md) |

## The API (swift_gpu/core)

- `GPUDevice`: RGBA8 textures from tightly packed bytes.
- `GPURenderPass`: one column-major 4x4 transform to clip space;
  `drawTextured` (stride-4 triangles, premultiplied-alpha blended),
  `drawColor` (stride-6, straight-alpha blended), `drawRects`
  (stride-11 SDF rounded rects: fills + centered strokes), and
  axis-aligned `setScissor`/`clearScissor`.

Deliberately small: enough for tile scenes (swift_map) and UI draw
lists (isomer's SwiftGPURenderer), growing by need rather than
exposing raw pipeline objects.

## Bringing your own backend

The core is backend-free by construction: `swift_gpu/core` is the
`GPUDevice` / `GPURenderPass` protocol surface plus the shared drawing
logic, with no Metal/GLES/WebGPU dependency — each platform package
compiles `//swift_gpu/core:srcs` together with its device into its own
`SwiftGPU` module. A third-party backend plugs in the same way:

1. Implement `GPUDevice` (and its render pass) over your API.
2. Compile `@isomer//swift_gpu/core:srcs` + your device into a
   `SwiftGPU` module for your platform.
3. Hand your device to the consumer's renderer surface (isomer's
   `SwiftGPURenderer` takes the device through its surface — it never
   constructs one).

## Consumers

- **swift_map** renders its map scenes through this API on all three
  platforms (one `MapSceneRenderer`).
- **isomer**'s `SwiftGPURenderer` is the single low-level UI
  renderer (shapes SDF-drawn; text/gradients/shadows/images rasterized
  by the platform host into textures).

Verification: `bazel test //swift_gpu/tests:metal_backend_tests` asserts
pixels offscreen (clear/blend/texture-sampling/SDF-corners/scissor);
cross-compiles: `bazel build //swift_gpu/{android,wasm}:swift_gpu
--platforms=//tools/platforms:{android_arm64,wasm32}`.
