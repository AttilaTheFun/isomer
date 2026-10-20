// The SwiftUI Map view on Apple platforms, backed by SwiftMap
// (//swift_map in this repository): a Metal-rendered OpenStreetMap with
// a two-way camera binding, in the spirit of MapKit-for-SwiftUI. Declared
// in IsomerBridge (which app code imports on every platform); the
// reimplementation platforms declare the same API in their SwiftUI module
// (shared/swift_ui_core/MapSupport.swift).

#if canImport(SwiftMap)
import SwiftMap
#endif
import SwiftUI

/// The viewpoint over a `Map`: geographic center, fractional zoom, heading
/// (degrees clockwise from north), and pitch (degrees from top-down).
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
    /// the current zoom (bearing-aware; positive `deltaX` moves content right).
    public mutating func pan(deltaX: Double, deltaY: Double) {
        #if canImport(SwiftMap)
        self = MapCamera(engineCamera: engineCamera.panned(deltaX: deltaX, deltaY: deltaY))
        #endif
    }

    #if canImport(SwiftMap)
    fileprivate var engineCamera: SwiftMap.MapCamera {
        SwiftMap.MapCamera(latitude: latitude, longitude: longitude, zoom: zoom, bearing: bearing, tilt: tilt)
    }

    fileprivate init(engineCamera: SwiftMap.MapCamera) {
        self.init(
            latitude: engineCamera.latitude,
            longitude: engineCamera.longitude,
            zoom: engineCamera.zoom,
            bearing: engineCamera.bearing,
            tilt: engineCamera.tilt
        )
    }
    #endif
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

    #if canImport(SwiftMap)
    fileprivate var engineAnnotation: SwiftMap.MapAnnotation {
        SwiftMap.MapAnnotation(
            id: id,
            coordinate: SwiftMap.MapCoordinate(latitude: latitude, longitude: longitude),
            color: SwiftMap.MapColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha),
            radius: radius,
            title: title
        )
    }

    fileprivate init(engineAnnotation: SwiftMap.MapAnnotation) {
        self.init(
            id: engineAnnotation.id,
            latitude: engineAnnotation.coordinate.latitude,
            longitude: engineAnnotation.coordinate.longitude,
            color: MapColor(
                red: engineAnnotation.color.red,
                green: engineAnnotation.color.green,
                blue: engineAnnotation.color.blue,
                alpha: engineAnnotation.color.alpha
            ),
            radius: engineAnnotation.radius,
            title: engineAnnotation.title
        )
    }
    #endif
}

/// An open path on the map plane, stroked with round joints: it pans,
/// rotates, and tilts with the map. Coordinates are (latitude, longitude)
/// pairs in degrees.
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

    #if canImport(SwiftMap)
    fileprivate var enginePolyline: SwiftMap.MapPolyline {
        SwiftMap.MapPolyline(
            id: id,
            coordinates: coordinates.compactMap { pair in
                pair.count == 2 ? SwiftMap.MapCoordinate(latitude: pair[0], longitude: pair[1]) : nil
            },
            color: SwiftMap.MapColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha),
            width: width
        )
    }
    #endif
}

/// A simple polygon (concave OK, no holes) on the map plane: it pans,
/// rotates, and tilts with the map. Coordinates are (latitude, longitude)
/// pairs in degrees.
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

    #if canImport(SwiftMap)
    fileprivate var enginePolygon: SwiftMap.MapPolygon {
        SwiftMap.MapPolygon(
            id: id,
            coordinates: coordinates.compactMap { pair in
                pair.count == 2 ? SwiftMap.MapCoordinate(latitude: pair[0], longitude: pair[1]) : nil
            },
            fillColor: SwiftMap.MapColor(red: fillColor.red, green: fillColor.green, blue: fillColor.blue, alpha: fillColor.alpha),
            strokeColor: strokeColor.map {
                SwiftMap.MapColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: $0.alpha)
            },
            strokeWidth: strokeWidth
        )
    }
    #endif
}

/// A Metal-rendered OpenStreetMap view. The binding is two-way: set it to
/// move the camera; gestures (drag, pinch, two-finger rotate, double-tap)
/// update it back. Annotations and polygons render inside the map's GPU
/// pass (markers above tiles and polygons).
public struct Map: View {
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

    public var body: some View {
        #if canImport(SwiftMap)
        MapRepresentable(
            camera: $camera,
            annotations: annotations,
            polygons: polygons,
            polylines: polylines,
            onAnnotationTap: onAnnotationTap
        )
        #else
        // SwiftMap not linked (swift_map is a dev dependency, enabled for the
        // example apps via --config=map): a neutral placeholder pane.
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.90, green: 0.92, blue: 0.94))
            Text("Map")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Color(red: 0.45, green: 0.49, blue: 0.55))
        }
        #endif
    }
}

#if canImport(SwiftMap)

#if os(macOS)

private struct MapRepresentable: NSViewRepresentable {
    @Binding var camera: MapCamera
    let annotations: [MapAnnotation]
    let polygons: [MapPolygon]
    let polylines: [MapPolyline]
    let onAnnotationTap: ((MapAnnotation) -> Void)?

    func makeNSView(context: Context) -> SwiftMap.MapView {
        makeMapView(camera: $camera)
    }

    func updateNSView(_ view: SwiftMap.MapView, context: Context) {
        applyCamera(camera, to: view)
        applyOverlays(annotations: annotations, polygons: polygons, polylines: polylines, onAnnotationTap: onAnnotationTap, to: view)
    }
}

#else

private struct MapRepresentable: UIViewRepresentable {
    @Binding var camera: MapCamera
    let annotations: [MapAnnotation]
    let polygons: [MapPolygon]
    let polylines: [MapPolyline]
    let onAnnotationTap: ((MapAnnotation) -> Void)?

    func makeUIView(context: Context) -> SwiftMap.MapView {
        makeMapView(camera: $camera)
    }

    func updateUIView(_ view: SwiftMap.MapView, context: Context) {
        applyCamera(camera, to: view)
        applyOverlays(annotations: annotations, polygons: polygons, polylines: polylines, onAnnotationTap: onAnnotationTap, to: view)
    }
}

#endif

@MainActor
private func applyOverlays(
    annotations: [MapAnnotation],
    polygons: [MapPolygon],
    polylines: [MapPolyline],
    onAnnotationTap: ((MapAnnotation) -> Void)?,
    to view: SwiftMap.MapView
) {
    let engineAnnotations = annotations.map(\.engineAnnotation)
    if view.annotations != engineAnnotations {
        view.annotations = engineAnnotations
    }
    let enginePolygons = polygons.map(\.enginePolygon)
    if view.polygons != enginePolygons {
        view.polygons = enginePolygons
    }
    let enginePolylines = polylines.map(\.enginePolyline)
    if view.polylines != enginePolylines {
        view.polylines = enginePolylines
    }
    if let onAnnotationTap {
        view.onAnnotationTap = { engineAnnotation in
            onAnnotationTap(MapAnnotation(engineAnnotation: engineAnnotation))
        }
    } else {
        view.onAnnotationTap = nil
    }
}

@MainActor
private func makeMapView(camera: Binding<MapCamera>) -> SwiftMap.MapView {
    let view = SwiftMap.MapView()
    view.camera = camera.wrappedValue.engineCamera
    // Delivered async on the main queue (coalesced), so writing the binding
    // here never re-enters a SwiftUI view update.
    view.onCameraChange = { engineCamera in
        let updated = MapCamera(engineCamera: engineCamera)
        if updated != camera.wrappedValue {
            camera.wrappedValue = updated
        }
    }
    return view
}

@MainActor
private func applyCamera(_ camera: MapCamera, to view: SwiftMap.MapView) {
    let target = camera.engineCamera
    // The engine clamps (zoom/tilt bounds, latitude limits); comparing
    // against the view's clamped value keeps the update loop convergent.
    if view.camera != target {
        view.camera = target
    }
}

#endif  // canImport(SwiftMap)
