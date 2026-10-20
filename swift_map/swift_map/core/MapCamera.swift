/// The viewpoint over the map: a geographic center plus a fractional zoom
/// (zoom n shows the world at `tileSize * 2^n` points wide), a heading, and
/// a pitch.
public struct MapCamera: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var zoom: Double
    /// Heading in degrees, clockwise from north (the map content rotates
    /// the opposite way on screen). Wrapped to [0, 360).
    public var bearing: Double
    /// Pitch in degrees away from straight-down (0 = top-down); the top of
    /// the viewport recedes. Clamped to the configuration's `maxTilt`.
    public var tilt: Double

    public init(latitude: Double, longitude: Double, zoom: Double, bearing: Double = 0, tilt: Double = 0) {
        self.latitude = latitude
        self.longitude = longitude
        self.zoom = zoom
        self.bearing = bearing
        self.tilt = tilt
    }
}

extension MapCamera {
    /// The camera moved so the map content shifts by a screen-space delta
    /// (bearing-aware: deltas are in screen directions; positive `deltaX`
    /// drags the content to the right, like a finger).
    public func panned(deltaX: Double, deltaY: Double, tileSize: Double = 256) -> MapCamera {
        // Rotate the screen delta into map-aligned flat space (the inverse
        // of Projection's rotation = the transpose).
        let projection = Projection(viewportWidth: 2, viewportHeight: 2, bearing: bearing, tilt: tilt)
        let flatX = projection.a * deltaX + projection.c * deltaY
        let flatY = projection.b * deltaX + projection.e * deltaY
        let world = TileMath.worldSize(zoom: zoom, tileSize: tileSize)
        let merc = TileMath.normalizedMercator(latitude: latitude, longitude: longitude)
        let coordinate = TileMath.coordinate(fromNormalizedX: merc.x - flatX / world, y: merc.y - flatY / world)
        var out = self
        out.latitude = coordinate.latitude
        out.longitude = coordinate.longitude
        return out
    }
}
