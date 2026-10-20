// MetalView: a view that draws with Metal, as an MTKView does on Apple
// platforms (where Isomer's MetalView wraps one). The app's closure gets a
// frame (device, command queue, drawable, render pass descriptor) and
// encodes, presents and commits as with an MTKView's delegate.
//
// In a browser the view is a host view ("metal"): under the React renderer
// the page gives it a canvas, a surface of the page's Metal executor, and
// asks for a frame each animation frame (`isoMetalViewFrame`); under the
// GPU renderer the frame is drawn into a texture the renderer composites in
// place (SwiftGPURenderer.metalViewFrame).

@_exported import IsomerMetal
@_exported import IsomerMetalWeb
import Metal
import SwiftUI

/// One frame of a MetalView: what an MTKView's delegate reads from the view.
public struct MetalViewFrame {
    public let device: any MTLDevice
    /// The view's queue (one per device).
    public let commandQueue: any MTLCommandQueue
    public let currentDrawable: any MTLDrawable
    /// The drawable's texture (the first color attachment).
    public let texture: any MTLTexture
    /// Clears the drawable to the view's clear color, and stores.
    public let currentRenderPassDescriptor: MTLRenderPassDescriptor
    /// In pixels.
    public let drawableSize: CGSize
}

public struct MetalView: View {
    @State private var token = MetalViews.makeToken()
    private let entry: MetalViews.Entry

    /// `draw` is called for every frame, as `MTKViewDelegate.draw(in:)` is.
    public init(
        device: (any MTLDevice)? = nil,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
        draw: @escaping (MetalViewFrame) -> Void
    ) {
        entry = MetalViews.Entry(device: device, colorPixelFormat: colorPixelFormat, clearColor: clearColor, draw: draw)
    }

    public var body: some View {
        MetalViews.register(token, entry)
        return _MetalHostView(token: token)
    }
}

/// The host view: the token is how the page (and the GPU renderer) asks
/// for this view's frames.
struct _MetalHostView: PlatformViewRepresentable {
    let token: String

    var kind: String { "metal" }
    var value: String { token }

    /// The page says "gone" when the view's canvas is unmounted.
    func onValueChanged(_ value: String) {
        if value == "gone" {
            MainActor.assumeIsolated { MetalViews.forget(token) }
        }
    }
}

@MainActor
enum MetalViews {
    struct Entry {
        var device: (any MTLDevice)?
        var colorPixelFormat: MTLPixelFormat
        var clearColor: MTLClearColor
        var draw: (MetalViewFrame) -> Void
    }

    private static var entries: [String: Entry] = [:]
    private static var layers: [String: IsomerMetalLayer] = [:]
    private static var offscreen: [String: any MTLTexture] = [:]
    private static var queues: [ObjectIdentifier: any MTLCommandQueue] = [:]
    private static var counter = 0

    nonisolated static func makeToken() -> String {
        MainActor.assumeIsolated {
            counter += 1
            return "metal-\(counter)"
        }
    }

    static func register(_ token: String, _ entry: Entry) {
        entries[token] = entry
        if SwiftGPURenderer.metalViewFrame == nil {
            SwiftGPURenderer.metalViewFrame = { token, width, height in
                MainActor.assumeIsolated { drawOffscreen(token, width: width, height: height) }
            }
        }
    }

    static func forget(_ token: String) {
        entries[token] = nil
        layers[token] = nil
        offscreen[token] = nil
    }

    private static func queue(for device: any MTLDevice) -> (any MTLCommandQueue)? {
        if let queue = queues[ObjectIdentifier(device)] { return queue }
        let queue = device.makeCommandQueue()
        queues[ObjectIdentifier(device)] = queue
        return queue
    }

    private static func passDescriptor(_ texture: any MTLTexture, _ entry: Entry) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = entry.clearColor
        return descriptor
    }

    /// A frame into the view's canvas (the React renderer's path).
    static func drawToSurface(_ token: String, surface: Int32) {
        guard let entry = entries[token], let device = entry.device ?? MTLCreateSystemDefaultDevice(),
              let queue = queue(for: device) else { return }
        let layer: IsomerMetalLayer
        if let existing = layers[token], existing.surface == surface {
            layer = existing
        } else {
            layer = IsomerMetalLayer(surface: surface)
            layers[token] = layer
        }
        layer.device = device
        layer.pixelFormat = entry.colorPixelFormat
        guard let drawable = layer.nextDrawable() else { return }
        let size = layer.drawableSize
        entry.draw(MetalViewFrame(
            device: device, commandQueue: queue, currentDrawable: drawable, texture: drawable.texture,
            currentRenderPassDescriptor: passDescriptor(drawable.texture, entry),
            drawableSize: CGSize(width: size.width, height: size.height)))
    }

    /// A frame into a texture of the given size (the GPU renderer's path),
    /// which the renderer then draws.
    static func drawOffscreen(_ token: String, width: Int, height: Int) -> (any MTLTexture)? {
        guard width > 0, height > 0, let entry = entries[token],
              let device = entry.device ?? MTLCreateSystemDefaultDevice(), let queue = queue(for: device) else { return nil }
        var texture = offscreen[token]
        if texture == nil || texture!.width != width || texture!.height != height || texture!.pixelFormat != entry.colorPixelFormat {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: entry.colorPixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            texture = device.makeTexture(descriptor: descriptor)
            offscreen[token] = texture
        }
        guard let texture else { return nil }
        entry.draw(MetalViewFrame(
            device: device, commandQueue: queue, currentDrawable: OffscreenDrawable(texture: texture), texture: texture,
            currentRenderPassDescriptor: passDescriptor(texture, entry),
            drawableSize: CGSize(width: width, height: height)))
        return texture
    }
}

/// A frame drawn into a texture: presenting it is the renderer's job.
private final class OffscreenDrawable: IsomerMetalDrawable {
    let texture: any MTLTexture
    let drawableID = 0
    var presentedTime: CFTimeInterval { 0 }

    init(texture: any MTLTexture) {
        self.texture = texture
    }

    func present() {}
    func present(at presentationTime: CFTimeInterval) {}
    func present(afterMinimumDuration duration: CFTimeInterval) {}
    func addPresentedHandler(_ block: @escaping MTLDrawablePresentedHandler) {}
}

/// The page asks for a frame of a MetalView whose canvas is `surface`.
@ExportedFunction
package func isoMetalViewFrame(token: String, surface: Int32) {
    MainActor.assumeIsolated {
        MetalViews.drawToSurface(token, surface: surface)
    }
}
