// The web host bridge, expressed as a swift_ffi surface.
//
// JavaScript implements `MapWebHost` (a plain object literal) and passes it
// into `smStart`; the engine calls back out through the generated foreign
// proxy, and the page drives the map through the exported functions.
// Rendering happens HERE, in Swift, through SwiftGPU over Isomer's Metal
// (connect Isomer's Metal executor, `metalHost.connect(bridge)`, before
// `smStart`) — the page owns only the canvas, input, fetch + decode, and
// callout text.

import IsomerFFI

// canImport-guarded like MapSceneRenderer, for single-module builds.
#if canImport(SwiftGPU)
import SwiftGPU
#endif

/// The browser side: canvas + input + fetch/decode + native-text callouts.
/// No drawing — that moved into Swift (via Isomer's Metal executor).
@ExportedInterface
public protocol MapWebHost {
    /// Per-frame info (camera + projected annotation anchors) for the
    /// callout overlay; called during `smRender`, after drawing.
    func presentFrame(infoJSON: String)
    /// Fetch + decode the tile, then call `smTileLoaded(key:width:height:
    /// rgba:)` (or `smTileFailed`).
    func requestTile(key: String, url: String)
    /// A tapped annotation (via `smTap`); show/toggle its callout.
    func annotationTapped(id: String, title: String, x: Double, y: Double)
    /// Coalesce into one rAF that calls `smRender()`.
    func scheduleRender()
    func log(message: String)
}

/// The active host, installed by `smStart`. The generated foreign proxy
/// retains the JavaScript object for as long as Swift holds this reference.
nonisolated(unsafe) var webHost: (any MapWebHost)?
nonisolated(unsafe) var engine: MapEngine?
nonisolated(unsafe) var gpuSurface: MetalWebSurface?
nonisolated(unsafe) var scene: MapSceneRenderer?

final class WebEngineHost: MapEngineHost {
    func requestTile(key: TileKey, url: String) {
        webHost?.requestTile(key: key.id, url: url)
    }

    func evictTile(key: TileKey) {
        scene?.removeTexture(forKey: key.id)
    }

    func setNeedsRender() {
        webHost?.scheduleRender()
    }
}

// MARK: - Exports (JavaScript -> Swift)

@ExportedFunction
public func smStart(host: any MapWebHost, width: Double, height: Double, latitude: Double, longitude: Double, zoom: Double, bearing: Double, tilt: Double) {
    webHost = host
    guard let surface = MetalWebSurface() else {
        host.log(message: "no Metal device: connect Isomer's Metal executor before smStart")
        return
    }
    gpuSurface = surface
    scene = MapSceneRenderer(device: surface.device)
    let mapEngine = MapEngine()
    mapEngine.host = WebEngineHost()
    engine = mapEngine
    mapEngine.resize(width: width, height: height)
    mapEngine.camera = MapCamera(latitude: latitude, longitude: longitude, zoom: zoom, bearing: bearing, tilt: tilt)
}

/// Render the current frame through SwiftGPU, then hand the host the slim
/// per-frame info for callouts.
@ExportedFunction
public func smRender() {
    guard let engine, let scene, let gpuSurface else { return }
    let frame = engine.buildFrame()
    gpuSurface.renderFrame(clear: MapSceneRenderer.clearColor) { pass in
        scene.draw(frame: frame, into: pass)
    }
    webHost?.presentFrame(infoJSON: frame.infoJSON())
}

/// Pointer phases: 0 down, 1 move, 2 up/cancel (single pointer pans).
@ExportedFunction
public func smPointer(phase: Int32, x: Double, y: Double) {
    engine?.pointer(phase: Int(phase), x: x, y: y)
}

@ExportedFunction
public func smPan(deltaX: Double, deltaY: Double) {
    engine?.pan(deltaX: deltaX, deltaY: deltaY)
}

@ExportedFunction
public func smZoom(delta: Double, anchorX: Double, anchorY: Double) {
    engine?.zoom(by: delta, anchorX: anchorX, anchorY: anchorY)
}

@ExportedFunction
public func smSetCamera(latitude: Double, longitude: Double, zoom: Double, bearing: Double, tilt: Double) {
    engine?.camera = MapCamera(latitude: latitude, longitude: longitude, zoom: zoom, bearing: bearing, tilt: tilt)
}

/// Turn the camera heading by `delta` degrees.
@ExportedFunction
public func smRotate(delta: Double) {
    engine?.rotate(by: delta)
}

/// Pitch the camera by `delta` degrees (clamped to [0, maxTilt]).
@ExportedFunction
public func smTilt(delta: Double) {
    engine?.tilt(by: delta)
}

/// Replace the annotation set (spec grammar in MapOverlaySpec.swift):
/// `id|lat|lon|red|green|blue|alpha|radius[|title]` records joined by ";".
@ExportedFunction
public func smSetAnnotations(spec: String) {
    engine?.setAnnotations(spec: spec)
}

/// Replace the polygon set: `id|fillR,G,B,A|strokeR,G,B,A,width|lat,lon;…`
/// records joined by newlines (empty stroke field = no stroke).
@ExportedFunction
public func smSetPolygons(spec: String) {
    engine?.setPolygons(spec: spec)
}

/// Replace the polyline set: `id|red,green,blue,alpha|width|lat,lon;…`
/// records joined by newlines.
@ExportedFunction
public func smSetPolylines(spec: String) {
    engine?.setPolylines(spec: spec)
}

/// Hit-test a tap against the annotation markers; a hit calls back
/// `annotationTapped`.
@ExportedFunction
public func smTap(x: Double, y: Double) {
    guard let engine, let annotation = engine.annotation(atScreenX: x, y: y) else { return }
    webHost?.annotationTapped(
        id: annotation.id,
        title: annotation.title,
        x: x,
        y: y
    )
}

@ExportedFunction
public func smResize(width: Double, height: Double) {
    engine?.resize(width: width, height: height)
}

/// The host finished fetching + decoding a tile (tightly packed
/// straight-alpha RGBA8).
@ExportedFunction
public func smTileLoaded(key: String, width: Int32, height: Int32, rgba: [UInt8]) {
    guard let tileKey = TileKey(id: key) else { return }
    scene?.setTexture(rgba: rgba, width: Int(width), height: Int(height), forKey: key)
    engine?.tileLoaded(key: tileKey)
}

@ExportedFunction
public func smTileFailed(key: String) {
    guard let tileKey = TileKey(id: key) else { return }
    engine?.tileFailed(key: tileKey)
}
