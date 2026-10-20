// Offscreen SwiftMap verification: fetches real OSM tiles for a fixed
// camera, renders the frame into an offscreen Metal texture, and writes a
// PNG. `bazel run //swift_map/apple/tools/map_snapshot -- /tmp/map.png [lat lon zoom
// [bearing tilt]]` exercises the full core-engine + Metal pipeline
// (including the bearing/tilt projection) without a window.

import CoreGraphics
import Foundation
import ImageIO
import SwiftGPU
import SwiftMap

final class SnapshotHost: MapEngineHost {
    var pendingRequests: [(key: TileKey, url: String)] = []

    func requestTile(key: TileKey, url: String) {
        pendingRequests.append((key, url))
    }

    func evictTile(key: TileKey) {}

    func setNeedsRender() {}
}

let arguments = CommandLine.arguments
let outputPath = arguments.count > 1 ? arguments[1] : "/tmp/swift_map_snapshot.png"
let latitude = arguments.count > 4 ? Double(arguments[2])! : 37.7749
let longitude = arguments.count > 4 ? Double(arguments[3])! : -122.4194
let zoom = arguments.count > 4 ? Double(arguments[4])! : 12.0
let bearing = arguments.count > 6 ? Double(arguments[5])! : 0.0
let tilt = arguments.count > 6 ? Double(arguments[6])! : 0.0

let width = 800.0
let height = 600.0

guard let device = MetalGPUDevice() else {
    fatalError("no GPU device")
}
let scene = MapSceneRenderer(device: device)

let engine = MapEngine()
let host = SnapshotHost()
engine.host = host
engine.resize(width: width, height: height)
engine.camera = MapCamera(latitude: latitude, longitude: longitude, zoom: zoom, bearing: bearing, tilt: tilt)

// `overlays` (as any argument) adds sample SF annotations + a Golden Gate
// Park polygon, verifying the overlay pipeline end to end.
if arguments.contains("overlays") {
    engine.annotations = [
        MapAnnotation(id: "ferry", coordinate: MapCoordinate(latitude: 37.7955, longitude: -122.3937), title: "Ferry Building"),
        MapAnnotation(id: "goldengate", coordinate: MapCoordinate(latitude: 37.8199, longitude: -122.4783), color: .blue, title: "Golden Gate Bridge"),
        MapAnnotation(id: "alcatraz", coordinate: MapCoordinate(latitude: 37.8270, longitude: -122.4230), color: .green, radius: 10, title: "Alcatraz Island"),
    ]
    engine.polylines = [
        // The Alcatraz ferry route out of the Ferry Building.
        MapPolyline(
            id: "ferryroute",
            coordinates: [
                MapCoordinate(latitude: 37.7955, longitude: -122.3937),
                MapCoordinate(latitude: 37.8080, longitude: -122.4090),
                MapCoordinate(latitude: 37.8210, longitude: -122.4180),
                MapCoordinate(latitude: 37.8270, longitude: -122.4230),
            ],
            color: MapColor(red: 0.0, green: 0.48, blue: 1.0, alpha: 0.9),
            width: 4
        ),
    ]
    engine.polygons = [
        MapPolygon(
            id: "goldengatepark",
            coordinates: [
                MapCoordinate(latitude: 37.7714, longitude: -122.5110),
                MapCoordinate(latitude: 37.7748, longitude: -122.4553),
                MapCoordinate(latitude: 37.7680, longitude: -122.4547),
                MapCoordinate(latitude: 37.7645, longitude: -122.5104),
            ],
            fillColor: MapColor(red: 0.2, green: 0.78, blue: 0.35, alpha: 0.35),
            strokeColor: .green,
            strokeWidth: 3
        ),
    ]
}

// First frame: discover + request the visible tiles.
_ = engine.buildFrame()
print("fetching \(host.pendingRequests.count) tiles…")

// The injected cross-platform fetcher, driven synchronously.
let fetcher = FoundationTileFetcher()

var loaded = 0
for request in host.pendingRequests {
    let semaphore = DispatchSemaphore(value: 0)
    var tileBytes: [UInt8]?
    fetcher.fetch(url: request.url) { bytes in
        tileBytes = bytes
        semaphore.signal()
    }
    semaphore.wait()
    if let bytes = tileBytes, let decoded = TileDecoder.decodeRGBA(bytes) {
        scene.setTexture(rgba: decoded.rgba, width: decoded.width, height: decoded.height, forKey: request.key.id)
        engine.tileLoaded(key: request.key)
        loaded += 1
    } else {
        print("  FAILED \(request.url)")
        engine.tileFailed(key: request.key)
    }
}
print("loaded \(loaded)/\(host.pendingRequests.count) tiles")

// Second frame: every tile ready.
let frame = engine.buildFrame()
print("frame has \(frame.quads.count) quads")

// Render offscreen through SwiftGPU and write the PNG from RGBA bytes.
let pixels = device.renderOffscreen(
    width: Int(width),
    height: Int(height),
    clear: MapSceneRenderer.clearColor
) { pass in
    scene.draw(frame: frame, into: pass)
}
let provider = CGDataProvider(data: Data(pixels) as CFData)!
let image = CGImage(
    width: Int(width),
    height: Int(height),
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    bytesPerRow: Int(width) * 4,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
    provider: provider,
    decode: nil,
    shouldInterpolate: false,
    intent: .defaultIntent
)!
let url = URL(fileURLWithPath: outputPath) as CFURL
let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("failed to write \(outputPath)")
}
print("wrote \(outputPath)")
