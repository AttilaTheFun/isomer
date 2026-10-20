// The Android host bridge, expressed as a swift_ffi surface.
//
// Kotlin implements `MapAndroidHost` (an object expression in
// MapSurfaceView.kt) and passes it into `smStart`; the engine calls back
// out through the generated JNI foreign proxy, and the GL thread drives the
// map through the exported functions. Rendering happens HERE, in Swift,
// through SwiftGPU's GLES backend — Kotlin owns only the EGL surface,
// input, network fetch + image decode, and callout text.
//
// Single-threaded contract: Kotlin marshals every call onto the GL thread
// (GLSurfaceView.queueEvent / onDrawFrame).

import IsomerFFI

// canImport-guarded like MapSceneRenderer, for single-module builds.
#if canImport(SwiftGPU)
import SwiftGPU
#endif

/// The Kotlin side: EGL surface + input + fetch/decode + native-text
/// callouts. No drawing — that moved into Swift.
@ExportedInterface
public protocol MapAndroidHost {
    /// Per-frame info (camera + projected annotation anchors) for the
    /// callout overlay; called during `smRender`, after drawing.
    func presentFrame(infoJSON: String)
    /// Fetch + decode the tile, then call `smTileLoaded(key:width:height:
    /// rgba:)` (or `smTileFailed`) on the GL thread.
    func requestTile(key: String, url: String)
    /// A tapped annotation (via `smTap`); show/toggle its callout.
    func annotationTapped(id: String, title: String, x: Double, y: Double)
    /// Coalesce into one `requestRender()` (RENDERMODE_WHEN_DIRTY).
    func scheduleRender()
    func log(message: String)
}

/// The active host, installed by `smStart`. The generated foreign proxy
/// holds a JNI global ref to the Kotlin object while Swift keeps this.
nonisolated(unsafe) var androidHost: (any MapAndroidHost)?
nonisolated(unsafe) var engine: MapEngine?
nonisolated(unsafe) let gpuDevice = GLESGPUDevice()
nonisolated(unsafe) var scene: MapSceneRenderer?
nonisolated(unsafe) var surfaceWidthPx: Int32 = 0
nonisolated(unsafe) var surfaceHeightPx: Int32 = 0

final class AndroidEngineHost: MapEngineHost {
    func requestTile(key: TileKey, url: String) {
        androidHost?.requestTile(key: key.id, url: url)
    }

    func evictTile(key: TileKey) {
        scene?.removeTexture(forKey: key.id)
    }

    func setNeedsRender() {
        androidHost?.scheduleRender()
    }
}

// MARK: - Exports (Kotlin -> Swift)

/// (Re)start the engine — also called after a GL context loss, when every
/// GL handle is dead and every tile must be refetched.
@ExportedFunction
public func smStart(host: any MapAndroidHost, width: Double, height: Double, latitude: Double, longitude: Double, zoom: Double, bearing: Double, tilt: Double) {
    androidHost = host
    gpuDevice.contextLost()
    scene = MapSceneRenderer(device: gpuDevice)
    let mapEngine = MapEngine()
    mapEngine.host = AndroidEngineHost()
    engine = mapEngine
    mapEngine.resize(width: width, height: height)
    mapEngine.camera = MapCamera(latitude: latitude, longitude: longitude, zoom: zoom, bearing: bearing, tilt: tilt)
}

/// The surface's device-pixel size (for the GL viewport); logical sizing
/// stays in dp via `smStart`/`smResize`.
@ExportedFunction
public func smSurfaceChanged(widthPx: Int32, heightPx: Int32) {
    surfaceWidthPx = widthPx
    surfaceHeightPx = heightPx
}

/// Render the current frame through SwiftGPU (on the GL thread, context
/// current), then hand the host the slim per-frame info for callouts.
@ExportedFunction
public func smRender() {
    guard let engine, let scene else { return }
    let frame = engine.buildFrame()
    gpuDevice.renderFrame(
        widthPx: Int(surfaceWidthPx),
        heightPx: Int(surfaceHeightPx),
        clear: MapSceneRenderer.clearColor
    ) { pass in
        scene.draw(frame: frame, into: pass)
    }
    androidHost?.presentFrame(infoJSON: frame.infoJSON())
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
    androidHost?.annotationTapped(
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
/// straight-alpha RGBA8); called on the GL thread.
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
