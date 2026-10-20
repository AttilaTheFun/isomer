// The SwiftGPU surface: a deliberately small, friendly abstraction over the
// platform graphics APIs (Metal / OpenGL ES / WebGPU / DirectX). Consumers
// program against these protocols; each platform's SwiftGPU module provides
// the device (MetalGPUDevice on Apple's Metal and on Isomer's Metal in a
// browser, GLESGPUDevice, DirectXGPUDevice, GLGPUDevice).
//
// The surface is three pipelines — premultiplied-alpha textured triangles,
// straight-alpha per-vertex-color triangles, and SDF rounded rects — plus an
// axis-aligned scissor, under one homogeneous transform. That covers tile/
// scene rendering and UI draw lists, and grows deliberately rather than
// exposing raw pipeline objects.

/// A straight-alpha RGBA color in [0, 1].
public struct GPUColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// An opaque handle to a device texture (RGBA8, premultiplied alpha —
/// `drawTextured` composites with premultiplied blending, so translucent
/// pixels must arrive premultiplied; opaque content is unaffected). Created
/// by `GPUDevice.makeTexture`; backends subclass or map `id` to their native
/// resource.
public class GPUTexture {
    public let id: Int
    public let width: Int
    public let height: Int

    init(id: Int, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }
}

/// A GPU device: owns textures and (per platform) the render surface.
public protocol GPUDevice: AnyObject {
    /// Create an RGBA8 texture from tightly packed bytes
    /// (`width * height * 4`). Translucent content must be PREMULTIPLIED —
    /// `drawTextured` blends `src = ONE, dst = INV_SRC_ALPHA` on every
    /// backend, so straight-alpha translucent pixels render dark fringes
    /// (or black boxes for rasterized text). Opaque bytes are unaffected.
    func makeTexture(width: Int, height: Int, rgba: [UInt8]) -> GPUTexture

    /// Free the texture's native resource; the handle is dead afterwards.
    func destroyTexture(_ texture: GPUTexture)
}

/// One frame's draw encoder. Draw order is paint order; every vertex
/// position runs through the current transform.
public protocol GPURenderPass: AnyObject {
    /// Column-major 4x4 taking positions (x, y, 0, 1) to clip space.
    /// Applies to subsequent draws.
    func setTransform(_ matrix: [Double])

    /// Textured triangles, vertex stride 4: x, y, u, v. Premultiplied-alpha
    /// blended (fully opaque textures composite unchanged).
    func drawTextured(vertices: [Float], texture: GPUTexture)

    /// Solid triangles, vertex stride 6: x, y, red, green, blue, alpha.
    /// Straight-alpha blended over the frame.
    func drawColor(vertices: [Float])

    /// Anti-aliased rounded rectangles (fills and centered strokes) via a
    /// signed-distance-field shader. Instance stride 11:
    /// x, y, width, height, cornerRadius, borderWidth (0 = fill),
    /// red, green, blue, alpha, unused. Straight-alpha blended.
    func drawRects(instances: [Float])

    /// Clip subsequent draws to a device-pixel rectangle (the axis-aligned
    /// scissor every backend has). Pass `nil` to clear.
    func setScissor(x: Int, y: Int, width: Int, height: Int)
    func clearScissor()
}

/// The number of floats per `drawRects` instance.
public let gpuRectInstanceStride = 11

/// Expand `drawRects` instances (stride 11) into stride-12 triangle
/// vertices (6 per rect) every backend feeds its SDF shader:
/// pos(2), local(2), halfSize(2), radius(1), border(1), color(4).
/// Strokes are centered on the edge, so the quad grows by border/2.
public func expandRectInstances(_ instances: [Float]) -> [Float] {
    var vertices: [Float] = []
    vertices.reserveCapacity((instances.count / gpuRectInstanceStride) * 6 * 12)
    var index = 0
    while index + gpuRectInstanceStride <= instances.count {
        let x = instances[index]
        let y = instances[index + 1]
        let width = instances[index + 2]
        let height = instances[index + 3]
        let radius = instances[index + 4]
        let border = instances[index + 5]
        let red = instances[index + 6]
        let green = instances[index + 7]
        let blue = instances[index + 8]
        let alpha = instances[index + 9]
        index += gpuRectInstanceStride

        let grow = border / 2
        let originX = x - grow
        let originY = y - grow
        let quadWidth = width + grow * 2
        let quadHeight = height + grow * 2
        let corners: [(Float, Float)] = [
            (0, 0), (1, 0), (0, 1),
            (1, 0), (1, 1), (0, 1),
        ]
        for (cornerX, cornerY) in corners {
            vertices.append(originX + cornerX * quadWidth)
            vertices.append(originY + cornerY * quadHeight)
            vertices.append((cornerX - 0.5) * quadWidth)
            vertices.append((cornerY - 0.5) * quadHeight)
            vertices.append(width / 2)
            vertices.append(height / 2)
            vertices.append(radius)
            vertices.append(border)
            vertices.append(red)
            vertices.append(green)
            vertices.append(blue)
            vertices.append(alpha)
        }
    }
    return vertices
}

/// Pack Float32 values as little-endian bytes (the wire form vertex data
/// takes across FFI boundaries; free on every supported target — they are
/// all little-endian).
public func packFloats(_ values: [Float]) -> [UInt8] {
    values.withUnsafeBytes { Array($0) }
}
