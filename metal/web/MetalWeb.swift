// Isomer's Metal in a browser: the backend that hands the `Metal` module's
// command streams to the page's WebGPU executor
// (metal/runtime/isomer_metal_webgpu.js, the only code that touches
// navigator.gpu), and the layer that gives a canvas's frames to Metal as
// drawables, as Core Animation's CAMetalLayer does on Apple platforms.
//
// The page connects the executor before the app makes its device:
//   const metalHost = await createIsomerMetalHost(canvas);
//   metalHost.connect(bridge);   // calls metalConnect(host:)

import IsomerFFI
import IsomerMetal
import Metal

/// The page's WebGPU executor, implemented by createIsomerMetalHost in
/// metal/runtime/isomer_metal_webgpu.js.
@ExportedInterface
public protocol MetalWebHost {
    /// Performs a command stream (IsomerMetal's MetalCommands format). A
    /// token other than 0 asks for `metalCompleted(token:readback:)` once
    /// the GPU has finished the stream's work.
    func metalPerform(commands: [UInt8], token: Int32)
    /// A surface's (canvas's) size in pixels; 0 when there is none.
    func metalSurfaceWidth(surface: Int32) -> Int32
    func metalSurfaceHeight(surface: Int32) -> Int32
    /// The adapter's description, for `MTLDevice.name`.
    func metalAdapterName() -> String
}

/// Installs the page's executor as the platform's Metal backend.
@ExportedFunction
public func metalConnect(host: any MetalWebHost) {
    currentMetalBackend = WebMetalBackend(host: host)
}

/// The executor's answer to a stream performed with a token: the GPU has
/// finished it, and `readback` holds what it read back (MetalReadback's
/// format).
@ExportedFunction
public func metalCompleted(token: Int32, readback: [UInt8]) {
    guard let backend = currentMetalBackend as? WebMetalBackend,
          let completion = backend.completions.removeValue(forKey: token) else { return }
    completion(MetalReadback(decoding: readback))
}

final class WebMetalBackend: MetalBackend {
    let host: any MetalWebHost
    var completions: [Int32: (MetalReadback) -> Void] = [:]
    private var nextToken: Int32 = 0

    init(host: any MetalWebHost) {
        self.host = host
    }

    lazy var name: String = host.metalAdapterName()

    func perform(_ commands: [UInt8], completion: ((MetalReadback) -> Void)?) {
        var token: Int32 = 0
        if let completion {
            nextToken = nextToken == Int32.max ? 1 : nextToken + 1
            token = nextToken
            completions[token] = completion
        }
        host.metalPerform(commands: commands, token: token)
    }

    func drawableSize(surface: Int32) -> (width: Int, height: Int)? {
        let width = Int(host.metalSurfaceWidth(surface: surface))
        let height = Int(host.metalSurfaceHeight(surface: surface))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }
}

/// A frame of a layer: its texture, to render into and present.
public protocol IsomerMetalDrawable: MTLDrawable {
    var texture: any MTLTexture { get }
}

extension _IsomerSurfaceDrawable: IsomerMetalDrawable {}

/// A canvas's frames as Metal drawables: what CAMetalLayer is to a view on
/// Apple platforms. Surface 1 is the canvas the page gave
/// createIsomerMetalHost; a page adds others with `metalHost.addSurface`.
public final class IsomerMetalLayer {
    public var device: (any MTLDevice)?
    public var pixelFormat: MTLPixelFormat = .bgra8Unorm
    public let surface: Int32

    public init(surface: Int32 = 1) {
        self.surface = surface
    }

    /// The canvas's size in pixels (its backing store, which the page
    /// sizes).
    public var drawableSize: (width: Int, height: Int) {
        currentMetalBackend?.drawableSize(surface: surface) ?? (0, 0)
    }

    /// The canvas's next frame, or nil when there is no device or no
    /// canvas.
    public func nextDrawable() -> (any IsomerMetalDrawable)? {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { return nil }
        return _isomerNextDrawable(device: device, surface: surface, pixelFormat: pixelFormat)
    }
}
