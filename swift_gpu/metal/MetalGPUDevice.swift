// The Metal backend: a Metal device and SwiftGPU's three pipelines behind
// the SwiftGPU API. The same source runs on Apple's Metal (swift_gpu/apple
// adds the MTKView surface and the offscreen render-to-bytes) and on
// Isomer's Metal off Apple platforms (swift_gpu/wasm adds a canvas surface
// over IsomerMetalLayer): it imports Metal and nothing else.

import Metal

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct TexVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex TexVSOut tex_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 4;
    TexVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.uv = float2(verts[base + 2], verts[base + 3]);
    return out;
}

fragment float4 tex_fs(
    TexVSOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    sampler s [[sampler(0)]]
) {
    return tex.sample(s, in.uv);
}

struct ColorVSOut {
    float4 position [[position]];
    float4 color;
};

vertex ColorVSOut color_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 6;
    ColorVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.color = float4(verts[base + 2], verts[base + 3], verts[base + 4], verts[base + 5]);
    return out;
}

fragment float4 color_fs(ColorVSOut in [[stage_in]]) {
    return in.color;
}

struct RectVSOut {
    float4 position [[position]];
    float2 local;
    float2 halfSize;
    float radius;
    float border;
    float4 color;
};

vertex RectVSOut rect_vs(
    uint vid [[vertex_id]],
    const device float *verts [[buffer(0)]],
    constant float4x4 &transform [[buffer(1)]]
) {
    uint base = vid * 12;
    RectVSOut out;
    out.position = transform * float4(verts[base], verts[base + 1], 0.0, 1.0);
    out.local = float2(verts[base + 2], verts[base + 3]);
    out.halfSize = float2(verts[base + 4], verts[base + 5]);
    out.radius = verts[base + 6];
    out.border = verts[base + 7];
    out.color = float4(verts[base + 8], verts[base + 9], verts[base + 10], verts[base + 11]);
    return out;
}

float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r);
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

fragment float4 rect_fs(RectVSOut in [[stage_in]]) {
    float r = min(in.radius, min(in.halfSize.x, in.halfSize.y));
    float d = sdRoundBox(in.local, in.halfSize, r);
    float alpha;
    if (in.border > 0.0) {
        alpha = 1.0 - smoothstep(-0.75, 0.75, fabs(d) - in.border * 0.5);
    } else {
        alpha = 1.0 - smoothstep(-0.75, 0.75, d);
    }
    return float4(in.color.rgb, in.color.a * alpha);
}
"""

final class MetalTexture: GPUTexture {
    let native: any MTLTexture

    init(id: Int, native: any MTLTexture) {
        self.native = native
        super.init(id: id, width: native.width, height: native.height)
    }
}

public final class MetalGPUDevice: GPUDevice {
    let device: any MTLDevice
    let queue: any MTLCommandQueue
    let texturedPipeline: any MTLRenderPipelineState
    let colorPipeline: any MTLRenderPipelineState
    let rectPipeline: any MTLRenderPipelineState
    let sampler: any MTLSamplerState
    var nextTextureID = 1
    /// The frame `beginFrame` opened.
    private var frameCommandBuffer: (any MTLCommandBuffer)?
    private var frameEncoder: (any MTLRenderCommandEncoder)?

    public init?() {
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              let commandQueue = metalDevice.makeCommandQueue(),
              let library = try? metalDevice.makeLibrary(source: shaderSource, options: nil) else {
            return nil
        }
        device = metalDevice
        queue = commandQueue

        // Premultiplied-alpha blending: opaque content (alpha 1) is
        // unaffected; rasterized text/shadow textures composite correctly.
        let textured = MTLRenderPipelineDescriptor()
        textured.vertexFunction = library.makeFunction(name: "tex_vs")
        textured.fragmentFunction = library.makeFunction(name: "tex_fs")
        textured.colorAttachments[0].pixelFormat = .bgra8Unorm
        textured.colorAttachments[0].isBlendingEnabled = true
        textured.colorAttachments[0].sourceRGBBlendFactor = .one
        textured.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        textured.colorAttachments[0].sourceAlphaBlendFactor = .one
        textured.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let color = MTLRenderPipelineDescriptor()
        color.vertexFunction = library.makeFunction(name: "color_vs")
        color.fragmentFunction = library.makeFunction(name: "color_fs")
        color.colorAttachments[0].pixelFormat = .bgra8Unorm
        color.colorAttachments[0].isBlendingEnabled = true
        color.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        color.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        color.colorAttachments[0].sourceAlphaBlendFactor = .one
        color.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge

        let rect = MTLRenderPipelineDescriptor()
        rect.vertexFunction = library.makeFunction(name: "rect_vs")
        rect.fragmentFunction = library.makeFunction(name: "rect_fs")
        rect.colorAttachments[0].pixelFormat = .bgra8Unorm
        rect.colorAttachments[0].isBlendingEnabled = true
        rect.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        rect.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        rect.colorAttachments[0].sourceAlphaBlendFactor = .one
        rect.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let texturedState = try? metalDevice.makeRenderPipelineState(descriptor: textured),
              let colorState = try? metalDevice.makeRenderPipelineState(descriptor: color),
              let rectState = try? metalDevice.makeRenderPipelineState(descriptor: rect),
              let samplerState = metalDevice.makeSamplerState(descriptor: samplerDescriptor) else {
            return nil
        }
        texturedPipeline = texturedState
        colorPipeline = colorState
        rectPipeline = rectState
        sampler = samplerState
    }

    // MARK: - GPUDevice

    public func makeTexture(width: Int, height: Int, rgba: [UInt8]) -> GPUTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        let native = device.makeTexture(descriptor: descriptor)!
        rgba.withUnsafeBytes { bytes in
            native.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4
            )
        }
        nextTextureID += 1
        return MetalTexture(id: nextTextureID, native: native)
    }

    /// A texture this device's pipelines can draw, over a Metal texture
    /// made elsewhere on the same device (a view's offscreen frame).
    public func makeTexture(wrapping texture: any MTLTexture) -> GPUTexture {
        nextTextureID += 1
        return MetalTexture(id: nextTextureID, native: texture)
    }

    public func destroyTexture(_ texture: GPUTexture) {
        // MTLTextures free with their last reference; dropping the handle
        // is enough.
    }

    // MARK: - Frames

    /// Open a frame drawing into `texture`, cleared to `clear`; draw into
    /// the returned pass until `endFrame` (for renderers whose draw calls
    /// arrive across a call tree rather than in one closure).
    public func beginFrame(texture: any MTLTexture, clear: GPUColor) -> GPURenderPass? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: clear.red, green: clear.green, blue: clear.blue, alpha: clear.alpha)
        return beginFrame(renderPassDescriptor: descriptor)
    }

    /// Open a frame on a render pass descriptor (its first color
    /// attachment is the target).
    public func beginFrame(renderPassDescriptor: MTLRenderPassDescriptor) -> GPURenderPass? {
        guard let target = renderPassDescriptor.colorAttachments[0].texture,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return nil
        }
        frameCommandBuffer = commandBuffer
        frameEncoder = encoder
        return MetalRenderPass(device: self, encoder: encoder, targetWidth: target.width, targetHeight: target.height)
    }

    /// Close the frame `beginFrame` opened and commit it, presenting
    /// `drawable` when there is one.
    public func endFrame(present drawable: (any MTLDrawable)? = nil) {
        guard let commandBuffer = frameCommandBuffer, let encoder = frameEncoder else { return }
        encoder.endEncoding()
        if let drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
        frameCommandBuffer = nil
        frameEncoder = nil
    }

    /// Encode one frame into a drawable's render pass and present it.
    func render(
        drawable: any MTLDrawable,
        renderPassDescriptor: MTLRenderPassDescriptor,
        _ body: (GPURenderPass) -> Void
    ) {
        guard let pass = beginFrame(renderPassDescriptor: renderPassDescriptor) else { return }
        body(pass)
        endFrame(present: drawable)
    }
}

final class MetalRenderPass: GPURenderPass {
    private let device: MetalGPUDevice
    private let encoder: any MTLRenderCommandEncoder
    private let targetWidth: Int
    private let targetHeight: Int
    private var transform: [Float] = [
        1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1,
    ]

    init(device: MetalGPUDevice, encoder: any MTLRenderCommandEncoder, targetWidth: Int, targetHeight: Int) {
        self.device = device
        self.encoder = encoder
        self.targetWidth = targetWidth
        self.targetHeight = targetHeight
    }

    public func setTransform(_ matrix: [Double]) {
        transform = matrix.map { Float($0) }
    }

    public func drawTextured(vertices: [Float], texture: GPUTexture) {
        guard vertices.count >= 12, let metalTexture = texture as? MetalTexture else { return }
        encoder.setRenderPipelineState(device.texturedPipeline)
        setVertexData(vertices)
        encoder.setFragmentSamplerState(device.sampler, index: 0)
        encoder.setFragmentTexture(metalTexture.native, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 4)
    }

    public func drawColor(vertices: [Float]) {
        guard vertices.count >= 18 else { return }
        encoder.setRenderPipelineState(device.colorPipeline)
        setVertexData(vertices)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 6)
    }

    public func drawRects(instances: [Float]) {
        let vertices = expandRectInstances(instances)
        guard !vertices.isEmpty else { return }
        encoder.setRenderPipelineState(device.rectPipeline)
        setVertexData(vertices)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count / 12)
    }

    public func setScissor(x: Int, y: Int, width: Int, height: Int) {
        // Metal validates the scissor against the attachment bounds.
        let clampedX = max(0, min(x, targetWidth))
        let clampedY = max(0, min(y, targetHeight))
        let clampedW = max(0, min(width, targetWidth - clampedX))
        let clampedH = max(0, min(height, targetHeight - clampedY))
        encoder.setScissorRect(MTLScissorRect(x: clampedX, y: clampedY, width: clampedW, height: clampedH))
    }

    public func clearScissor() {
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    }

    private func setVertexData(_ vertices: [Float]) {
        let byteCount = vertices.count * MemoryLayout<Float>.size
        if byteCount <= 4096 {
            // Small batches fit setVertexBytes' 4 KB cap.
            vertices.withUnsafeBytes { bytes in
                encoder.setVertexBytes(bytes.baseAddress!, length: byteCount, index: 0)
            }
        } else if let buffer = device.device.makeBuffer(bytes: vertices, length: byteCount) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        }
        transform.withUnsafeBytes { bytes in
            encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 1)
        }
    }
}
