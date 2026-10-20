// SwiftGPU in a browser: the Metal backend's device (swift_gpu/metal) over
// Isomer's Metal, drawing each frame into the page's canvas through
// IsomerMetalLayer. The page connects Isomer's Metal executor before a
// surface is made:
//   const metalHost = await createIsomerMetalHost(canvas);
//   metalHost.connect(bridge);

import IsomerMetalWeb
import Metal

public final class MetalWebSurface {
    public let device: MetalGPUDevice
    public let layer: IsomerMetalLayer
    private var drawable: (any IsomerMetalDrawable)?

    /// Nil until the page has connected its executor (no Metal device).
    public init?(surface: Int32 = 1) {
        guard let device = MetalGPUDevice() else { return nil }
        self.device = device
        layer = IsomerMetalLayer(surface: surface)
        layer.device = device.device
        layer.pixelFormat = .bgra8Unorm
    }

    /// Open a frame on the canvas's next drawable, cleared to `clear`.
    public func beginFrame(clear: GPUColor) -> GPURenderPass? {
        guard let next = layer.nextDrawable() else { return nil }
        drawable = next
        return device.beginFrame(texture: next.texture, clear: clear)
    }

    /// Commit the frame and present it.
    public func endFrame() {
        device.endFrame(present: drawable)
        drawable = nil
    }

    /// Render one frame into the canvas.
    public func renderFrame(clear: GPUColor, _ body: (GPURenderPass) -> Void) {
        guard let pass = beginFrame(clear: clear) else { return }
        body(pass)
        endFrame()
    }
}
