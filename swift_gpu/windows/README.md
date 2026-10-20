# swift_gpu Windows backend (DirectX) — implementation guide

Status: **implemented** (D3D11 via a flat C shim — `sgpu_d3d11.cpp` +
`DirectXGPUDevice.swift`; offscreen pixel checks in
`directx_backend_check`). The guide below is kept as the backend's design
rationale and for the consumer-migration steps.

## What to build

A `DirectXGPUDevice` (+ render pass) conforming to the SwiftGPU API in
`//swift_gpu/core:GPUDevice.swift`, compiled as the `SwiftGPU` module for
Windows (mirror `//swift_gpu/apple:swift_gpu` / `//swift_gpu/android:
swift_gpu` — a `swift_library` named `swift_gpu`, `module_name =
"SwiftGPU"`, srcs = this backend + `//swift_gpu/core:srcs`, constrained
`target_compatible_with = ["@platforms//os:windows"]`).

D3D11 is the recommended level: flat 2D pipelines, no need for D3D12's
explicit residency/queues. Feature level 10_0 is plenty.

## The API contract (must match the other backends exactly)

Read `swift_gpu/core/GPUDevice.swift` first — it is the source of truth.
Summary of the semantics the shaders/pipelines must reproduce:

- **Transform**: one column-major 4x4; `clip = M * (x, y, 0, 1)`. The
  matrix goes all the way to clip space; the GPU's perspective divide must
  interpolate UVs perspective-correctly (pass positions as float4 through
  the vertex shader — do NOT divide on the CPU).
- **drawTextured** — stride 4 (x, y, u, v), triangle list, sampled with a
  linear clamp-to-edge sampler, **premultiplied-alpha blended**
  (`src = ONE, dst = INV_SRC_ALPHA`, both color and alpha). Textures are
  RGBA8 (DXGI_FORMAT_R8G8B8A8_UNORM), tightly packed, straight-from-caller
  (callers premultiply; opaque content has alpha 255 throughout).
- **drawColor** — stride 6 (x, y, r, g, b, a), straight-alpha blended
  (`src = SRC_ALPHA, dst = INV_SRC_ALPHA`; alpha channel `ONE /
  INV_SRC_ALPHA`).
- **drawRects** — stride-11 SDF rounded-rect instances. Call
  `expandRectInstances` from core (CPU expansion to stride-12 vertices,
  6 per rect: pos2, local2, halfSize2, radius, border, color4) and port
  the SDF fragment shader — the HLSL translation of `rect_fs` in
  `swift_gpu/apple/MetalGPUDevice.swift` (sdRoundBox + smoothstep edges;
  border > 0 means a centered stroke). Blending as drawColor.
- **setScissor/clearScissor** — device-pixel, top-left origin
  (D3D11 `RSSetScissorRects` is already top-left — no flip needed, unlike
  GL). Clamp to the render target (mirror the Metal backend's clamping).
  clearScissor = full-target rect (a rasterizer state with scissor always
  enabled + full-size rect is simplest).
- **Textures**: `makeTexture(width:height:rgba:)` from tightly packed
  bytes (`rowPitch = width * 4`); `destroyTexture` releases. Subclass
  `GPUTexture` holding the `ID3D11ShaderResourceView` (see `MetalTexture`
  / `GLESTexture` for the pattern).

## Talking to D3D from Swift

Two options, in order of preference:

1. **A small C shim, compiled into this package** (the pattern
   isomer's Windows host already uses — see
   `isomer/windows/libraries/swift_ui/renderer.{h,cpp}` for a
   working Swift↔C↔D3D-era setup with `cc_library` + `swiftc_inputs`
   header import). Keep the shim mechanical: create device/swapchain,
   compile the three shader pairs (D3DCompile at startup), and expose
   flat C functions (`sgpu_begin_frame`, `sgpu_draw_textured(verts, n,
   tex)`, …) that the Swift backend calls 1:1 from the GPURenderPass
   methods. ALL D3D calls stay in this directory — that is the point of
   swift_gpu.
2. Direct COM from Swift via `@_extern(c)` is possible but miserable
   (vtable calls by hand). Don't.

## Surface/device ownership

Follow the GLES backend's division: the HOST (isomer's Windows app
shell / a future swift_map Windows host) owns the HWND and sizing; the
backend owns device, swapchain, pipelines, textures, draws.
Suggested Swift surface:

```swift
public final class DirectXGPUDevice: GPUDevice {
    public init?(hwnd: UnsafeMutableRawPointer)   // creates device+swapchain
    public func resize(widthPx: Int, heightPx: Int)  // swapchain resize
    public func beginFrame(clear: GPUColor) -> GPURenderPass
    public func endFrame()                         // Present(1, 0)
    public func renderFrame(clear:_:)              // closure sugar, see GLES
}
```

## After the backend: migrate the consumers

1. `isomer/windows` — replace the Direct2D draw path in
   `renderer.cpp` with the SwiftGPURenderer flow: WindowsHost implements
   `rasterize(spec) -> [UInt8]` (DirectWrite for text, GDI+/WIC or D2D
   *offscreen* for gradients/shadows/images — rasterization is not a GPU
   call, so D2D-to-bitmap here is fine), the bridge wraps the host in
   `SwiftGPURenderer` for low-level bindings (copy the Android wiring in
   `isomer/android/libraries/swift_ui/AndroidBridge.swift`,
   including the surface-size globals and the wantsRender continuation
   gotcha), and the legacy draw-list path is deleted. Only the *draw*
   functions go: the services half of `renderer.cpp` survives unchanged —
   window + message loop, DirectWrite measurement, the EDIT text-input
   overlay, native Picker/DatePicker/WebView child windows, the WinHTTP
   pool, image decode, app-private storage, and crash logging.
2. `swift_map` — add a Windows host (window + input + WinHTTP/URLSession
   fetcher + WIC decode → RGBA bytes) and reuse `MapSceneRenderer`
   unchanged.

## Verification (on the Windows machine)

- Port `swift_gpu/tests/MetalBackendTests.swift` as an offscreen D3D test
  (render to a staging texture, Map/read back, same pixel asserts: clear,
  blended triangle, 2x2 texture sampling, SDF corner cut, scissor halves).
  Note the RGBA byte-order swizzle in `renderOffscreen` if the target is
  BGRA.
- Then `isomer`'s example app under the low-level binding and the
  swift_map example, visually.

## Gotchas collected from the other backends

- Premultiplied blending on drawTextured is NOT optional: without it,
  rasterized text/shadow textures composite as black boxes.
- The SDF quad grows by border/2 for strokes (expandRectInstances handles
  it) — don't re-derive.
- Vertex data arrives as Swift `[Float]`; per-draw dynamic vertex buffers
  (D3D11_USAGE_DYNAMIC + Map/WRITE_DISCARD) are fine at these sizes.
- Windows builds use `--spawn_strategy=local` (.bazelrc) and build natively
  on the Windows host only — nothing here is cross-compiled from macOS, so
  keep the package `target_compatible_with` Windows to stay out of
  wildcard builds on other hosts.
