/// The platform half of the engine: network + texture ownership + redraw
/// scheduling. The engine decides *what* to fetch, keep, and draw; the host
/// owns the bytes and pixels.
public protocol MapEngineHost: AnyObject {
    /// Fetch and decode the tile, upload it as a texture stored under
    /// `key.id`, then call `MapEngine.tileLoaded(key:)` (or `tileFailed`).
    /// Called at most once per key while the tile is tracked; the engine
    /// dedupes in-flight and cached tiles.
    func requestTile(key: TileKey, url: String)

    /// Free the texture stored under `key.id`; the engine has evicted it.
    func evictTile(key: TileKey)

    /// Schedule a redraw (the host should call `buildFrame`/`frameJSON` on
    /// its next paint). Coalescing is the host's job (e.g. one rAF).
    func setNeedsRender()
}
