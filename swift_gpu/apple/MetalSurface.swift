// SwiftGPU's Metal backend on Apple platforms: what the portable device
// (swift_gpu/metal) leaves to them, an on-screen surface view (MTKView)
// and an offscreen render-to-bytes for tests and snapshots. With the
// portable device, the only Metal and MetalKit imports in the ecosystem
// outside Isomer's own Metal.

import Metal
import MetalKit

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

extension MetalGPUDevice {
    /// An on-screen render surface (an NSView/UIView): event-driven — set
    /// `onDraw` and call `setNeedsRender()`.
    public func makeSurfaceView() -> GPUSurfaceView {
        GPUSurfaceView(device: self)
    }

    /// Render one frame into an offscreen target and read it back as
    /// tightly packed RGBA bytes (top-left origin).
    public func renderOffscreen(
        width: Int,
        height: Int,
        clear: GPUColor,
        _ body: (GPURenderPass) -> Void
    ) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .shared
        let target = device.makeTexture(descriptor: descriptor)!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: clear.red, green: clear.green, blue: clear.blue, alpha: clear.alpha)

        let commandBuffer = queue.makeCommandBuffer()!
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
        body(MetalRenderPass(device: self, encoder: encoder, targetWidth: width, targetHeight: height))
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(
            &bgra,
            bytesPerRow: width * 4,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
        // BGRA -> RGBA so callers see the API's canonical byte order.
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra.swapAt(i, i + 2)
        }
        return bgra
    }
}

/// The on-screen Metal surface: an MTKView driven event-style (`isPaused`,
/// draw on `setNeedsRender()`). Consumers see an NSView/UIView; all Metal
/// stays in this module.
public final class GPUSurfaceView: MTKView {
    private let gpuDevice: MetalGPUDevice

    /// Encode the frame: receives the pass and the drawable's logical size
    /// in points.
    public var onDraw: ((GPURenderPass, Double, Double) -> Void)?

    /// The frame background.
    public var clear: GPUColor = GPUColor(red: 0, green: 0, blue: 0) {
        didSet {
            clearColor = MTLClearColor(
                red: clear.red, green: clear.green, blue: clear.blue, alpha: clear.alpha)
        }
    }

    init(device: MetalGPUDevice) {
        gpuDevice = device
        super.init(frame: .zero, device: device.device)
        colorPixelFormat = .bgra8Unorm
        isPaused = true
        enableSetNeedsDisplay = true
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public func setNeedsRender() {
        #if canImport(AppKit)
        needsDisplay = true
        #else
        setNeedsDisplay()
        #endif
    }

    public override func draw(_ dirtyRect: CGRect) {
        guard let drawable = currentDrawable,
              let descriptor = currentRenderPassDescriptor,
              let onDraw else {
            return
        }
        gpuDevice.render(drawable: drawable, renderPassDescriptor: descriptor) { pass in
            onDraw(pass, Double(bounds.width), Double(bounds.height))
        }
    }
}
