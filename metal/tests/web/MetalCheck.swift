// Isomer's Metal on a browser's WebGPU, end to end: a compute kernel whose
// results come back to the CPU, an offscreen render read back pixel by
// pixel, a texture written with replace(region:) and sampled, SwiftGPU's
// own shaders as pipelines, and a frame drawn to the page's canvas. Each
// check reports "ok …" or "FAIL …"; "done" ends the run
// (tools/metal/run_metal_check.js drives it in headless Chrome).

import IsomerFFI
import IsomerMetalWeb
import Metal

@ExportedInterface
public protocol MetalCheckReporter {
    func report(line: String)
}

nonisolated(unsafe) private var reporter: (any MetalCheckReporter)?
nonisolated(unsafe) private var pending = 0

private func report(_ line: String) {
    reporter?.report(line: line)
}

private func expect(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    report(condition ? "ok \(name)" : "FAIL \(name) \(detail())")
}

private func begin() {
    pending += 1
}

private func end() {
    pending -= 1
    if pending == 0 { report("done") }
}

@ExportedFunction
public func metalCheckRun(reporter newReporter: any MetalCheckReporter) {
    reporter = newReporter
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
        report("FAIL no Metal device")
        report("done")
        return
    }
    report("device \(device.name)")
    begin()
    do {
        try checkCompute(device, queue)
        try checkRender(device, queue)
        try checkTexture(device, queue)
        try checkSwiftGPUShaders(device, queue)
        checkDrawable(device, queue)
    } catch {
        report("FAIL \(error)")
    }
    end()
}

private func checkCompute(_ device: any MTLDevice, _ queue: any MTLCommandQueue) throws {
    let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;

        kernel void add_arrays(device const float* a [[buffer(0)]],
                               device const float* b [[buffer(1)]],
                               device float* result [[buffer(2)]],
                               constant float &scale [[buffer(3)]],
                               uint index [[thread_position_in_grid]]) {
            result[index] = (a[index] + b[index]) * scale;
        }
        """, options: nil)
    guard let function = library.makeFunction(name: "add_arrays") else {
        report("FAIL compute: no function")
        return
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    let count = 1000
    let a = (0..<count).map { Float($0) }
    let b = (0..<count).map { Float($0 * 2) }
    let bufferA = a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    let bufferB = b.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)! }
    let result = device.makeBuffer(length: count * 4, options: .storageModeShared)!
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeComputeCommandEncoder()!
    encoder.setComputePipelineState(pipeline)
    encoder.setBuffer(bufferA, offset: 0, index: 0)
    encoder.setBuffer(bufferB, offset: 0, index: 1)
    encoder.setBuffer(result, offset: 0, index: 2)
    var scale: Float = 0.5
    encoder.setBytes(&scale, length: 4, index: 3)
    encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
    encoder.endEncoding()
    begin()
    commandBuffer.addCompletedHandler { buffer in
        let values = result.contents().bindMemory(to: Float.self, capacity: count)
        var wrong = 0
        for i in 0..<count where values[i] != Float(i) * 1.5 { wrong += 1 }
        expect(wrong == 0, "compute: 1000 sums come back", "\(wrong) wrong, [999] = \(values[999])")
        expect(buffer.status == .completed, "compute: status completed")
        end()
    }
    commandBuffer.commit()
}

private func readPixels(_ texture: any MTLTexture) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    pixels.withUnsafeMutableBytes {
        texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }
    return pixels
}

private func pixel(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> [UInt8] {
    let i = (y * width + x) * 4
    return Array(pixels[i..<i + 4])
}

private func checkRender(_ device: any MTLDevice, _ queue: any MTLCommandQueue) throws {
    let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position [[attribute(0)]];
            float4 color [[attribute(1)]];
        };

        struct VertexOut {
            float4 position [[position]];
            float4 color;
        };

        vertex VertexOut vertex_main(VertexIn in [[stage_in]], constant float2 &offset [[buffer(1)]]) {
            VertexOut out;
            out.position = float4(in.position + offset, 0, 1);
            out.color = in.color;
            return out;
        }

        fragment float4 fragment_main(VertexOut in [[stage_in]]) {
            return in.color;
        }
        """, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "vertex_main")
    descriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    let vertexDescriptor = MTLVertexDescriptor()
    vertexDescriptor.attributes[0].format = .float2
    vertexDescriptor.attributes[0].offset = 0
    vertexDescriptor.attributes[0].bufferIndex = 0
    vertexDescriptor.attributes[1].format = .float4
    vertexDescriptor.attributes[1].offset = 8
    vertexDescriptor.attributes[1].bufferIndex = 0
    vertexDescriptor.layouts[0].stride = 24
    descriptor.vertexDescriptor = vertexDescriptor
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

    // The left half red, over a blue clear.
    let vertices: [Float] = [
        -1, -1, 1, 0, 0, 1,
        0, -1, 1, 0, 0, 1,
        -1, 1, 1, 0, 0, 1,
        0, -1, 1, 0, 0, 1,
        0, 1, 1, 0, 0, 1,
        -1, 1, 1, 0, 0, 1,
    ]
    let vertexBuffer = vertices.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: [])! }
    let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 64, height: 64, mipmapped: false)
    textureDescriptor.usage = [.renderTarget, .shaderRead]
    let target = device.makeTexture(descriptor: textureDescriptor)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 1, alpha: 1)
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
    var offset: (Float, Float) = (0, 0)
    encoder.setVertexBytes(&offset, length: 8, index: 1)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()
    let blit = commandBuffer.makeBlitCommandEncoder()!
    blit.synchronize(resource: target)
    blit.endEncoding()
    begin()
    commandBuffer.addCompletedHandler { _ in
        let pixels = readPixels(target)
        expect(pixel(pixels, 64, 16, 32) == [255, 0, 0, 255], "render: left half red", "\(pixel(pixels, 64, 16, 32))")
        expect(pixel(pixels, 64, 48, 32) == [0, 0, 255, 255], "render: right half the clear color", "\(pixel(pixels, 64, 48, 32))")
        end()
    }
    commandBuffer.commit()
}

private func checkTexture(_ device: any MTLDevice, _ queue: any MTLCommandQueue) throws {
    let library = try device.makeLibrary(source: """
        #include <metal_stdlib>
        using namespace metal;

        struct QuadOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex QuadOut quad_vs(uint vid [[vertex_id]]) {
            float2 p = float2((vid << 1) & 2, vid & 2);
            QuadOut out;
            out.position = float4(p * 2.0 - 1.0, 0, 1);
            out.uv = float2(p.x, 1.0 - p.y);
            return out;
        }

        fragment float4 quad_fs(QuadOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(filter::nearest, address::clamp_to_edge);
            return tex.sample(s, in.uv);
        }
        """, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "quad_vs")
    descriptor.fragmentFunction = library.makeFunction(name: "quad_fs")
    descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

    let source = device.makeTexture(descriptor: .texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false))!
    let texels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
    texels.withUnsafeBytes { source.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 8) }
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
    targetDescriptor.usage = .renderTarget
    let target = device.makeTexture(descriptor: targetDescriptor)!

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentTexture(source, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    let blit = commandBuffer.makeBlitCommandEncoder()!
    blit.synchronize(resource: target)
    blit.endEncoding()
    begin()
    commandBuffer.addCompletedHandler { _ in
        let pixels = readPixels(target)
        expect(pixel(pixels, 4, 0, 0) == [255, 0, 0, 255], "texture: top left red", "\(pixel(pixels, 4, 0, 0))")
        expect(pixel(pixels, 4, 3, 0) == [0, 255, 0, 255], "texture: top right green", "\(pixel(pixels, 4, 3, 0))")
        expect(pixel(pixels, 4, 0, 3) == [0, 0, 255, 255], "texture: bottom left blue", "\(pixel(pixels, 4, 0, 3))")
        expect(pixel(pixels, 4, 3, 3) == [255, 255, 255, 255], "texture: bottom right white", "\(pixel(pixels, 4, 3, 3))")
        end()
    }
    commandBuffer.commit()
}

private let swiftGPUShaders = """
#include <metal_stdlib>
using namespace metal;

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

/// SwiftGPU's rounded-rect pipeline, as its Metal device makes it: a
/// filled rect in the middle of a 32x32 target, read back.
private func checkSwiftGPUShaders(_ device: any MTLDevice, _ queue: any MTLCommandQueue) throws {
    let library = try device.makeLibrary(source: swiftGPUShaders, options: nil)
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "rect_vs")
    descriptor.fragmentFunction = library.makeFunction(name: "rect_fs")
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

    // One rect from (8, 8) to (24, 24) in pixels, radius 2, green; the
    // transform takes pixels to clip space (y down).
    let x: Float = 8, y: Float = 8, w: Float = 16, h: Float = 16
    var vertices: [Float] = []
    for (cx, cy) in [(0, 0), (1, 0), (0, 1), (1, 0), (1, 1), (0, 1)] as [(Float, Float)] {
        vertices += [x + cx * w, y + cy * h, (cx - 0.5) * w, (cy - 0.5) * h, w / 2, h / 2, 2, 0, 0, 1, 0, 1]
    }
    var transform: [Float] = [2.0 / 32, 0, 0, 0, 0, -2.0 / 32, 0, 0, 0, 0, 1, 0, -1, 1, 0, 1]
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 32, height: 32, mipmapped: false)
    targetDescriptor.usage = .renderTarget
    let target = device.makeTexture(descriptor: targetDescriptor)!
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
    transform.withUnsafeMutableBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 1) }
    encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 32, height: 32))
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    encoder.endEncoding()
    let blit = commandBuffer.makeBlitCommandEncoder()!
    blit.synchronize(resource: target)
    blit.endEncoding()
    begin()
    commandBuffer.addCompletedHandler { _ in
        let pixels = readPixels(target)
        // BGRA: green is [0, 255, 0, 255] either way round.
        expect(pixel(pixels, 32, 16, 16) == [0, 255, 0, 255], "SwiftGPU rect: inside green", "\(pixel(pixels, 32, 16, 16))")
        expect(pixel(pixels, 32, 2, 2) == [255, 255, 255, 255], "SwiftGPU rect: outside white", "\(pixel(pixels, 32, 2, 2))")
        end()
    }
    commandBuffer.commit()
}

/// A frame to the page's canvas (surface 1): cleared to a color the page
/// reads back.
private func checkDrawable(_ device: any MTLDevice, _ queue: any MTLCommandQueue) {
    let layer = IsomerMetalLayer()
    layer.device = device
    guard let drawable = layer.nextDrawable() else {
        report("FAIL drawable: none")
        return
    }
    expect(drawable.texture.width == layer.drawableSize.width, "drawable: the canvas's size")
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = drawable.texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 0.5, blue: 0, alpha: 1)
    let commandBuffer = queue.makeCommandBuffer()!
    let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
    report("drawn canvas")
}
