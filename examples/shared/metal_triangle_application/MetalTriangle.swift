// A triangle drawn with Metal, turning: one SwiftUI source that draws with
// Apple's Metal on iOS and macOS (MetalView wraps an MTKView) and with
// Isomer's Metal in a browser (MetalView's canvas, WebGPU underneath, the
// shaders translated to WGSL when the library is made).

import Isomer
import Metal
import SwiftUI

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float4 color;
};

vertex VertexOut triangle_vs(uint vid [[vertex_id]], constant float &angle [[buffer(0)]]) {
    float2 corners[3] = { float2(0.0, 0.8), float2(-0.7, -0.6), float2(0.7, -0.6) };
    float4 colors[3] = { float4(1.0, 0.25, 0.3, 1.0), float4(0.2, 0.85, 0.4, 1.0), float4(0.25, 0.45, 1.0, 1.0) };
    float2 p = corners[vid];
    float c = cos(angle), s = sin(angle);
    VertexOut out;
    out.position = float4(p.x * c - p.y * s, p.x * s + p.y * c, 0.0, 1.0);
    out.color = colors[vid];
    return out;
}

fragment float4 triangle_fs(VertexOut in [[stage_in]]) {
    return in.color;
}
"""

/// The pipeline (made once a device is known) and the turn so far.
final class TriangleRenderer {
    nonisolated(unsafe) static let shared = TriangleRenderer()

    private var pipeline: (any MTLRenderPipelineState)?
    private var angle: Float = 0

    func draw(_ frame: MetalViewFrame) {
        if pipeline == nil {
            do {
                let library = try frame.device.makeLibrary(source: shaderSource, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "triangle_vs")
                descriptor.fragmentFunction = library.makeFunction(name: "triangle_fs")
                descriptor.colorAttachments[0].pixelFormat = frame.texture.pixelFormat
                pipeline = try frame.device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                print("Metal: \(error)")
                return
            }
        }
        guard let pipeline, let commandBuffer = frame.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: frame.currentRenderPassDescriptor) else { return }
        angle += 0.02
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&angle, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(frame.currentDrawable)
        commandBuffer.commit()
    }
}

struct MetalTriangleView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Drawn with Metal")
                .font(.headline)
            MetalView(clearColor: MTLClearColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)) { frame in
                TriangleRenderer.shared.draw(frame)
            }
            .frame(height: 320)
            .cornerRadius(12)
            Text("The same Swift source and shader on Apple's Metal and, in a browser, on Isomer's over WebGPU.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

@main
struct MetalTriangleApplication: App {
    var body: some Scene {
        WindowGroup("Metal") {
            MetalTriangleView()
        }
    }
}
