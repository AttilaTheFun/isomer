// Web Mercator tile math (EPSG:3857, the slippy-map tiling scheme).
//
// The world is a square of `tileSize * 2^zoom` "world points" at a given
// (fractional) zoom; tile (z, x, y) covers a `tileSize * 2^(zoom-z)`-point
// square. Latitude is clamped to the Mercator limit so the world square
// closes at the poles.

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

/// Identifies one slippy-map tile. `z` is the integer tile zoom, `x` grows
/// east from the antimeridian, `y` grows south from the north Mercator limit.
public struct TileKey: Hashable, Sendable {
    public let z: Int
    public let x: Int
    public let y: Int

    public init(z: Int, x: Int, y: Int) {
        self.z = z
        self.x = x
        self.y = y
    }

    /// The stable string form used as the host-side texture identifier.
    public var id: String { "\(z)/\(x)/\(y)" }

    /// Parse the `id` form back (the FFI bridges round-trip keys as strings).
    public init?(id: String) {
        let parts = id.split(separator: "/")
        guard parts.count == 3,
              let z = Int(parts[0]), let x = Int(parts[1]), let y = Int(parts[2]) else {
            return nil
        }
        self.init(z: z, x: x, y: y)
    }

    /// The tile one zoom level up that contains this tile.
    public var parent: TileKey? {
        z > 0 ? TileKey(z: z - 1, x: x >> 1, y: y >> 1) : nil
    }
}

public enum TileMath {
    /// Poleward of this the Mercator projection diverges; the standard
    /// tiling scheme cuts the world off here so it stays square.
    public static let maxLatitude = 85.05112877980659

    /// Longitude/latitude -> normalized Mercator coordinates in [0, 1]
    /// (x east from the antimeridian, y south from the north limit).
    public static func normalizedMercator(latitude: Double, longitude: Double) -> (x: Double, y: Double) {
        let clampedLatitude = min(max(latitude, -maxLatitude), maxLatitude)
        let x = (longitude + 180.0) / 360.0
        let phi = clampedLatitude * Double.pi / 180.0
        let y = (1.0 - log(tan(phi) + 1.0 / cos(phi)) / Double.pi) / 2.0
        return (x, y)
    }

    /// Inverse of `normalizedMercator`. `x` may be outside [0, 1] (the map
    /// wraps east/west); `y` is clamped to the Mercator limits.
    public static func coordinate(fromNormalizedX x: Double, y: Double) -> (latitude: Double, longitude: Double) {
        let clampedY = min(max(y, 0.0), 1.0)
        let latitude = atan(sinh(Double.pi * (1.0 - 2.0 * clampedY))) * 180.0 / Double.pi
        var longitude = x * 360.0 - 180.0
        longitude = longitude.truncatingRemainder(dividingBy: 360.0)
        if longitude >= 180.0 { longitude -= 360.0 }
        if longitude < -180.0 { longitude += 360.0 }
        return (latitude, longitude)
    }

    /// Side length of the world square in points at a fractional zoom.
    public static func worldSize(zoom: Double, tileSize: Double) -> Double {
        tileSize * exp2(zoom)
    }
}
