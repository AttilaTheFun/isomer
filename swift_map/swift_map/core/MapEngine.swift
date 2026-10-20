// The platform-independent map engine: camera state, gesture arithmetic,
// visible-tile computation with ancestor fallback, and fetch/cache policy.
//
// Single-threaded by contract: every call must come from the host's render
// thread (the main thread on Apple, the GL thread on Android, the JS thread
// on the web). The engine is event-driven — it renders no frames itself; it
// asks the host via `setNeedsRender()` and the host pulls a `MapFrame` (or
// its JSON form) when it paints.

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

public final class MapEngine {
    public let configuration: MapConfiguration

    /// The platform half. Strong: the engine is the root object on the FFI
    /// platforms and the host proxy must stay alive as long as it does.
    public var host: (any MapEngineHost)?

    public init(configuration: MapConfiguration = .openStreetMap) {
        self.configuration = configuration
        _camera = MapCamera(latitude: 0, longitude: 0, zoom: configuration.minZoom)
    }

    // MARK: - Camera & viewport

    private var _camera: MapCamera
    public var camera: MapCamera {
        get { _camera }
        set {
            _camera = clamped(newValue)
            host?.setNeedsRender()
        }
    }

    public private(set) var viewportWidth: Double = 0
    public private(set) var viewportHeight: Double = 0

    public func resize(width: Double, height: Double) {
        guard width != viewportWidth || height != viewportHeight else { return }
        viewportWidth = max(width, 0)
        viewportHeight = max(height, 0)
        _camera = clamped(_camera)
        host?.setNeedsRender()
    }

    // MARK: - Gestures

    private var dragLast: (x: Double, y: Double)?

    /// Pointer phases: 0 down, 1 move, 2 up/cancel. A single pointer pans.
    public func pointer(phase: Int, x: Double, y: Double) {
        switch phase {
        case 0:
            dragLast = (x, y)
        case 1:
            guard let last = dragLast else { return }
            pan(deltaX: x - last.x, deltaY: y - last.y)
            dragLast = (x, y)
        default:
            dragLast = nil
        }
    }

    /// Move the map content by a screen-space delta (the content follows the
    /// finger: a positive `deltaX` drags the content to the right, whatever
    /// the bearing).
    public func pan(deltaX: Double, deltaY: Double) {
        _camera = clamped(_camera.panned(deltaX: deltaX, deltaY: deltaY, tileSize: configuration.tileSize))
        host?.setNeedsRender()
    }

    /// Change zoom by `delta` levels, keeping the geographic point under the
    /// screen-space anchor fixed (scroll-wheel / pinch semantics).
    public func zoom(by delta: Double, anchorX: Double, anchorY: Double) {
        let oldZoom = _camera.zoom
        let newZoom = min(max(oldZoom + delta, configuration.minZoom), configuration.maxZoom)
        guard newZoom != oldZoom else { return }
        let scale = exp2(newZoom - oldZoom)

        // Flat-space offset from the center that projects onto the anchor
        // (identical to `anchor - center` when bearing = tilt = 0).
        let flat = projection().unproject(screenX: anchorX, screenY: anchorY)

        let oldWorld = TileMath.worldSize(zoom: oldZoom, tileSize: configuration.tileSize)
        let merc = TileMath.normalizedMercator(latitude: _camera.latitude, longitude: _camera.longitude)
        // World-point position of the anchor before the zoom…
        let anchorWorldX = merc.x * oldWorld + flat.x
        let anchorWorldY = merc.y * oldWorld + flat.y
        // …stays under the same screen point after scaling the world.
        let newWorld = oldWorld * scale
        let newCenterX = (anchorWorldX * scale - flat.x) / newWorld
        let newCenterY = (anchorWorldY * scale - flat.y) / newWorld

        let coordinate = TileMath.coordinate(fromNormalizedX: newCenterX, y: newCenterY)
        var camera = _camera
        camera.latitude = coordinate.latitude
        camera.longitude = coordinate.longitude
        camera.zoom = newZoom
        _camera = clamped(camera)
        host?.setNeedsRender()
    }

    /// Turn the camera heading by `delta` degrees (content rotates the
    /// opposite way about the screen center).
    public func rotate(by delta: Double) {
        var camera = _camera
        camera.bearing += delta
        _camera = clamped(camera)
        host?.setNeedsRender()
    }

    /// Pitch the camera by `delta` degrees (clamped to [0, maxTilt]).
    public func tilt(by delta: Double) {
        var camera = _camera
        camera.tilt += delta
        _camera = clamped(camera)
        host?.setNeedsRender()
    }

    private func projection() -> Projection {
        Projection(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            bearing: _camera.bearing,
            tilt: _camera.tilt
        )
    }

    private func clamped(_ camera: MapCamera) -> MapCamera {
        var result = camera
        result.zoom = min(max(camera.zoom, configuration.minZoom), configuration.maxZoom)
        result.tilt = min(max(camera.tilt, 0), configuration.maxTilt)
        result.bearing = camera.bearing.truncatingRemainder(dividingBy: 360.0)
        if result.bearing < 0 { result.bearing += 360.0 }

        // Wrap longitude; clamp the center so the viewport never scrolls past
        // the top/bottom of the world square (when the world is shorter than
        // the viewport, lock the center to the equatorial middle).
        result.longitude = result.longitude.truncatingRemainder(dividingBy: 360.0)
        if result.longitude >= 180.0 { result.longitude -= 360.0 }
        if result.longitude < -180.0 { result.longitude += 360.0 }

        let world = TileMath.worldSize(zoom: result.zoom, tileSize: configuration.tileSize)
        let merc = TileMath.normalizedMercator(latitude: result.latitude, longitude: result.longitude)
        var y = merc.y
        let halfView = viewportHeight / 2 / world
        if world <= viewportHeight {
            y = 0.5
        } else {
            y = min(max(y, halfView), 1.0 - halfView)
        }
        result.latitude = TileMath.coordinate(fromNormalizedX: merc.x, y: y).latitude
        return result
    }

    // MARK: - Overlays

    /// Billboarded point markers (replace-all semantics, binding-friendly).
    public var annotations: [MapAnnotation] = [] {
        didSet { host?.setNeedsRender() }
    }

    /// Map-plane polygons. Triangulated once per set, in Mercator space, so
    /// per-frame work is a linear remap.
    public var polygons: [MapPolygon] = [] {
        didSet {
            triangulatedPolygons = polygons.compactMap { polygon in
                let merc = polygon.coordinates.map { coordinate -> (x: Double, y: Double) in
                    TileMath.normalizedMercator(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                let triangles = Triangulation.earClip(merc)
                guard !triangles.isEmpty || polygon.strokeColor != nil else { return nil }
                return (polygon, merc, triangles)
            }
            host?.setNeedsRender()
        }
    }

    private var triangulatedPolygons: [(polygon: MapPolygon, merc: [(x: Double, y: Double)], triangles: [Int])] = []

    /// Open paths on the map plane (round joints/caps).
    public var polylines: [MapPolyline] = [] {
        didSet {
            mercPolylines = polylines.compactMap { line in
                guard line.coordinates.count >= 2 else { return nil }
                let merc = line.coordinates.map { coordinate -> (x: Double, y: Double) in
                    TileMath.normalizedMercator(latitude: coordinate.latitude, longitude: coordinate.longitude)
                }
                return (line, merc)
            }
            host?.setNeedsRender()
        }
    }

    private var mercPolylines: [(line: MapPolyline, merc: [(x: Double, y: Double)])] = []

    /// The topmost annotation whose marker contains the screen point
    /// (matching the drawn radius plus `slop` for fat fingers), or nil.
    public func annotation(atScreenX x: Double, y: Double, slop: Double = 8) -> MapAnnotation? {
        guard viewportWidth > 0, viewportHeight > 0 else { return nil }
        let world = TileMath.worldSize(zoom: _camera.zoom, tileSize: configuration.tileSize)
        let merc = TileMath.normalizedMercator(latitude: _camera.latitude, longitude: _camera.longitude)
        let anchors = annotationAnchors(
            world: world,
            originX: merc.x * world - viewportWidth / 2,
            originY: merc.y * world - viewportHeight / 2,
            matrix: projection().matrix()
        )
        // Last drawn = topmost.
        for anchor in anchors.reversed() {
            let dx = anchor.x - x
            let dy = anchor.y - y
            let reach = anchor.annotation.radius + slop
            if dx * dx + dy * dy <= reach * reach {
                return anchor.annotation
            }
        }
        return nil
    }

    /// On-screen annotation anchor positions (screen points), in draw order.
    private func annotationAnchors(
        world: Double,
        originX: Double,
        originY: Double,
        matrix: [Double]
    ) -> [(annotation: MapAnnotation, x: Double, y: Double)] {
        func wrapped(_ flatX: Double) -> Double {
            flatX - (((flatX - viewportWidth / 2) / world).rounded()) * world
        }
        var anchors: [(annotation: MapAnnotation, x: Double, y: Double)] = []
        for annotation in annotations {
            let merc = TileMath.normalizedMercator(
                latitude: annotation.coordinate.latitude,
                longitude: annotation.coordinate.longitude
            )
            let flatX = wrapped(merc.x * world - originX)
            let flatY = merc.y * world - originY
            let clipW = matrix[3] * flatX + matrix[7] * flatY + matrix[15]
            guard clipW > 1e-4 else { continue } // behind the camera
            let ndcX = (matrix[0] * flatX + matrix[4] * flatY + matrix[12]) / clipW
            let ndcY = (matrix[1] * flatX + matrix[5] * flatY + matrix[13]) / clipW
            let screenX = (ndcX + 1) * viewportWidth / 2
            let screenY = (1 - ndcY) * viewportHeight / 2
            let margin = annotation.radius + 8
            guard screenX > -margin, screenX < viewportWidth + margin,
                  screenY > -margin, screenY < viewportHeight + margin else {
                continue
            }
            anchors.append((annotation, screenX, screenY))
        }
        return anchors
    }

    /// Bridge helpers: overlay sets crossing an FFI boundary as spec strings
    /// (see MapOverlaySpec.swift for the grammar).
    public func setAnnotations(spec: String) {
        annotations = MapOverlaySpec.parseAnnotations(spec)
    }

    public func setPolygons(spec: String) {
        polygons = MapOverlaySpec.parsePolygons(spec)
    }

    public func setPolylines(spec: String) {
        polylines = MapOverlaySpec.parsePolylines(spec)
    }

    private func buildOverlayVertices(
        world: Double,
        originX: Double,
        originY: Double,
        matrix: [Double]
    ) -> (shapes: [Double], marks: [Double], anchors: [(annotation: MapAnnotation, x: Double, y: Double)]) {
        // Nearest antimeridian wrap, so overlays follow the shorter way
        // around when longitude wraps.
        func wrapped(_ flatX: Double) -> Double {
            flatX - (((flatX - viewportWidth / 2) / world).rounded()) * world
        }

        var shapes: [Double] = []
        for entry in triangulatedPolygons {
            var flat = entry.merc.map { point -> (x: Double, y: Double) in
                (point.x * world - originX, point.y * world - originY)
            }
            if let first = flat.first {
                let shift = wrapped(first.x) - first.x
                if shift != 0 {
                    flat = flat.map { ($0.x + shift, $0.y) }
                }
            }
            let fill = entry.polygon.fillColor
            for index in entry.triangles {
                let point = flat[index]
                shapes += [point.x, point.y, fill.red, fill.green, fill.blue, fill.alpha]
            }
            if let stroke = entry.polygon.strokeColor {
                appendStroke(flat, color: stroke, width: entry.polygon.strokeWidth, closed: true, into: &shapes)
            }
        }

        // Polylines: open strokes with round joints/caps (a disk at every
        // vertex), on the map plane like polygon strokes.
        for entry in mercPolylines {
            var flat = entry.merc.map { point -> (x: Double, y: Double) in
                (point.x * world - originX, point.y * world - originY)
            }
            if let first = flat.first {
                let shift = wrapped(first.x) - first.x
                if shift != 0 {
                    flat = flat.map { ($0.x + shift, $0.y) }
                }
            }
            appendStroke(flat, color: entry.line.color, width: entry.line.width, closed: false, into: &shapes)
            for point in flat {
                appendCircle(centerX: point.x, centerY: point.y, radius: entry.line.width / 2, color: entry.line.color, into: &shapes)
            }
        }

        // Markers: CPU-projected anchors so they stay screen-sized and
        // upright under bearing/tilt; the same anchors feed hit-testing and
        // the frame's host-callout positions.
        let anchors = annotationAnchors(world: world, originX: originX, originY: originY, matrix: matrix)
        var marks: [Double] = []
        for anchor in anchors {
            appendCircle(centerX: anchor.x, centerY: anchor.y, radius: anchor.annotation.radius + 1.5, color: .white, into: &marks)
            appendCircle(centerX: anchor.x, centerY: anchor.y, radius: anchor.annotation.radius, color: anchor.annotation.color, into: &marks)
        }
        return (shapes, marks, anchors)
    }

    private func appendCircle(centerX: Double, centerY: Double, radius: Double, color: MapColor, into vertices: inout [Double]) {
        let segments = 20
        var previousX = centerX + radius
        var previousY = centerY
        for i in 1...segments {
            let angle = Double(i) / Double(segments) * 2 * Double.pi
            let x = centerX + radius * cos(angle)
            let y = centerY + radius * sin(angle)
            vertices += [centerX, centerY, color.red, color.green, color.blue, color.alpha]
            vertices += [previousX, previousY, color.red, color.green, color.blue, color.alpha]
            vertices += [x, y, color.red, color.green, color.blue, color.alpha]
            previousX = x
            previousY = y
        }
    }

    private func appendStroke(_ flat: [(x: Double, y: Double)], color: MapColor, width: Double, closed: Bool, into vertices: inout [Double]) {
        let half = width / 2
        let segmentCount = closed ? flat.count : flat.count - 1
        for i in 0..<segmentCount {
            let a = flat[i]
            let b = flat[(i + 1) % flat.count]
            let dx = b.x - a.x
            let dy = b.y - a.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 1e-9 else { continue }
            let px = -dy / length * half
            let py = dx / length * half
            let corners = [
                (a.x - px, a.y - py), (a.x + px, a.y + py),
                (b.x + px, b.y + py), (b.x - px, b.y - py),
            ]
            for index in [0, 1, 2, 0, 2, 3] {
                vertices += [corners[index].0, corners[index].1, color.red, color.green, color.blue, color.alpha]
            }
        }
    }

    // MARK: - Tile cache state

    private enum TileState {
        case pending
        case ready
        case failed
    }

    private var tiles: [TileKey: TileState] = [:]
    private var lastDisplayed: [TileKey: UInt64] = [:]
    private var frameStamp: UInt64 = 0

    /// The host finished decoding + uploading the texture for `key`.
    public func tileLoaded(key: TileKey) {
        guard tiles[key] == .pending else { return }
        tiles[key] = .ready
        host?.setNeedsRender()
    }

    /// The fetch or decode failed; the tile keeps its ancestor fallback and
    /// is not re-requested until it falls out of the cache.
    public func tileFailed(key: TileKey) {
        guard tiles[key] == .pending else { return }
        tiles[key] = .failed
    }

    // MARK: - Frame building

    /// Compute the tiles covering the viewport, request what's missing,
    /// substitute ready ancestors for tiles still in flight, and evict
    /// tiles that have fallen out of the cache budget.
    public func buildFrame() -> MapFrame {
        frameStamp += 1
        var quads: [TileQuad] = []

        let zoom = _camera.zoom
        let maxTileZ = Int(configuration.maxZoom.rounded(.down))
        let tileZ = min(max(Int(zoom.rounded()), 0), maxTileZ)
        let tileSpan = configuration.tileSize * exp2(zoom - Double(tileZ))
        let tileCount = 1 << tileZ

        let world = TileMath.worldSize(zoom: zoom, tileSize: configuration.tileSize)
        let merc = TileMath.normalizedMercator(latitude: _camera.latitude, longitude: _camera.longitude)
        let originX = merc.x * world - viewportWidth / 2
        let originY = merc.y * world - viewportHeight / 2

        let projection = self.projection()
        if viewportWidth > 0 && viewportHeight > 0 {
            // The viewport's footprint on the (flat) map plane: under
            // rotation/tilt it's a quadrilateral, so unproject the corners
            // and tile its bounding box.
            var minFlatX = Double.infinity
            var maxFlatX = -Double.infinity
            var minFlatY = Double.infinity
            var maxFlatY = -Double.infinity
            for corner in [(0.0, 0.0), (viewportWidth, 0.0), (0.0, viewportHeight), (viewportWidth, viewportHeight)] {
                let flat = projection.unproject(screenX: corner.0, screenY: corner.1)
                minFlatX = min(minFlatX, flat.x)
                maxFlatX = max(maxFlatX, flat.x)
                minFlatY = min(minFlatY, flat.y)
                maxFlatY = max(maxFlatY, flat.y)
            }
            let centerWorldX = merc.x * world
            let centerWorldY = merc.y * world

            var firstX = Int(((centerWorldX + minFlatX) / tileSpan).rounded(.down))
            var lastX = Int(((centerWorldX + maxFlatX) / tileSpan).rounded(.down))
            var firstY = max(Int(((centerWorldY + minFlatY) / tileSpan).rounded(.down)), 0)
            var lastY = min(Int(((centerWorldY + maxFlatY) / tileSpan).rounded(.down)), tileCount - 1)

            // Safety cap: extreme tilt/viewport combinations must not fetch
            // the world. Clamp the footprint around the center tile.
            let centerTileX = Int((centerWorldX / tileSpan).rounded(.down))
            let centerTileY = Int((centerWorldY / tileSpan).rounded(.down))
            let maxSpread = 12
            firstX = max(firstX, centerTileX - maxSpread)
            lastX = min(lastX, centerTileX + maxSpread)
            firstY = max(firstY, centerTileY - maxSpread)
            lastY = min(lastY, centerTileY + maxSpread)

            var y = firstY
            while y <= lastY {
                var x = firstX
                while x <= lastX {
                    let wrappedX = ((x % tileCount) + tileCount) % tileCount
                    let key = TileKey(z: tileZ, x: wrappedX, y: y)
                    if let quad = resolve(
                        key: key,
                        screenX: Double(x) * tileSpan - originX,
                        screenY: Double(y) * tileSpan - originY,
                        size: tileSpan
                    ) {
                        quads.append(quad)
                    }
                    x += 1
                }
                y += 1
            }
        }

        evictBeyondBudget()
        let matrix = projection.matrix()
        let overlays = buildOverlayVertices(world: world, originX: originX, originY: originY, matrix: matrix)
        return MapFrame(
            width: viewportWidth,
            height: viewportHeight,
            camera: _camera,
            quads: quads,
            matrix: matrix,
            shapeVertices: overlays.shapes,
            markVertices: overlays.marks,
            screenMatrix: Projection(
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight,
                bearing: 0,
                tilt: 0
            ).matrix(),
            annotationAnchors: overlays.anchors.map {
                AnnotationAnchor(id: $0.annotation.id, x: $0.x, y: $0.y, title: $0.annotation.title)
            }
        )
    }

    /// The `buildFrame` JSON form used by the FFI hosts.
    public func frameJSON() -> String {
        buildFrame().json()
    }

    private func resolve(key: TileKey, screenX: Double, screenY: Double, size: Double) -> TileQuad? {
        lastDisplayed[key] = frameStamp

        switch tiles[key] {
        case .ready:
            return TileQuad(textureKey: key.id, x: screenX, y: screenY, size: size, u: 0, v: 0, uvSize: 1)
        case .pending, .failed:
            break
        case nil:
            tiles[key] = .pending
            host?.requestTile(key: key, url: configuration.url(for: key))
        }

        // Not drawable yet: walk up the pyramid for a loaded ancestor and
        // draw its matching quadrant instead. Touch the ancestor so the
        // fallback isn't evicted while it's still on screen.
        var ancestor = key
        var u = 0.0
        var v = 0.0
        var uvSize = 1.0
        for _ in 0..<6 {
            guard let parent = ancestor.parent else { break }
            u = (Double(ancestor.x & 1) + u) / 2
            v = (Double(ancestor.y & 1) + v) / 2
            uvSize /= 2
            ancestor = parent
            if tiles[ancestor] == .ready {
                lastDisplayed[ancestor] = frameStamp
                return TileQuad(textureKey: ancestor.id, x: screenX, y: screenY, size: size, u: u, v: v, uvSize: uvSize)
            }
        }
        return nil
    }

    private func evictBeyondBudget() {
        let excess = tiles.count - configuration.maxCachedTiles
        guard excess > 0 else { return }

        // Oldest-first among tiles not displayed this frame. Pending tiles
        // stay tracked (the host request is already in flight; dropping the
        // entry would double-fetch and orphan the completion).
        var candidates: [(key: TileKey, stamp: UInt64)] = []
        for (key, state) in tiles {
            guard state != .pending else { continue }
            let stamp = lastDisplayed[key] ?? 0
            if stamp < frameStamp {
                candidates.append((key, stamp))
            }
        }
        candidates.sort { $0.stamp < $1.stamp }
        for candidate in candidates.prefix(excess) {
            if tiles[candidate.key] == .ready {
                host?.evictTile(key: candidate.key)
            }
            tiles[candidate.key] = nil
            lastDisplayed[candidate.key] = nil
        }
    }
}
