// Overlay model: annotations (billboarded point markers) and polygons
// (filled/stroked shapes that live on the map plane). Set them on the
// engine; each frame projects them alongside the tiles.

/// A geographic point (degrees).
public struct MapCoordinate: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A straight-alpha RGBA color in [0, 1] (renderers blend src-alpha /
/// one-minus-src-alpha).
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

    public static let red = MapColor(red: 1.0, green: 0.23, blue: 0.19)
    public static let blue = MapColor(red: 0.0, green: 0.48, blue: 1.0)
    public static let green = MapColor(red: 0.2, green: 0.78, blue: 0.35)
    public static let white = MapColor(red: 1, green: 1, blue: 1)
}

/// A point marker: a colored dot with a white halo, drawn screen-sized and
/// upright whatever the camera bearing/tilt (billboarded). A non-empty
/// `title` is shown by the host's callout when the annotation is tapped
/// (native text — AppKit/UIKit label, DOM element, Android TextView).
public struct MapAnnotation: Equatable, Sendable {
    public var id: String
    public var coordinate: MapCoordinate
    public var color: MapColor
    /// Dot radius in points.
    public var radius: Double
    /// Callout text. Must not contain `|`, `;`, or newlines (the FFI spec
    /// string's separators).
    public var title: String

    public init(id: String, coordinate: MapCoordinate, color: MapColor = .red, radius: Double = 8, title: String = "") {
        self.id = id
        self.coordinate = coordinate
        self.color = color
        self.radius = radius
        self.title = title
    }
}

/// An open path on the map plane, stroked with round joints: it pans,
/// rotates, and tilts with the map.
public struct MapPolyline: Equatable, Sendable {
    public var id: String
    public var coordinates: [MapCoordinate]
    public var color: MapColor
    /// Stroke width in points (at the viewport center; perspective applies).
    public var width: Double

    public init(id: String, coordinates: [MapCoordinate], color: MapColor = .blue, width: Double = 4) {
        self.id = id
        self.coordinates = coordinates
        self.color = color
        self.width = width
    }
}

/// A simple polygon (no holes; concave is fine) on the map plane: it pans,
/// rotates, and tilts with the map.
public struct MapPolygon: Equatable, Sendable {
    public var id: String
    public var coordinates: [MapCoordinate]
    public var fillColor: MapColor
    public var strokeColor: MapColor?
    /// Stroke width in points (at the viewport center; perspective applies).
    public var strokeWidth: Double

    public init(
        id: String,
        coordinates: [MapCoordinate],
        fillColor: MapColor,
        strokeColor: MapColor? = nil,
        strokeWidth: Double = 2
    ) {
        self.id = id
        self.coordinates = coordinates
        self.fillColor = fillColor
        self.strokeColor = strokeColor
        self.strokeWidth = strokeWidth
    }
}

/// Ear-clipping triangulation for simple polygons (O(n^2); overlay polygons
/// are small). Returns indices into the input, three per triangle.
enum Triangulation {
    static func earClip(_ points: [(x: Double, y: Double)]) -> [Int] {
        let count = points.count
        guard count >= 3 else { return [] }

        // Work on a consistently-wound index list (counterclockwise in the
        // conventional y-up sense; the sign convention just has to match
        // `convex` below).
        var remaining = Array(0..<count)
        if signedArea(points) < 0 {
            remaining.reverse()
        }

        func cross(_ o: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        func pointInTriangle(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double), _ c: (x: Double, y: Double)) -> Bool {
            let d1 = cross(p, a, b)
            let d2 = cross(p, b, c)
            let d3 = cross(p, c, a)
            let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
            let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNegative && hasPositive)
        }

        var result: [Int] = []
        var safety = count * count + 16
        while remaining.count > 3 && safety > 0 {
            safety -= 1
            var clipped = false
            for i in 0..<remaining.count {
                let prev = remaining[(i + remaining.count - 1) % remaining.count]
                let curr = remaining[i]
                let next = remaining[(i + 1) % remaining.count]
                // Convex corner…
                guard cross(points[prev], points[curr], points[next]) > 0 else { continue }
                // …containing no other remaining vertex.
                var isEar = true
                for other in remaining where other != prev && other != curr && other != next {
                    if pointInTriangle(points[other], points[prev], points[curr], points[next]) {
                        isEar = false
                        break
                    }
                }
                guard isEar else { continue }
                result += [prev, curr, next]
                remaining.remove(at: i)
                clipped = true
                break
            }
            if !clipped { break } // degenerate input; emit what we have
        }
        if remaining.count == 3 {
            result += remaining
        }
        return result
    }

    static func signedArea(_ points: [(x: Double, y: Double)]) -> Double {
        var area = 0.0
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            area += a.x * b.y - b.x * a.y
        }
        return area / 2
    }
}
