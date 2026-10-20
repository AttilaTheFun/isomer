// SwiftMap on Linux: an SDL2 window (host.c) hosting swift_gpu's desktop GL
// backend. The engine and MapSceneRenderer are the same code every platform
// runs; this file is only the host half — input routing, URLSession tile
// fetch, stb decode, and the attribution overlay the OSM tile policy
// requires. Drag pans, the scroll wheel zooms about the cursor.

import Foundation
import SwiftGPU
import SwiftMap

// host.c (SDL window + events + attribution raster)
@_extern(c) func smw_create(_ width: Int32, _ height: Int32, _ title: UnsafePointer<CChar>) -> Int32
@_extern(c) func smw_size_px(_ outWidth: UnsafeMutablePointer<Int32>, _ outHeight: UnsafeMutablePointer<Int32>)
@_extern(c) func smw_scale() -> Double
@_extern(c) func smw_swap()
@_extern(c) func smw_poll(_ timeoutMs: Int32) -> Int32
@_extern(c) func smw_set_pointer_callback(_ cb: @convention(c) (Int32, Double, Double) -> Void)
@_extern(c) func smw_set_wheel_callback(_ cb: @convention(c) (Double, Double, Double) -> Void)
@_extern(c) func smw_set_resize_callback(_ cb: @convention(c) () -> Void)
@_extern(c) func smw_attribution_rgba(
    _ text: UnsafePointer<CChar>,
    _ outWidth: UnsafeMutablePointer<Int32>, _ outHeight: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>?
@_extern(c) func smw_free_rgba(_ pixels: UnsafeMutablePointer<UInt8>)

// shared/stb_decode
@_extern(c) func sm_decode_rgba(
    _ bytes: UnsafePointer<UInt8>, _ len: Int32,
    _ outWidth: UnsafeMutablePointer<Int32>, _ outHeight: UnsafeMutablePointer<Int32>
) -> UnsafeMutablePointer<UInt8>?
@_extern(c) func sm_free_rgba(_ pixels: UnsafeMutablePointer<UInt8>)

// MARK: - Shared state (single-threaded main loop + locked tile inbox)

final class AppState {
    let engine = MapEngine()
    let device = GLGPUDevice()
    var scene: MapSceneRenderer?
    let fetcher = FoundationTileFetcher()
    var needsRender = true

    let inboxLock = NSLock()
    var inbox: [(key: TileKey, rgba: [UInt8]?, width: Int, height: Int)] = []
}

nonisolated(unsafe) let state = AppState()

/// MapEngineHost: fetch+decode off-thread, deliver through the inbox.
final class Host: MapEngineHost {
    func requestTile(key: TileKey, url: String) {
        state.fetcher.fetch(url: url) { bytes in
            var decoded: (rgba: [UInt8]?, width: Int, height: Int) = (nil, 0, 0)
            if let bytes, !bytes.isEmpty {
                var width: Int32 = 0
                var height: Int32 = 0
                let pixels = bytes.withUnsafeBufferPointer { buffer in
                    sm_decode_rgba(buffer.baseAddress!, Int32(buffer.count), &width, &height)
                }
                if let pixels, width > 0, height > 0 {
                    decoded = (
                        Array(UnsafeBufferPointer(start: pixels, count: Int(width * height * 4))),
                        Int(width), Int(height)
                    )
                    sm_free_rgba(pixels)
                }
            }
            state.inboxLock.lock()
            state.inbox.append((key, decoded.rgba, decoded.width, decoded.height))
            state.inboxLock.unlock()
        }
    }

    func evictTile(key: TileKey) {
        state.scene?.removeTexture(forKey: key.id)
    }

    func setNeedsRender() {
        state.needsRender = true
    }
}

@main
enum ExampleApp {
    static func main() {
        let created = "SwiftMap".withCString { smw_create(900, 640, $0) }
        guard created != 0 else {
            fatalError("SDL window/GL context creation failed")
        }

        state.scene = MapSceneRenderer(device: state.device)
        state.engine.host = Host()
        var widthPx: Int32 = 0
        var heightPx: Int32 = 0
        smw_size_px(&widthPx, &heightPx)
        state.engine.resize(
            width: Double(widthPx) / smw_scale(), height: Double(heightPx) / smw_scale())
        state.engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 12)

        smw_set_pointer_callback { phase, x, y in
            state.engine.pointer(phase: Int(phase), x: x, y: y)
        }
        smw_set_wheel_callback { x, y, delta in
            state.engine.zoom(by: delta * 0.4, anchorX: x, anchorY: y)
        }
        smw_set_resize_callback {
            var width: Int32 = 0
            var height: Int32 = 0
            smw_size_px(&width, &height)
            state.engine.resize(
                width: Double(width) / smw_scale(), height: Double(height) / smw_scale())
        }

        // The attribution overlay (rasterized once; premultiplied for the
        // textured pipeline's blending contract).
        var attribution: (texture: GPUTexture, width: Double, height: Double)?
        var attributionWidth: Int32 = 0
        var attributionHeight: Int32 = 0
        if let pixels = "© OpenStreetMap contributors".withCString({
            smw_attribution_rgba($0, &attributionWidth, &attributionHeight)
        }) {
            var rgba = Array(
                UnsafeBufferPointer(
                    start: pixels, count: Int(attributionWidth * attributionHeight * 4)))
            smw_free_rgba(pixels)
            for i in stride(from: 0, to: rgba.count, by: 4) {
                let alpha = Int(rgba[i + 3])
                rgba[i] = UInt8(Int(rgba[i]) * alpha / 255)
                rgba[i + 1] = UInt8(Int(rgba[i + 1]) * alpha / 255)
                rgba[i + 2] = UInt8(Int(rgba[i + 2]) * alpha / 255)
            }
            attribution = (
                state.device.makeTexture(
                    width: Int(attributionWidth), height: Int(attributionHeight), rgba: rgba),
                Double(attributionWidth) / smw_scale(),
                Double(attributionHeight) / smw_scale()
            )
        }

        while smw_poll(state.needsRender ? 0 : 32) != 0 {
            // Drain decoded tiles (URLSession threads -> main).
            state.inboxLock.lock()
            let arrived = state.inbox
            state.inbox.removeAll()
            state.inboxLock.unlock()
            for tile in arrived {
                if let rgba = tile.rgba {
                    state.scene?.setTexture(
                        rgba: rgba, width: tile.width, height: tile.height, forKey: tile.key.id)
                    state.engine.tileLoaded(key: tile.key)
                } else {
                    state.engine.tileFailed(key: tile.key)
                }
                state.needsRender = true
            }

            guard state.needsRender, let scene = state.scene else { continue }
            state.needsRender = false
            smw_size_px(&widthPx, &heightPx)
            let frame = state.engine.buildFrame()
            state.device.renderFrame(
                widthPx: Int(widthPx), heightPx: Int(heightPx),
                clear: MapSceneRenderer.clearColor
            ) { pass in
                scene.draw(frame: frame, into: pass)
                if let attribution {
                    drawAttribution(attribution, into: pass, frame: frame)
                }
            }
            smw_swap()
        }
    }

    /// A white plaque + the rasterized text, bottom-left over the map.
    static func drawAttribution(
        _ attribution: (texture: GPUTexture, width: Double, height: Double),
        into pass: GPURenderPass, frame: MapFrame
    ) {
        pass.setTransform(frame.screenMatrix)
        let pad = 4.0
        let x = 6.0
        let y = frame.height - attribution.height - pad * 2 - 6
        let width = attribution.width + pad * 2
        let height = attribution.height + pad * 2
        pass.drawRects(instances: [
            Float(x), Float(y), Float(width), Float(height), 4, 0, 1, 1, 1, 0.75, 0,
        ])
        let x0 = Float(x + pad)
        let y0 = Float(y + pad)
        let x1 = x0 + Float(attribution.width)
        let y1 = y0 + Float(attribution.height)
        pass.drawTextured(vertices: [
            x0, y0, 0, 0, x1, y0, 1, 0, x0, y1, 0, 1,
            x1, y0, 1, 0, x1, y1, 1, 1, x0, y1, 0, 1,
        ], texture: attribution.texture)
    }
}
