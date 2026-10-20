// The Map view (SwiftMap-backed on Apple — see
// apple/libraries/swift_ui/Map.swift, the same API in the Apple Isomer
// module). It is Isomer's, not MapKit's, so it is the Isomer module's on
// every platform. Where the renderer draws SwiftMap tile scenes
// (`Renderer.hostRendersMaps`) it is the real map; elsewhere an informative
// placeholder, with the camera binding working all the same, so app code
// behaves identically.

import SwiftUI
import IsomerSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

/// The viewpoint over a `Map`: geographic center, fractional zoom, heading
/// (degrees clockwise from north), and pitch (degrees from top-down).
/// Mirrors SwiftMap's `MapCamera`.
public struct MapCamera: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var zoom: Double
    public var bearing: Double
    public var tilt: Double

    public init(latitude: Double, longitude: Double, zoom: Double, bearing: Double = 0, tilt: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.zoom = zoom
        self.bearing = bearing
        self.tilt = tilt
    }

    /// Move the center so the map content shifts by a screen-space delta at
    /// the current zoom (bearing-aware; positive `deltaX` moves content
    /// right — Web Mercator, 256-point tiles).
    public mutating func pan(deltaX: Double, deltaY: Double) {
        let rho = -bearing * Double.pi / 180
        let flatX = cos(rho) * deltaX + sin(rho) * deltaY
        let flatY = -sin(rho) * deltaX + cos(rho) * deltaY
        let world = 256.0 * exp2(zoom)
        let clampedLatitude = min(max(latitude, -85.05112877980659), 85.05112877980659)
        let phi = clampedLatitude * Double.pi / 180
        let mercX = (longitude + 180.0) / 360.0 - flatX / world
        let mercY = (1.0 - log(tan(phi) + 1.0 / cos(phi)) / Double.pi) / 2.0 - flatY / world
        latitude = atan(sinh(Double.pi * (1.0 - 2.0 * min(max(mercY, 0.0), 1.0)))) * 180.0 / Double.pi
        var newLongitude = mercX * 360.0 - 180.0
        newLongitude = newLongitude.truncatingRemainder(dividingBy: 360.0)
        if newLongitude >= 180.0 { newLongitude -= 360.0 }
        if newLongitude < -180.0 { newLongitude += 360.0 }
        longitude = newLongitude
    }
}

/// A straight-alpha RGBA color for map overlays.
public struct MapColor: Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

/// A point marker: a colored dot with a white halo, drawn screen-sized and
/// upright whatever the camera bearing/tilt.
public struct MapAnnotation: Equatable, Sendable {
    public var id: String
    public var latitude: Double
    public var longitude: Double
    public var color: MapColor
    public var radius: Double
    /// Callout text shown when the marker is tapped (native text bubble).
    public var title: String

    public init(id: String, latitude: Double, longitude: Double, color: MapColor = MapColor(red: 1, green: 0.23, blue: 0.19), radius: Double = 8, title: String = "") {
        self.id = id
        self.latitude = latitude
        self.longitude = longitude
        self.color = color
        self.radius = radius
        self.title = title
    }
}

/// An open path on the map plane, stroked with round joints. Coordinates
/// are (latitude, longitude) pairs in degrees.
public struct MapPolyline: Equatable, Sendable {
    public var id: String
    public var coordinates: [[Double]]
    public var color: MapColor
    public var width: Double

    public init(id: String, coordinates: [[Double]], color: MapColor = MapColor(red: 0, green: 0.48, blue: 1), width: Double = 4) {
        self.id = id
        self.coordinates = coordinates
        self.color = color
        self.width = width
    }
}

/// A simple polygon (concave OK, no holes) on the map plane. Coordinates
/// are (latitude, longitude) pairs in degrees.
public struct MapPolygon: Equatable, Sendable {
    public var id: String
    public var coordinates: [[Double]]
    public var fillColor: MapColor
    public var strokeColor: MapColor?
    public var strokeWidth: Double

    public init(id: String, coordinates: [[Double]], fillColor: MapColor, strokeColor: MapColor? = nil, strokeWidth: Double = 2) {
        self.id = id
        self.coordinates = coordinates
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
    }
}

/// The SwiftUI `Map` view. On hosts whose renderer draws SwiftMap tile
/// scenes (`Renderer.hostRendersMaps` — the SwiftGPU renderer with SwiftMap
/// linked, on Windows/Linux) this is the real map: the camera and overlays
/// cross to the engine as a host-view spec each build. Elsewhere it shows
/// the informative placeholder until that host is wired.
public struct Map {
    @Binding private var camera: MapCamera
    private let annotations: [MapAnnotation]
    private let polygons: [MapPolygon]
    private let polylines: [MapPolyline]
    private let onAnnotationTap: ((MapAnnotation) -> Void)?

    public init(
        camera: Binding<MapCamera>,
        annotations: [MapAnnotation] = [],
        polygons: [MapPolygon] = [],
        polylines: [MapPolyline] = [],
        onAnnotationTap: ((MapAnnotation) -> Void)? = nil
    ) {
        _camera = camera
        self.annotations = annotations
        self.polygons = polygons
        self.polylines = polylines
        self.onAnnotationTap = onAnnotationTap
    }

    @ViewBuilder
    public var body: some View {
        if Renderer.hostRendersMaps {
            ZStack {
                MapHostView(
                    camera: $camera,
                    annotationsSpec: Self.annotationsSpec(annotations),
                    polygonsSpec: Self.polygonsSpec(polygons),
                    polylinesSpec: Self.polylinesSpec(polylines)
                )
                // Tile-source attribution (ODbL requires it over the map).
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("© OpenStreetMap contributors")
                            .font(.caption)
                            // Dark on the light box in either scheme: the
                            // attribution must stay legible over the map.
                            .foregroundColor(Color(white: 0.25))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(white: 1, opacity: 0.75))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
            }
        } else {
            ZStack {
                Color(red: 0.949, green: 0.937, blue: 0.913)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                VStack(spacing: 6) {
                    Text("SwiftMap")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(cameraDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !annotations.isEmpty || !polygons.isEmpty || !polylines.isEmpty {
                        Text("\(annotations.count) annotations · \(polygons.count) polygons · \(polylines.count) polylines")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Text("Map rendering is not wired to this host yet")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var cameraDescription: String {
        func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }
        return "(\(round2(camera.latitude)), \(round2(camera.longitude))) z\(round2(camera.zoom))"
            + " b\(round2(camera.bearing))° t\(round2(camera.tilt))°"
    }

    // MARK: - Overlay spec strings (swift_map's MapOverlaySpec grammar)

    private static func specSafe(_ text: String) -> String {
        var out = ""
        for character in text where character != "|" && character != ";" && character != "\n" {
            out.append(character)
        }
        return out
    }

    /// Records ";"-separated: id|lat|lon|r|g|b|a|radius|title.
    static func annotationsSpec(_ annotations: [MapAnnotation]) -> String {
        annotations.map { a in
            "\(specSafe(a.id))|\(a.latitude)|\(a.longitude)|\(a.color.red)|\(a.color.green)"
                + "|\(a.color.blue)|\(a.color.alpha)|\(a.radius)|\(specSafe(a.title))"
        }.joined(separator: ";")
    }

    /// Records newline-separated: id|fr,fg,fb,fa|sr,sg,sb,sa,w (or empty)|lat,lon;….
    static func polygonsSpec(_ polygons: [MapPolygon]) -> String {
        polygons.map { p in
            let stroke = p.strokeColor.map {
                "\($0.red),\($0.green),\($0.blue),\($0.alpha),\(p.strokeWidth)"
            } ?? ""
            let coordinates = p.coordinates
                .filter { $0.count == 2 }
                .map { "\($0[0]),\($0[1])" }
                .joined(separator: ";")
            let fill = p.fillColor
            return "\(specSafe(p.id))|\(fill.red),\(fill.green),\(fill.blue),\(fill.alpha)|\(stroke)|\(coordinates)"
        }.joined(separator: "\n")
    }

    /// Records newline-separated: id|r,g,b,a|w|lat,lon;….
    static func polylinesSpec(_ polylines: [MapPolyline]) -> String {
        polylines.map { line in
            let coordinates = line.coordinates
                .filter { $0.count == 2 }
                .map { "\($0[0]),\($0[1])" }
                .joined(separator: ";")
            let color = line.color
            return "\(specSafe(line.id))|\(color.red),\(color.green),\(color.blue),\(color.alpha)|\(line.width)|\(coordinates)"
        }.joined(separator: "\n")
    }
}

/// The map's host view: a "map" node the host renderer draws inline (see
/// HostBridge.drawHostView). The camera crosses as a CSV value, the overlays
/// as MapOverlaySpec strings in params; gestures come back as
/// "pan:dx,dy" / "zoom:dy,ax,ay,w,h" commands through onValueChanged and
/// land in the camera binding (screen-space math here — no engine coupling,
/// so any host renderer gets drag-pan and wheel-zoom for free). A "map" node
/// takes the space it is offered, both ways, as SwiftUI's Map does.
struct MapHostView: PlatformViewRepresentable {
    let camera: Binding<MapCamera>
    let annotationsSpec: String
    let polygonsSpec: String
    let polylinesSpec: String

    var kind: String { "map" }

    var parameters: [String: String] {
        [
            "annotations": annotationsSpec,
            "polygons": polygonsSpec,
            "polylines": polylinesSpec,
        ]
    }

    var value: String {
        let value = camera.wrappedValue
        return "\(value.latitude),\(value.longitude),\(value.zoom),\(value.bearing),\(value.tilt)"
    }

    func onValueChanged(_ command: String) {
        Self.applyGesture(command, to: camera)
    }

    /// Runtime gesture commands -> camera-binding updates.
    static func applyGesture(_ command: String, to binding: Binding<MapCamera>) {
        var camera = binding.wrappedValue
        if command.hasPrefix("pan:") {
            let parts = command.dropFirst(4).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2 else { return }
            camera.pan(deltaX: parts[0], deltaY: parts[1])
        } else if command.hasPrefix("zoom:") {
            // dy, anchorX, anchorY, width, height (rect-relative points).
            let parts = command.dropFirst(5).split(separator: ",").compactMap { Double($0) }
            guard parts.count == 5 else { return }
            let delta = parts[0] / 100  // one wheel notch (±40) ≈ 0.4 levels
            let newZoom = min(max(camera.zoom + delta, 1), 19)
            let scale = exp2(newZoom - camera.zoom)
            camera.zoom = newZoom
            // Keep the content under the cursor fixed: a point at screen
            // offset `o` from the center lands at `o * scale` after zooming
            // about the center, so shift the content back by o(scale - 1).
            camera.pan(
                deltaX: -(parts[1] - parts[3] / 2) * (scale - 1),
                deltaY: -(parts[2] - parts[4] / 2) * (scale - 1))
        } else {
            return
        }
        binding.wrappedValue = camera
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Map: View {}
