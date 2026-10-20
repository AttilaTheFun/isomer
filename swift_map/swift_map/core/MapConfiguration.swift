/// Static engine configuration: the tile source and cache policy.
public struct MapConfiguration: Sendable {
    /// Raster tile URL template with `{z}`/`{x}`/`{y}` placeholders.
    public var tileURLTemplate: String

    /// The size one tile covers on screen at integer zoom, in points.
    public var tileSize: Double

    public var minZoom: Double
    public var maxZoom: Double

    /// Upper bound on camera tilt, in degrees. Beyond ~60° the visible tile
    /// footprint (and the fetch load) grows without bound.
    public var maxTilt: Double

    /// Soft cap on cached tiles; least-recently-displayed tiles beyond it
    /// are evicted (the host frees the texture) after each frame.
    public var maxCachedTiles: Int

    /// Required attribution for the tile source; hosts must display it over
    /// the map (ODbL requires it for OpenStreetMap).
    public var attribution: String

    public init(
        tileURLTemplate: String,
        tileSize: Double = 256,
        minZoom: Double = 1,
        maxZoom: Double = 19,
        maxTilt: Double = 60,
        maxCachedTiles: Int = 240,
        attribution: String = ""
    ) {
        self.tileURLTemplate = tileURLTemplate
        self.tileSize = tileSize
        self.minZoom = minZoom
        self.maxZoom = maxZoom
        self.maxTilt = maxTilt
        self.maxCachedTiles = maxCachedTiles
        self.attribution = attribution
    }

    /// The openstreetmap.org raster tile server. Fine for development and
    /// light use; production apps should point at their own tile source
    /// (see https://operations.osmfoundation.org/policies/tiles/).
    public static let openStreetMap = MapConfiguration(
        tileURLTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png",
        attribution: "© OpenStreetMap contributors"
    )

    public func url(for key: TileKey) -> String {
        var url = tileURLTemplate
        url = url.replacingFirst(of: "{z}", with: "\(key.z)")
        url = url.replacingFirst(of: "{x}", with: "\(key.x)")
        url = url.replacingFirst(of: "{y}", with: "\(key.y)")
        return url
    }
}

extension String {
    /// Foundation-free single-occurrence replace (the core builds for wasm
    /// and Android without Foundation, so `range(of:)` is unavailable).
    func replacingFirst(of needle: String, with replacement: String) -> String {
        guard !needle.isEmpty else { return self }
        var index = startIndex
        while index < endIndex {
            if self[index...].hasPrefix(needle) {
                let end = self.index(index, offsetBy: needle.count)
                return String(self[..<index]) + replacement + String(self[end...])
            }
            index = self.index(after: index)
        }
        return self
    }
}
