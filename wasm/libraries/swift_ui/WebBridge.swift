// The web host bridge, expressed as a swift_ffi surface.
//
// JavaScript implements `WebHost` (a plain object literal) and passes it into
// `isoStart`; Swift calls back out through the generated foreign proxy, and
// the browser drives the runtime through the exported functions. This
// replaces the hand-written `@_extern(wasm, …)` imports, `@_cdecl` exports,
// and staging-buffer plumbing that previously carried the same surface.

package import IsomerFFI
internal import IsomerNetworkHost

#if canImport(SwiftGPU)
import SwiftGPU
#endif

@ExportedStruct
package struct TextMetrics {
    public let width: Double
    public let height: Double
}

@ExportedStruct
package struct ImageInfoValue {
    /// 0 loading, 1 ready, 2 failed.
    public let state: Int32
    public let width: Double
    public let height: Double
}

/// The browser side of the host bridge. Under the SwiftGPURenderer drawing
/// stays in Swift and this object supplies services (measurement,
/// rasterization, IME, host views); under the ReactRenderer it receives the
/// serialized tree through `renderTree`.
@ExportedInterface
package protocol WebHost {
    func measureText(text: String, fontSize: Double, weight: Int32, wrapWidth: Double) -> TextMetrics
    func imageInfo(source: String, isRemote: Bool) -> ImageInfoValue
    // Drawing is SwiftGPURenderer's job (it draws every pixel through swift_gpu's
    // WebGPU backend); the host only supplies the services below. The old
    // host-canvas drawing methods were removed with HostDrawnRenderer.
    func syncHostViews(viewsJSON: String)
    func beginTextInput(text: String, x: Double, y: Double, width: Double, height: Double, fontSize: Double)
    func endTextInput()
    func scheduleRender()
    func setColorScheme(dark: Bool)
    func now() -> Double
    /// Rasterize content for the SwiftGPU renderer (spec JSON in, [w u32]
    /// [h u32][RGBA8...] out; empty when unavailable).
    func rasterize(spec: String) -> [UInt8]
    func log(message: String)
    func openURL(url: String)
    func platformCommand(key: String, value: String)
    func epochMillis() -> Double
    /// ReactRenderer path: render the serialized view tree (the tree.fbs
    /// FlatBuffer) as React components. Unused under the SwiftGPURenderer.
    func renderTree(tree: [UInt8])
    /// An encoded picture's bytes for `source` (`IsomerImages`): the browser
    /// keeps them as a Blob and draws it by its object URL; empty bytes
    /// forget it.
    func registerImage(source: String, bytes: [UInt8])
}

/// The active host, installed by `isoStart`. The generated foreign proxy
/// retains the JavaScript object for as long as Swift holds this reference.
nonisolated(unsafe) var webHost: (any WebHost)?

/// Display name of the renderer `isoStart` bound (for the System screen).
package nonisolated(unsafe) var _boundRendererName = "None"

/// Bridge calls shared with the IsomerBridge module.
package enum _WebBridgeCalls {
    public static func log(_ message: String) { webHost?.log(message: message) }
    public static func openURL(_ url: String) { webHost?.openURL(url: url) }
    public static func epochMilliseconds() -> Int64 {
        Int64(webHost?.epochMillis() ?? 0)
    }
}

// MARK: - Exports (JavaScript -> Swift)

// The app's synthesized @main entry point, run once to install the App into
// the Runtime (the reactor is linked without a command _start). On wasm32 the
// two-argument C `main` is mangled to `__main_argc_argv`.
@_extern(c, "__main_argc_argv")
func _application_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

#if canImport(SwiftGPU)
/// The SwiftGPU surface for the web: SwiftGPU's Metal device over Isomer's
/// Metal, drawing into the page's canvas (the page connects Isomer's Metal
/// executor with `metalHost.connect(bridge)` before `isoStart`).
final class WebGPURendererSurface: SwiftGPURendererSurface {
    private lazy var surface: MetalWebSurface = {
        guard let surface = MetalWebSurface() else {
            fatalError("no Metal device: the page connects Isomer's Metal executor before drawing")
        }
        return surface
    }()
    var displayScale: Double = 1
    var device: GPUDevice { surface.device }

    func beginFrame(clear: GPUColor, width: Double, height: Double) -> GPURenderPass? {
        surface.beginFrame(clear: clear)
    }

    func endFrame() {
        surface.endFrame()
    }
}

nonisolated(unsafe) var gpuSurface: WebGPURendererSurface?
#endif

/// Device pixels per point, for the SwiftGPU renderer's scissor clips.
nonisolated(unsafe) var displayScale: Double = 1

@ExportedFunction
package func isoSetDisplayScale(scale: Double) {
    displayScale = scale
    MainActor.assumeIsolated { Runtime.shared.displayScale = CGFloat(scale) }
}

@ExportedFunction
package func isoStart(host: any WebHost, renderer: String, width: Double, height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        webHost = host
        // Foundation's networking over the page's fetch and WebSocket (boot
        // injects them), before the app's `@main`, which may ask already.
        installInjectedNetworkHosts()
        if Runtime.shared.host == nil {
            _ = _application_main(0, nil)
        }
        if renderer == "react" {
            _boundRendererName = "React"
            Renderer.bind(ReactRenderer { webHost?.renderTree(tree: $0) })
            #if canImport(SwiftGPU) && canImport(SwiftMap)
            // The component system renders the tree as DOM, but the `Map` host
            // view still draws real SwiftMap tiles: the tree carries the map
            // node, and the page calls `isoMapSurfaceRender` to draw it into a
            // WebGPU canvas positioned over the map element.
            Renderer.hostRendersMaps = true
            #endif
            Runtime.shared.start(host: WasmHostBridge(), width: width, height: height)
            return
        }
        #if canImport(SwiftGPU)
        // The self-drawing renderer: SwiftGPU draws every pixel; the JS host
        // keeps the services half (measurement, rasterization, IME, host views).
        let surface = WebGPURendererSurface()
        surface.displayScale = displayScale
        gpuSurface = surface
        let gpuRenderer = SwiftGPURenderer(services: WasmHostBridge(), surface: surface)
        _boundRendererName = "SwiftGPU"
        Renderer.bind(gpuRenderer)
        #if canImport(SwiftMap)
        Renderer.hostRendersMaps = true  // `Map` draws real SwiftMap tiles
        #endif
        Runtime.shared.start(host: gpuRenderer, width: width, height: height)
        #else
        #error("HostDrawnRenderer has been removed; SwiftGPU is now the only self-drawing renderer. Link swift_gpu (WebGPU) for web — see docs/renderer_layers.md")
        #endif
    }
}

@ExportedFunction
package func isoRender() {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        Runtime.shared.renderFrame()
    }
}

#if canImport(SwiftGPU) && canImport(SwiftMap)
/// The ReactRenderer path's map surface: one SwiftGPU renderer reserved for
/// `Map` host views, drawing into the page's WebGPU canvas (which the page
/// positions inside the map's DOM element). The page passes the serialized
/// map node's fields back verbatim; `id` (the node's host-event id) keys the
/// engine/tile state across frames, so camera moves reuse the loaded tiles.
nonisolated(unsafe) var mapSurfaceRenderer: SwiftGPURenderer?
#endif

/// Draw one frame of the `Map` host view at `width`×`height` points.
/// No-op unless swift_map is linked (`--config=map`).
@ExportedFunction
package func isoMapSurfaceRender(
    id: String, camera: String, annotations: String, polygons: String,
    polylines: String, width: Double, height: Double
) {
    #if canImport(SwiftGPU) && canImport(SwiftMap)
    if mapSurfaceRenderer == nil {
        let surface = WebGPURendererSurface()
        surface.displayScale = displayScale
        mapSurfaceRenderer = SwiftGPURenderer(services: WasmHostBridge(), surface: surface)
    }
    guard let renderer = mapSurfaceRenderer else { return }
    renderer.beginFrame(width: width, height: height)
    _ = renderer.drawHostView(
        id: id,
        kind: "map",
        value: camera,
        params: [
            "annotations": annotations,
            "polygons": polygons,
            "polylines": polylines,
        ],
        in: CGRect(x: 0, y: 0, width: width, height: height)
    )
    renderer.endFrame()
    #endif
}

/// The page's visibility changed; "active" / "inactive" / "background" maps
/// to `@Environment(\.scenePhase)`.
@ExportedFunction
package func isoSetScenePhase(phase: String) {
    switch phase {
    case "background": Runtime.shared.setScenePhase(.background)
    case "inactive": Runtime.shared.setScenePhase(.inactive)
    default: Runtime.shared.setScenePhase(.active)
    }
}

/// The page's `prefers-color-scheme` (initial value and every change): maps
/// to the core's system scheme, so the semantic palette re-resolves and the
/// next frame renders dark/light.
@ExportedFunction
package func isoSetColorScheme(dark: Bool) {
    Runtime.shared.setSystemColorScheme(dark: dark)
}

/// A URL was delivered to the running app (launch URL / `iso:openurl`
/// event); dispatched to `.onOpenURL` handlers.
@ExportedFunction
package func isoOpenURL(url: String) {
    Runtime.shared.openURL(external: url)
}

@ExportedFunction
package func isoPointerEvent(kind: Int32, x: Double, y: Double) {
    Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
}

@ExportedFunction
package func isoWheelEvent(x: Double, y: Double, deltaX: Double, deltaY: Double) {
    Runtime.shared.wheelEvent(x: x, y: y, deltaX: deltaX, deltaY: deltaY)
}

@ExportedFunction
package func isoResize(width: Double, height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        Runtime.shared.resize(width: width, height: height)
    }
}

@ExportedFunction
package func isoTextChanged(text: String) {
    Runtime.shared.textChanged(text)
}

@ExportedFunction
package func isoTextSubmitted() {
    Runtime.shared.textSubmitted()
}

@ExportedFunction
package func isoTextEnded() {
    Runtime.shared.textInputEnded()
}

@ExportedFunction
package func isoHostEvent(id: String, value: String) {
    Runtime.shared.hostViewEvent(id: id, value: value)
}

/// A field's key (`.onKeyPress`): true when the app took it, so the
/// renderer keeps it from the field (`preventDefault`).
@ExportedFunction
package func isoKeyEvent(id: String, value: String) -> Bool {
    Runtime.shared.keyPressEvent(id: id, value: value)
}
