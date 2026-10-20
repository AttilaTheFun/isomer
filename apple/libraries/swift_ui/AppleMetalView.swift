// MetalView on Apple platforms: an MTKView, drawn every frame, whose
// delegate hands the app's closure the same frame the web's MetalView does
// (device, command queue, drawable, render pass descriptor), so one view
// source draws with Apple's Metal here and Isomer's elsewhere.

import MetalKit
import SwiftUI

/// One frame of a MetalView: what an MTKView's delegate reads from the view.
public struct MetalViewFrame {
    public let device: any MTLDevice
    /// The view's queue (one per view).
    public let commandQueue: any MTLCommandQueue
    public let currentDrawable: any MTLDrawable
    /// The drawable's texture (the first color attachment).
    public let texture: any MTLTexture
    /// Clears the drawable to the view's clear color, and stores.
    public let currentRenderPassDescriptor: MTLRenderPassDescriptor
    /// In pixels.
    public let drawableSize: CGSize
}

public struct MetalView {
    private let device: (any MTLDevice)?
    private let colorPixelFormat: MTLPixelFormat
    private let clearColor: MTLClearColor
    private let draw: (MetalViewFrame) -> Void

    /// `draw` is called for every frame, as `MTKViewDelegate.draw(in:)` is.
    public init(
        device: (any MTLDevice)? = nil,
        colorPixelFormat: MTLPixelFormat = .bgra8Unorm,
        clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1),
        draw: @escaping (MetalViewFrame) -> Void
    ) {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
        self.clearColor = clearColor
        self.draw = draw
    }

    public final class Coordinator: NSObject, MTKViewDelegate {
        var draw: (MetalViewFrame) -> Void
        private var queue: (any MTLCommandQueue)?

        init(draw: @escaping (MetalViewFrame) -> Void) {
            self.draw = draw
        }

        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        public func draw(in view: MTKView) {
            guard let device = view.device, let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            if queue == nil { queue = device.makeCommandQueue() }
            guard let queue else { return }
            draw(MetalViewFrame(
                device: device, commandQueue: queue, currentDrawable: drawable, texture: drawable.texture,
                currentRenderPassDescriptor: descriptor, drawableSize: view.drawableSize))
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(draw: draw)
    }

    private func makeMetalView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device ?? MTLCreateSystemDefaultDevice())
        view.delegate = context.coordinator
        updateMetalView(view, context: context)
        return view
    }

    private func updateMetalView(_ view: MTKView, context: Context) {
        context.coordinator.draw = draw
        view.colorPixelFormat = colorPixelFormat
        view.clearColor = clearColor
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension MetalView: NSViewRepresentable {
    public func makeNSView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    public func updateNSView(_ view: MTKView, context: Context) {
        updateMetalView(view, context: context)
    }
}
#else
extension MetalView: UIViewRepresentable {
    public func makeUIView(context: Context) -> MTKView {
        makeMetalView(context: context)
    }

    public func updateUIView(_ view: MTKView, context: Context) {
        updateMetalView(view, context: context)
    }
}
#endif
