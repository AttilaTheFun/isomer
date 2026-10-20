// The SwiftGPU renderer: ONE self-drawing `TreeRenderer` for every
// platform, replacing the per-platform WebGPU/OpenGL/Direct2D
// implementations. It wraps the platform's `HostBridge` (the "services"
// half: text measurement, rasterization, IME, files, host views) and
// implements the drawing half itself through SwiftGPU — shapes with the
// SDF rect pipeline, text/images/gradients/shadows as host-rasterized
// RGBA textures, clips as scissors.
//
// This file is (with the map's MapSceneRenderer in swift_map) the only
// `import SwiftGPU` in the ecosystem; it only compiles on platforms whose
// bridge links swift_gpu (canImport is false elsewhere).

#if canImport(SwiftGPU)

import SwiftGPU
package import IsomerSwiftUI
#if os(WASI) && canImport(Metal)
import Metal
#endif
#if canImport(SwiftMap)
import SwiftMap
#endif

/// The device half each platform bridge supplies (MetalGPUDevice over
/// Isomer's Metal on wasm, GLESGPUDevice on Android) plus its per-frame
/// scale factor.
package protocol SwiftGPURendererSurface: AnyObject {
    /// Open a frame; the renderer draws into the returned pass.
    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass?
    /// Present the frame opened by `beginFrame`.
    func endFrame()
    var device: GPUDevice { get }
    /// Device pixels per logical point (for scissor rects).
    var displayScale: Double { get }
}

package final class SwiftGPURenderer: HostBridge, TreeRenderer {
    // MARK: - TreeRenderer

    /// Self-drawing renderers own the entire surface, so they are app-only —
    /// they cannot be embedded in a host's native view hierarchy.
    public let supportedModes: Set<IntegrationMode> = [.app]

    /// Self-drawing: there are no platform navigation components to map to —
    /// the guest expands its own drawn chrome (bar, large title,
    /// transitions), consistent across every GPU backend.
    public let semanticNavigation = false

    /// Self-drawing: lay the tree out and draw every pixel through
    /// SwiftGPU (chrome included), via the runtime's layout+draw walk —
    /// which arrives back here through the HostBridge drawing surface.
    @MainActor
    public func render(tree: RenderNode) {
        Runtime.shared.drawTree(root: tree)
    }

    private let services: HostBridge
    private let surface: SwiftGPURendererSurface

    private var pass: GPURenderPass?
    private var frameWidth: Double = 0
    private var frameHeight: Double = 0

    // Pending SDF rect instances, flushed before any other draw or state
    // change so paint order holds.
    private var pendingRects: [Float] = []

    // Transform stack: affine (a,b,c,d,e,f) rows composed over the base
    // NDC mapping.
    private var transformStack: [(Double, Double, Double, Double, Double, Double)] = []
    private var clipStack: [CGRect] = []

    // Host-rasterized textures (text runs, gradients, shadows, images),
    // keyed by their spec; evicted LRU beyond the budget.
    private var rasterCache: [String: GPUTexture] = [:]
    private var rasterOrder: [String] = []
    private let rasterBudget = 512

    #if canImport(SwiftMap)
    // One SwiftMap engine + scene per `Map` node (keyed by the node's
    // identity path); tiles ride the services bridge's image machinery.
    private var mapStates: [String: MapHostState] = [:]
    #endif

    public init(services: HostBridge, surface: SwiftGPURendererSurface) {
        self.services = services
        self.surface = surface
    }

    // MARK: - Frame lifecycle

    public func beginFrame(width: Double, height: Double) {
        frameWidth = width
        frameHeight = height
        transformStack = []
        clipStack = []
        pendingRects = []
        pass = surface.beginFrame(
            clear: GPUColor(red: 0.98, green: 0.98, blue: 0.98),
            width: width,
            height: height
        )
        pass?.setTransform(currentMatrix())
    }

    public func endFrame() {
        flushRects()
        pass = nil
        surface.endFrame()
    }

    // MARK: - Transform / clip state

    private func currentMatrix() -> [Double] {
        // Base: logical points -> NDC (y down -> y up).
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0, e = 0.0, f = 0.0
        for t in transformStack {
            // Compose row-major affine: current = current * t.
            let (ta, tb, tc, td, te, tf) = t
            let na = a * ta + c * tb
            let nb = b * ta + d * tb
            let nc = a * tc + c * td
            let nd = b * tc + d * td
            let ne = a * te + c * tf + e
            let nf = b * te + d * tf + f
            a = na; b = nb; c = nc; d = nd; e = ne; f = nf
        }
        let sx = 2.0 / max(frameWidth, 1)
        let sy = -2.0 / max(frameHeight, 1)
        // Column-major 4x4: clip = ortho * affine * point.
        return [
            a * sx, b * sy, 0, 0,
            c * sx, d * sy, 0, 0,
            0, 0, 0, 0,
            e * sx - 1, f * sy + 1, 0, 1,
        ]
    }

    public func pushTransform(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {
        flushRects()
        transformStack.append((a, b, c, d, e, f))
        pass?.setTransform(currentMatrix())
    }

    public func popTransform() {
        flushRects()
        if !transformStack.isEmpty { transformStack.removeLast() }
        pass?.setTransform(currentMatrix())
    }

    public func pushClip(_ rect: CGRect, cornerRadius: Double) {
        flushRects()
        // Axis-aligned scissor (the same approximation the per-platform
        // renderers used); intersect with the current clip.
        let clip = clipStack.last.map { $0.clipped(to: rect) } ?? rect
        clipStack.append(clip)
        applyScissor()
    }

    public func popClip() {
        flushRects()
        if !clipStack.isEmpty { clipStack.removeLast() }
        applyScissor()
    }

    private func applyScissor() {
        guard let pass else { return }
        if let clip = clipStack.last {
            let scale = surface.displayScale
            pass.setScissor(
                x: Int(clip.minX * scale),
                y: Int(clip.minY * scale),
                width: Int(clip.width * scale),
                height: Int(clip.height * scale)
            )
        } else {
            pass.clearScissor()
        }
    }

    // MARK: - Shapes (SDF rect pipeline)

    public func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor) {
        appendRect(rect, cornerRadius: cornerRadius, border: 0, color: color)
    }

    public func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor) {
        appendRect(rect, cornerRadius: cornerRadius, border: lineWidth, color: color)
    }

    private func appendRect(_ rect: CGRect, cornerRadius: Double, border: Double, color: HostColor) {
        // A sentinel radius (fully rounded) clamps to the half-size.
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)
        pendingRects += [
            Float(rect.minX), Float(rect.minY), Float(rect.width), Float(rect.height),
            Float(radius), Float(border),
            Float(color.red), Float(color.green), Float(color.blue), Float(color.opacity),
            0,
        ]
    }

    private func flushRects() {
        guard !pendingRects.isEmpty, let pass else { return }
        pass.drawRects(instances: pendingRects)
        pendingRects = []
    }

    // MARK: - Rasterized content (host raster -> texture -> quad)

    public func drawText(_ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor) {
        let spec = "{\"kind\":\"text\",\"text\":\"\(jsonEscapedGPU(text))\",\"size\":\(fontSize),\"weight\":\(weight)"
            + ",\"wrap\":\(rect.width),\"r\":\(color.red),\"g\":\(color.green),\"b\":\(color.blue),\"a\":\(color.opacity)}"
        flushRects()
        guard let pass, let texture = rasterTexture(spec: spec) else { return }
        // The raster is the text's natural size, which can differ from the
        // frame: narrower (a placeholder in a wide field — draw leading-
        // aligned, vertically centered) or taller (wrapped lines capped by
        // .lineLimit — top-align and clip to the frame, exactly like the
        // per-platform renderers' hard text clip). Never stretch.
        let scale = max(surface.displayScale, 0.001)
        let textWidth = Double(texture.width) / scale
        let textHeight = Double(texture.height) / scale
        let overflows = textHeight > rect.height + 0.5 || textWidth > rect.width + 0.5
        let offsetY = textHeight <= rect.height ? (rect.height - textHeight) / 2 : 0
        let dest = CGRect(
            x: rect.minX,
            y: rect.minY + offsetY,
            width: textWidth,
            height: textHeight
        )
        if overflows { pushClip(rect, cornerRadius: 0) }
        pass.drawTextured(vertices: quadVertices(dest), texture: texture)
        if overflows { popClip() }
    }

    public func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String) {
        let spec = "{\"kind\":\"gradient\",\"w\":\(rect.width),\"h\":\(rect.height)"
            + ",\"radius\":\(cornerRadius),\"gradient\":\(gradientJSON)}"
        drawRaster(spec: spec, in: rect)
    }

    public func drawShadow(_ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double) {
        // The raster includes the blur margin; draw it around the rect.
        let margin = radius * 2
        let spec = "{\"kind\":\"shadow\",\"w\":\(rect.width),\"h\":\(rect.height),\"corner\":\(cornerRadius)"
            + ",\"blur\":\(radius),\"r\":\(color.red),\"g\":\(color.green),\"b\":\(color.blue),\"a\":\(color.opacity)}"
        let dest = CGRect(
            x: rect.minX - margin + x,
            y: rect.minY - margin + y,
            width: rect.width + margin * 2,
            height: rect.height + margin * 2
        )
        drawRaster(spec: spec, in: dest)
    }

    public func drawImage(
        _ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect,
        cornerRadius: Double, opacity: Double
    ) {
        flushRects()
        guard let pass else { return }
        let spec = "{\"kind\":\"image\",\"source\":\"\(jsonEscapedGPU(source))\",\"remote\":\(isRemote)}"
        guard let texture = rasterTexture(spec: spec) else { return }
        // Clip via scissor while this quad draws (rounded corners
        // approximated, as before).
        pushClip(clip, cornerRadius: cornerRadius)
        pass.drawTextured(vertices: quadVertices(dest), texture: texture)
        popClip()
    }

    private func drawRaster(spec: String, in rect: CGRect) {
        flushRects()
        guard let pass, let texture = rasterTexture(spec: spec) else { return }
        pass.drawTextured(vertices: quadVertices(rect), texture: texture)
    }

    /// Fetch (or rasterize + cache) the texture for a raster spec. The host
    /// returns [width u32 LE][height u32 LE][rgba…]; empty means "not ready"
    /// (e.g. an image still loading — the host re-renders when it lands).
    private func rasterTexture(spec: String) -> GPUTexture? {
        if let cached = rasterCache[spec] {
            return cached
        }
        let payload = services.rasterize(spec)
        guard payload.count > 8 else { return nil }
        let width = Int(payload[0]) | Int(payload[1]) << 8 | Int(payload[2]) << 16 | Int(payload[3]) << 24
        let height = Int(payload[4]) | Int(payload[5]) << 8 | Int(payload[6]) << 16 | Int(payload[7]) << 24
        guard width > 0, height > 0, payload.count >= 8 + width * height * 4 else { return nil }
        let texture = surface.device.makeTexture(width: width, height: height, rgba: Array(payload[8...]))
        rasterCache[spec] = texture
        rasterOrder.append(spec)
        if rasterOrder.count > rasterBudget {
            let evicted = rasterOrder.removeFirst()
            if let texture = rasterCache.removeValue(forKey: evicted) {
                surface.device.destroyTexture(texture)
            }
        }
        return texture
    }

    private func quadVertices(_ rect: CGRect) -> [Float] {
        let x0 = Float(rect.minX)
        let y0 = Float(rect.minY)
        let x1 = Float(rect.maxX)
        let y1 = Float(rect.maxY)
        return [
            x0, y0, 0, 0, x1, y0, 1, 0, x0, y1, 0, 1,
            x1, y0, 1, 0, x1, y1, 1, 1, x0, y1, 0, 1,
        ]
    }

    // MARK: - Forwarded services

    public func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        services.measureText(text, fontSize: fontSize, weight: weight, wrapWidth: wrapWidth)
    }

    public func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        services.imageInfo(source, isRemote: isRemote)
    }

    public func syncHostViews(_ viewsJSON: String) { services.syncHostViews(viewsJSON) }
    public func beginHostViewSync() { services.beginHostViewSync() }
    public func syncWebView(id: String, url: String, frame: CGRect) { services.syncWebView(id: id, url: url, frame: frame) }
    public func syncNativeControl(id: String, kind: String, value: String, options: [String], frame: CGRect) {
        services.syncNativeControl(id: id, kind: kind, value: value, options: options, frame: frame)
    }
    public func endHostViewSync() { services.endHostViewSync() }
    public func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {
        services.beginTextInput(text, in: rect, fontSize: fontSize)
    }
    public func endTextInput() { services.endTextInput() }
    public func scheduleRender() { services.scheduleRender() }
    public func now() -> Double { services.now() }
    public func setColorScheme(dark: Bool) { services.setColorScheme(dark: dark) }
    public func log(_ message: String) { services.log(message) }
    public func openURL(_ url: String) { services.openURL(url) }
    public func platformCommand(_ key: String, _ value: String) { services.platformCommand(key, value) }

    // MARK: - SwiftMap tile scenes (the `Map` view's host renderer)

    public func drawHostView(
        id: String, kind: String, value: String, params: [String: String], in rect: CGRect
    ) -> Bool {
        #if os(WASI) && canImport(Metal)
        if kind == "metal" {
            return drawMetalView(token: value, rect: rect)
        }
        #endif
        #if canImport(SwiftMap)
        guard kind == "map" else { return false }
        drawMap(id: id, cameraCSV: value, params: params, rect: rect)
        return true
        #else
        return false
        #endif
    }

    // Isomer's Metal under SwiftGPU's Metal device: the web (an Apple host's
    // MetalView is an MTKView; GLES builds of this file have no Metal).
    #if os(WASI) && canImport(Metal)
    /// Draws a `MetalView`'s frame (Isomer's module renders it into a
    /// texture on this device; `token` is the view's) into the node's rect.
    /// Set by the Isomer module where SwiftGPU runs on Metal.
    public nonisolated(unsafe) static var metalViewFrame: ((_ token: String, _ width: Int, _ height: Int) -> (any MTLTexture)?)?

    private func drawMetalView(token: String, rect: CGRect) -> Bool {
        guard let pass, let device = surface.device as? MetalGPUDevice, let frame = Self.metalViewFrame else { return false }
        let scale = surface.displayScale
        guard let texture = frame(token, Int((rect.width * scale).rounded()), Int((rect.height * scale).rounded())) else {
            return false
        }
        flushRects()
        let quad: [Float] = [
            Float(rect.minX), Float(rect.minY), 0, 0,
            Float(rect.maxX), Float(rect.minY), 1, 0,
            Float(rect.minX), Float(rect.maxY), 0, 1,
            Float(rect.maxX), Float(rect.minY), 1, 0,
            Float(rect.maxX), Float(rect.maxY), 1, 1,
            Float(rect.minX), Float(rect.maxY), 0, 1,
        ]
        pass.drawTextured(vertices: quad, texture: device.makeTexture(wrapping: texture))
        // A Metal view draws every frame, as MTKView does by default.
        services.scheduleRender()
        return true
    }
    #endif

    #if canImport(SwiftMap)
    private func drawMap(id: String, cameraCSV: String, params: [String: String], rect: CGRect) {
        guard let pass, rect.width > 1, rect.height > 1 else { return }
        flushRects()

        let state: MapHostState
        if let existing = mapStates[id] {
            state = existing
        } else {
            state = MapHostState(device: surface.device, services: services)
            mapStates[id] = state
        }

        // Camera: the app's binding wins whenever its value changes (the
        // engine's own clamping must not fight an unchanged binding, so the
        // last-applied CSV is the comparison key, not the camera).
        if cameraCSV != state.lastCameraCSV {
            state.lastCameraCSV = cameraCSV
            let parts = cameraCSV.split(separator: ",").compactMap { Double($0) }
            if parts.count == 5 {
                state.engine.camera = SwiftMap.MapCamera(
                    latitude: parts[0], longitude: parts[1], zoom: parts[2],
                    bearing: parts[3], tilt: parts[4]
                )
            }
        }
        if let spec = params["annotations"], spec != state.lastAnnotations {
            state.lastAnnotations = spec
            state.engine.setAnnotations(spec: spec)
        }
        if let spec = params["polygons"], spec != state.lastPolygons {
            state.lastPolygons = spec
            state.engine.setPolygons(spec: spec)
        }
        if let spec = params["polylines"], spec != state.lastPolylines {
            state.lastPolylines = spec
            state.engine.setPolylines(spec: spec)
        }

        state.engine.resize(width: rect.width, height: rect.height)
        state.pollTiles()
        let frame = state.engine.buildFrame()

        // Draw the scene into this node's rect: scissor to it (respecting
        // the current clip) and remap the frame's viewport-NDC matrices into
        // the rect's corner of the target.
        let scale = surface.displayScale
        let clip = clipStack.last.map { $0.clipped(to: rect) } ?? rect
        pass.setScissor(
            x: Int(clip.minX * scale),
            y: Int(clip.minY * scale),
            width: Int(max(clip.width, 0) * scale),
            height: Int(max(clip.height, 0) * scale)
        )
        let region = RegionRenderPass(
            pass: pass, targetWidth: frameWidth, targetHeight: frameHeight, rect: rect)
        state.scene.draw(frame: frame, into: region)

        // Restore the UI renderer's state.
        applyScissor()
        pass.setTransform(currentMatrix())
    }
    #endif
}

#if canImport(SwiftMap)

/// The engine-host half of one `Map` node: SwiftMap decides what to fetch
/// and when to redraw; tiles are fetched and decoded through the services
/// bridge's existing image machinery (`imageInfo` starts the download,
/// `rasterize` returns the pixels — polled each frame until ready).
private final class MapHostState: SwiftMap.MapEngineHost {
    let engine: SwiftMap.MapEngine
    let scene: SwiftMap.MapSceneRenderer
    let services: HostBridge
    var pending: [SwiftMap.TileKey: String] = [:]
    var lastCameraCSV = ""
    var lastAnnotations = ""
    var lastPolygons = ""
    var lastPolylines = ""

    init(device: GPUDevice, services: HostBridge) {
        engine = SwiftMap.MapEngine()
        scene = SwiftMap.MapSceneRenderer(device: device)
        self.services = services
        engine.host = self
    }

    // MARK: MapEngineHost

    func requestTile(key: SwiftMap.TileKey, url: String) {
        pending[key] = url
        // Starts the download; completion arrives through the host's image
        // drain, which schedules a render — pollTiles picks it up then.
        _ = services.imageInfo(url, isRemote: true)
    }

    func evictTile(key: SwiftMap.TileKey) {
        scene.removeTexture(forKey: key.id)
    }

    func setNeedsRender() {
        services.scheduleRender()
    }

    /// Resolve pending tiles whose bytes have arrived: decode through the
    /// raster service and hand the texture to the scene. (Tiles are opaque,
    /// so the service's premultiplied output is also valid straight alpha.)
    func pollTiles() {
        guard !pending.isEmpty else { return }
        for (key, url) in pending {
            switch services.imageInfo(url, isRemote: true) {
            case .loading:
                continue
            case .failed:
                pending[key] = nil
                engine.tileFailed(key: key)
            case .ready:
                let payload = services.rasterize(
                    "{\"kind\":\"image\",\"source\":\"\(url)\",\"remote\":true}")
                guard payload.count > 8 else {
                    pending[key] = nil
                    engine.tileFailed(key: key)
                    continue
                }
                let width = Int(payload[0]) | Int(payload[1]) << 8
                    | Int(payload[2]) << 16 | Int(payload[3]) << 24
                let height = Int(payload[4]) | Int(payload[5]) << 8
                    | Int(payload[6]) << 16 | Int(payload[7]) << 24
                guard width > 0, height > 0, payload.count >= 8 + width * height * 4 else {
                    pending[key] = nil
                    engine.tileFailed(key: key)
                    continue
                }
                scene.setTexture(
                    rgba: Array(payload[8...]), width: width, height: height, forKey: key.id)
                pending[key] = nil
                engine.tileLoaded(key: key)
            }
        }
    }
}

/// Wraps the UI pass so SwiftMap's viewport-relative clip-space matrices
/// land in one node's rect of the full render target: with `S` scaling NDC
/// by (rect.w/W, rect.h/H) and translating to the rect's center, transforms
/// become `S * M` (the `w` term keeps tilt perspective-correct).
private final class RegionRenderPass: GPURenderPass {
    private let pass: GPURenderPass
    private let scaleX: Double
    private let scaleY: Double
    private let offsetX: Double
    private let offsetY: Double

    init(pass: GPURenderPass, targetWidth: Double, targetHeight: Double, rect: CGRect) {
        self.pass = pass
        let width = max(targetWidth, 1)
        let height = max(targetHeight, 1)
        scaleX = rect.width / width
        scaleY = rect.height / height
        offsetX = 2 * rect.midX / width - 1
        offsetY = 1 - 2 * rect.midY / height
    }

    func setTransform(_ matrix: [Double]) {
        guard matrix.count == 16 else { return }
        var out = matrix
        for column in 0..<4 {
            let x = matrix[column * 4]
            let y = matrix[column * 4 + 1]
            let w = matrix[column * 4 + 3]
            out[column * 4] = scaleX * x + offsetX * w
            out[column * 4 + 1] = scaleY * y + offsetY * w
        }
        pass.setTransform(out)
    }

    func drawTextured(vertices: [Float], texture: GPUTexture) {
        pass.drawTextured(vertices: vertices, texture: texture)
    }

    func drawColor(vertices: [Float]) { pass.drawColor(vertices: vertices) }
    func drawRects(instances: [Float]) { pass.drawRects(instances: instances) }
    func setScissor(x: Int, y: Int, width: Int, height: Int) {
        pass.setScissor(x: x, y: y, width: width, height: height)
    }
    func clearScissor() { pass.clearScissor() }
}

#endif

private func jsonEscapedGPU(_ text: String) -> String {
    var out = ""
    for character in text {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        default: out.append(character)
        }
    }
    return out
}

#endif
