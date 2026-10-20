// `GPUTreeView`: a UIView that draws a wasm feature's render tree (tree.fbs
// patches) with the self-drawing SwiftGPU renderer over Metal — the iOS
// Playground's "Metal" renderer for a run, the alternative to real SwiftUI
// (`IsomerTreeView`). This module compiles the SwiftUI *reimplementation*
// core (Runtime / SwiftGPURenderer / the tree decoder), whose type names
// clash with real SwiftUI: importers use a scoped import
// (`import class IsomerGPUTreeView.GPUTreeView`) so nothing else leaks.
//
// One at a time: the core's `Runtime.shared` is a process singleton, so a
// second live GPUTreeView would share its layout state.

import Foundation
import SwiftGPU
import UIKit

@MainActor
public final class GPUTreeView: UIView {
    /// Events the drawn tree raises (taps, edits) — forward to the feature.
    public var onEvent: ((String, String) -> Void)?

    private var surfaceView: GPUSurfaceView?
    private var surface: MetalRendererSurface?
    private var renderer: SwiftGPURenderer?
    private var decoder: FlatTreeDecoder?
    private var latestTree: RenderNode?
    private var pendingBytes: [[UInt8]] = []
    private var started = false

    public override init(frame: CoreFoundation.CGRect) {
        super.init(frame: frame)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        guard let device = MetalGPUDevice() else { NSLog("[gpu-tree] no Metal device"); return }
        let services = GPUTreeServicesHost()
        services.onScheduleRender = { [weak self] in self?.scheduleRender() }
        let surface = MetalRendererSurface(device: device)
        let renderer = SwiftGPURenderer(services: services, surface: surface)
        Renderer.bind(renderer)
        self.surface = surface
        self.renderer = renderer
        decoder = FlatTreeDecoder { [weak self] id, value in self?.onEvent?(id, value) }

        let surfaceView = device.makeSurfaceView()
        surfaceView.clear = GPUColor(red: 0.98, green: 0.98, blue: 0.98)
        surfaceView.frame = bounds
        surfaceView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surfaceView.onDraw = { [weak self] pass, width, height in
            self?.drawFrame(pass: pass, width: width, height: height)
        }
        addSubview(surfaceView)
        self.surfaceView = surfaceView
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let renderer else { return }
        let width = Double(bounds.width), height = Double(bounds.height)
        guard width > 0, height > 0 else { return }
        if !started {
            started = true
            // The runtime is only the layout/draw walker here; the tree
            // comes from the feature's patches.
            Runtime.shared.start(host: renderer, width: width, height: height)
        } else {
            Runtime.shared.resize(width: width, height: height)
        }
        scheduleRender()
    }

    /// One tree.fbs Patch from the feature, in arrival order (never coalesce:
    /// each is a delta against the retained tree).
    public func apply(patch: [UInt8]) {
        pendingBytes.append(patch)
        scheduleRender()
    }

    /// The host's appearance: the runtime's palette (window background,
    /// chrome) must match the scheme the feature resolved its colors in.
    public func setColorScheme(dark: Bool) {
        Runtime.shared.setSystemColorScheme(dark: dark)
        surfaceView?.clear = dark
            ? GPUColor(red: 0.07, green: 0.07, blue: 0.08)
            : GPUColor(red: 0.98, green: 0.98, blue: 0.98)
        scheduleRender()
    }

    /// A reloaded feature starts from an empty tree.
    public func reset() {
        pendingBytes = []
        latestTree = nil
        scheduleRender()
    }

    public func scheduleRender() {
        surfaceView?.setNeedsRender()
    }

    private func drawFrame(pass: GPURenderPass, width: Double, height: Double) {
        guard let surface, let renderer, let decoder else { return }
        if !pendingBytes.isEmpty {
            let queued = pendingBytes
            pendingBytes = []
            for bytes in queued {
                latestTree = decoder.applyPatch(bytes: bytes, to: latestTree)
            }
        }
        guard let tree = latestTree else { return }
        if ProcessInfo.processInfo.environment["ISO_GPU_TREE_DEBUG"] != nil {
            func dump(_ n: RenderNode, _ depth: Int) -> String {
                var line = String(repeating: " ", count: depth * 2) + String(describing: n.kind).prefix(60) + " f=\(Int(n.frame.origin.x)),\(Int(n.frame.origin.y)) \(Int(n.frame.size.width))x\(Int(n.frame.size.height))"
                if depth < 4 { for c in n.children.prefix(6) { line += "\n" + dump(c, depth + 1) } }
                return line
            }
            NSLog("[gpu-tree] tree:\n%@", dump(tree, 0))
        }
        surface.currentPass = pass
        renderer.beginFrame(width: width, height: height)
        renderer.render(tree: tree)
        renderer.endFrame()
        surface.currentPass = nil
    }

    // Touches → the runtime's hit-testing of the drawn tree.
    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 0) }
    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 2) }
    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 1) }
    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, kind: 1) }

    private func forward(_ touches: Set<UITouch>, kind: Int) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        Runtime.shared.pointerEvent(kind: kind, x: Double(point.x), y: Double(point.y))
        scheduleRender()
    }
}

/// Bridges the callback-style `GPUSurfaceView` (a pass per `draw`) to the
/// `SwiftGPURendererSurface` pull model.
final class MetalRendererSurface: SwiftGPURendererSurface {
    let gpuDevice: MetalGPUDevice
    var displayScale: Double = Double(UIScreen.main.scale)
    var currentPass: GPURenderPass?

    init(device: MetalGPUDevice) { gpuDevice = device }

    var device: GPUDevice { gpuDevice }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? { currentPass }

    func endFrame() {}
}
