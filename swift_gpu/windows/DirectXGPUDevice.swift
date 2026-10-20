// The Direct3D 11 backend: Swift calls the flat C shim (sgpu_d3d11.cpp) 1:1
// from the GPUDevice/GPURenderPass methods. The HOST owns the HWND and
// sizing (isomer's Windows app shell / a future swift_map Windows
// host); this backend owns the device, swapchain, pipelines, textures, and
// draws — every D3D call in the ecosystem lives in this directory.
//
// The shim is a single global D3D context, so one DirectXGPUDevice exists
// per process (one window or one offscreen target) — the same shape as the
// other desktop hosts.

private final class DirectXTexture: GPUTexture {
    let handle: Int32

    init(id: Int, handle: Int32, width: Int, height: Int) {
        self.handle = handle
        super.init(id: id, width: width, height: height)
    }
}

public final class DirectXGPUDevice: GPUDevice {
    private var nextTextureID = 1
    private var targetWidthPx = 0
    private var targetHeightPx = 0
    private let offscreen: Bool

    /// Create the device + swapchain against the host's HWND (client size in
    /// device pixels). The host calls `resize` on WM_SIZE.
    public init?(hwnd: UnsafeMutableRawPointer, widthPx: Int, heightPx: Int) {
        offscreen = false
        guard sgpu_d3d_init_hwnd(hwnd, Int32(widthPx), Int32(heightPx)) != 0 else { return nil }
        targetWidthPx = widthPx
        targetHeightPx = heightPx
    }

    /// Create the device with a readable offscreen target (tests/snapshots),
    /// mirroring MetalGPUDevice's offscreen entry point.
    public init?(offscreenWidthPx: Int, heightPx: Int) {
        offscreen = true
        guard sgpu_d3d_init_offscreen(Int32(offscreenWidthPx), Int32(heightPx)) != 0 else {
            return nil
        }
        targetWidthPx = offscreenWidthPx
        targetHeightPx = heightPx
    }

    /// Resize the swapchain to the window's new client size (device pixels).
    public func resize(widthPx: Int, heightPx: Int) {
        sgpu_d3d_resize(Int32(widthPx), Int32(heightPx))
        targetWidthPx = widthPx
        targetHeightPx = heightPx
    }

    // MARK: - GPUDevice

    public func makeTexture(width: Int, height: Int, rgba: [UInt8]) -> GPUTexture {
        let handle = rgba.withUnsafeBufferPointer { bytes in
            sgpu_d3d_make_texture(Int32(width), Int32(height), bytes.baseAddress!)
        }
        nextTextureID += 1
        return DirectXTexture(id: nextTextureID, handle: handle, width: width, height: height)
    }

    public func destroyTexture(_ texture: GPUTexture) {
        guard let dxTexture = texture as? DirectXTexture else { return }
        sgpu_d3d_destroy_texture(dxTexture.handle)
    }

    // MARK: - Frames

    /// Open a frame: bind + clear the target. `endFrame` presents (no-op on
    /// the offscreen target).
    public func beginFrame(clear: GPUColor) -> GPURenderPass {
        sgpu_d3d_begin_frame(
            Float(clear.red), Float(clear.green), Float(clear.blue), Float(clear.alpha))
        return DirectXRenderPass(targetWidthPx: targetWidthPx, targetHeightPx: targetHeightPx)
    }

    public func endFrame() {
        sgpu_d3d_end_frame()
    }

    /// Closure sugar over begin/end (see the GLES backend's renderFrame).
    public func renderFrame(clear: GPUColor, _ body: (GPURenderPass) -> Void) {
        body(beginFrame(clear: clear))
        endFrame()
    }

    /// Render one frame offscreen and read it back as tightly packed RGBA
    /// bytes (top-left origin) — the pixel test's entry point.
    public func renderOffscreen(clear: GPUColor, _ body: (GPURenderPass) -> Void) -> [UInt8] {
        precondition(offscreen, "renderOffscreen requires init?(offscreenWidthPx:heightPx:)")
        renderFrame(clear: clear, body)
        var pixels = [UInt8](repeating: 0, count: targetWidthPx * targetHeightPx * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            sgpu_d3d_read_pixels(buffer.baseAddress!)
        }
        return pixels
    }
}

private final class DirectXRenderPass: GPURenderPass {
    private let targetWidthPx: Int
    private let targetHeightPx: Int

    init(targetWidthPx: Int, targetHeightPx: Int) {
        self.targetWidthPx = targetWidthPx
        self.targetHeightPx = targetHeightPx
        setTransform([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    }

    func setTransform(_ matrix: [Double]) {
        let floats = matrix.map { Float($0) }
        floats.withUnsafeBufferPointer { buffer in
            sgpu_d3d_set_transform(buffer.baseAddress!)
        }
    }

    func drawTextured(vertices: [Float], texture: GPUTexture) {
        guard vertices.count >= 12, let dxTexture = texture as? DirectXTexture else { return }
        vertices.withUnsafeBufferPointer { buffer in
            sgpu_d3d_draw_textured(buffer.baseAddress!, Int32(buffer.count), dxTexture.handle)
        }
    }

    func drawColor(vertices: [Float]) {
        guard vertices.count >= 18 else { return }
        vertices.withUnsafeBufferPointer { buffer in
            sgpu_d3d_draw_color(buffer.baseAddress!, Int32(buffer.count))
        }
    }

    func drawRects(instances: [Float]) {
        let vertices = expandRectInstances(instances)
        guard !vertices.isEmpty else { return }
        vertices.withUnsafeBufferPointer { buffer in
            sgpu_d3d_draw_rect_vertices(buffer.baseAddress!, Int32(buffer.count))
        }
    }

    func setScissor(x: Int, y: Int, width: Int, height: Int) {
        sgpu_d3d_set_scissor(Int32(x), Int32(y), Int32(width), Int32(height))
    }

    func clearScissor() {
        sgpu_d3d_clear_scissor()
    }
}
