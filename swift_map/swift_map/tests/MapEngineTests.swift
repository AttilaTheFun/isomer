@testable import SwiftMapCore
import XCTest

final class RecordingHost: MapEngineHost {
    var requested: [TileKey] = []
    var evicted: [TileKey] = []
    var renderRequests = 0

    func requestTile(key: TileKey, url: String) {
        requested.append(key)
    }

    func evictTile(key: TileKey) {
        evicted.append(key)
    }

    func setNeedsRender() {
        renderRequests += 1
    }
}

final class TileMathTests: XCTestCase {
    func testMercatorRoundTrip() {
        let cases = [(37.7749, -122.4194), (51.5074, -0.1278), (-33.8688, 151.2093), (0.0, 0.0)]
        for (latitude, longitude) in cases {
            let merc = TileMath.normalizedMercator(latitude: latitude, longitude: longitude)
            XCTAssertTrue(merc.x >= 0 && merc.x <= 1)
            XCTAssertTrue(merc.y >= 0 && merc.y <= 1)
            let back = TileMath.coordinate(fromNormalizedX: merc.x, y: merc.y)
            XCTAssertEqual(back.latitude, latitude, accuracy: 1e-9)
            XCTAssertEqual(back.longitude, longitude, accuracy: 1e-9)
        }
    }

    func testKnownTile() {
        // openstreetmap.org's slippy-map reference: (37.7749, -122.4194) at
        // z11 falls in tile 11/327/791.
        let merc = TileMath.normalizedMercator(latitude: 37.7749, longitude: -122.4194)
        XCTAssertEqual(Int(merc.x * 2048), 327)
        XCTAssertEqual(Int(merc.y * 2048), 791)
    }

    func testTileURL() {
        let url = MapConfiguration.openStreetMap.url(for: TileKey(z: 11, x: 327, y: 791))
        XCTAssertEqual(url, "https://tile.openstreetmap.org/11/327/791.png")
    }
}

final class MapEngineTests: XCTestCase {
    private func makeEngine(maxCachedTiles: Int = 240) -> (MapEngine, RecordingHost) {
        var configuration = MapConfiguration.openStreetMap
        configuration.maxCachedTiles = maxCachedTiles
        let engine = MapEngine(configuration: configuration)
        let host = RecordingHost()
        engine.host = host
        engine.resize(width: 512, height: 512)
        return (engine, host)
    }

    func testInitialFrameRequestsVisibleTiles() {
        let (engine, host) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        let frame = engine.buildFrame()

        // Nothing is loaded yet: no quads, but every visible tile requested.
        XCTAssertTrue(frame.quads.isEmpty)
        XCTAssertEqual(host.requested.count, 9) // 512pt viewport -> 3x3 tiles
        XCTAssertTrue(host.requested.contains(TileKey(z: 11, x: 327, y: 791)))

        // A second frame does not re-request in-flight tiles.
        _ = engine.buildFrame()
        XCTAssertEqual(host.requested.count, 9)
    }

    func testLoadedTilesBecomeQuads() {
        let (engine, host) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        _ = engine.buildFrame()
        for key in host.requested {
            engine.tileLoaded(key: key)
        }
        let frame = engine.buildFrame()
        XCTAssertEqual(frame.quads.count, 9)
        for quad in frame.quads {
            XCTAssertEqual(quad.uvSize, 1)
            XCTAssertEqual(quad.size, 256, accuracy: 1e-9)
        }
    }

    func testAncestorFallbackWhileZoomingIn() {
        let (engine, host) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        _ = engine.buildFrame()
        for key in host.requested {
            engine.tileLoaded(key: key)
        }

        engine.zoom(by: 1, anchorX: 256, anchorY: 256)
        let frame = engine.buildFrame()

        // The z12 tiles are pending, so every quad draws a quadrant of a
        // ready z11 ancestor.
        XCTAssertFalse(frame.quads.isEmpty)
        for quad in frame.quads {
            XCTAssertTrue(quad.textureKey.hasPrefix("11/"))
            XCTAssertEqual(quad.uvSize, 0.5)
        }
    }

    func testZoomKeepsAnchorFixed() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)

        // The geographic point under the anchor must stay under it.
        let anchor = (x: 100.0, y: 400.0)
        let before = geographicPoint(of: engine, atScreenX: anchor.x, y: anchor.y)
        engine.zoom(by: 0.7, anchorX: anchor.x, anchorY: anchor.y)
        let after = geographicPoint(of: engine, atScreenX: anchor.x, y: anchor.y)
        XCTAssertEqual(before.latitude, after.latitude, accuracy: 1e-6)
        XCTAssertEqual(before.longitude, after.longitude, accuracy: 1e-6)
    }

    func testPanMovesCenter() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        let before = engine.camera
        engine.pointer(phase: 0, x: 300, y: 300)
        engine.pointer(phase: 1, x: 400, y: 300) // drag content east 100pt
        engine.pointer(phase: 2, x: 400, y: 300)
        XCTAssertLessThan(engine.camera.longitude, before.longitude)
        XCTAssertEqual(engine.camera.latitude, before.latitude, accuracy: 1e-9)
    }

    func testEvictionBeyondBudget() {
        let (engine, host) = makeEngine(maxCachedTiles: 12)
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        _ = engine.buildFrame()
        for key in host.requested {
            engine.tileLoaded(key: key)
        }
        _ = engine.buildFrame()

        // Pan a whole world away: a fresh set of tiles is needed and the old
        // ready tiles fall out of the 12-tile budget.
        engine.camera = MapCamera(latitude: 37.7749, longitude: 57.5806, zoom: 11)
        _ = engine.buildFrame()
        _ = engine.buildFrame()
        XCTAssertFalse(host.evicted.isEmpty)
        for key in host.evicted {
            XCTAssertEqual(key.z, 11)
        }
    }

    func testFrameJSONShape() {
        let (engine, host) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        _ = engine.buildFrame()
        for key in host.requested {
            engine.tileLoaded(key: key)
        }
        let json = engine.frameJSON()
        XCTAssertTrue(json.hasPrefix("{\"w\":512,\"h\":512,"))
        XCTAssertTrue(json.contains("\"m\":["))
        XCTAssertTrue(json.contains("\"quads\":[{"))
        XCTAssertTrue(json.contains("\"k\":\"11/327/791\""))
        XCTAssertFalse(json.contains("e-"), "matrix JSON must not use scientific notation")
    }

    func testIdentityProjectionMatchesLegacyMapping() {
        // bearing = tilt = 0: the matrix must reduce to the plain NDC
        // mapping the renderers used before projection support.
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        let m = engine.buildFrame().matrix

        func apply(_ x: Double, _ y: Double) -> (Double, Double) {
            let clipX = m[0] * x + m[4] * y + m[12]
            let clipY = m[1] * x + m[5] * y + m[13]
            let clipW = m[3] * x + m[7] * y + m[15]
            return (clipX / clipW, clipY / clipW)
        }
        let center = apply(256, 256)
        XCTAssertEqual(center.0, 0, accuracy: 1e-9)
        XCTAssertEqual(center.1, 0, accuracy: 1e-9)
        let topLeft = apply(0, 0)
        XCTAssertEqual(topLeft.0, -1, accuracy: 1e-9)
        XCTAssertEqual(topLeft.1, 1, accuracy: 1e-9)
        let bottomRight = apply(512, 512)
        XCTAssertEqual(bottomRight.0, 1, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.1, -1, accuracy: 1e-9)
    }

    func testRotatedTiltedFrameCoversViewport() {
        // Under bearing + tilt, every NDC corner must be covered by the
        // unprojected footprint: project each quad's corners and check the
        // union's bounding box spans the viewport.
        let (engine, host) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11, bearing: 45, tilt: 45)
        _ = engine.buildFrame()
        for key in host.requested {
            engine.tileLoaded(key: key)
        }
        let frame = engine.buildFrame()
        XCTAssertFalse(frame.quads.isEmpty)

        let m = frame.matrix
        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity
        for quad in frame.quads {
            for (cx, cy) in [(quad.x, quad.y), (quad.x + quad.size, quad.y),
                             (quad.x, quad.y + quad.size), (quad.x + quad.size, quad.y + quad.size)] {
                let clipW = m[3] * cx + m[7] * cy + m[15]
                XCTAssertGreaterThan(clipW, 0, "tile corner behind the camera")
                let ndcX = (m[0] * cx + m[4] * cy + m[12]) / clipW
                let ndcY = (m[1] * cx + m[5] * cy + m[13]) / clipW
                minX = min(minX, ndcX)
                maxX = max(maxX, ndcX)
                minY = min(minY, ndcY)
                maxY = max(maxY, ndcY)
            }
        }
        XCTAssertLessThanOrEqual(minX, -1)
        XCTAssertGreaterThanOrEqual(maxX, 1)
        XCTAssertLessThanOrEqual(minY, -1)
        XCTAssertGreaterThanOrEqual(maxY, 1)
    }

    func testBearingAndTiltClamp() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 0, longitude: 0, zoom: 5, bearing: -90, tilt: 200)
        XCTAssertEqual(engine.camera.bearing, 270)
        XCTAssertEqual(engine.camera.tilt, 60)
        engine.rotate(by: 100)
        XCTAssertEqual(engine.camera.bearing, 10, accuracy: 1e-9)
        engine.tilt(by: -100)
        XCTAssertEqual(engine.camera.tilt, 0)
    }

    func testPanFollowsScreenDirectionUnderBearing() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11, bearing: 90)
        let before = engine.camera
        // Content dragged right on screen with bearing 90: the screen-x
        // axis is map-north/south, so longitude must stay put.
        engine.pan(deltaX: 100, deltaY: 0)
        XCTAssertEqual(engine.camera.longitude, before.longitude, accuracy: 1e-9)
        XCTAssertNotEqual(engine.camera.latitude, before.latitude)
    }

    func testZoomKeepsAnchorFixedUnderRotation() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11, bearing: 30)
        // With tilt = 0 the projection is affine, so the frame matrix is an
        // exact screen mapping we can use to track a geographic point.
        let anchor = (x: 120.0, y: 380.0)
        let before = geographicPoint(of: engine, atScreenX: anchor.x, y: anchor.y)
        engine.zoom(by: 0.8, anchorX: anchor.x, anchorY: anchor.y)
        let after = geographicPoint(of: engine, atScreenX: anchor.x, y: anchor.y)
        XCTAssertEqual(before.latitude, after.latitude, accuracy: 1e-6)
        XCTAssertEqual(before.longitude, after.longitude, accuracy: 1e-6)
    }

    func testAnnotationsProjectToScreenMarks() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        engine.annotations = [
            MapAnnotation(id: "center", coordinate: MapCoordinate(latitude: 37.7749, longitude: -122.4194)),
            MapAnnotation(id: "offscreen", coordinate: MapCoordinate(latitude: -33.86, longitude: 151.21)),
        ]
        let frame = engine.buildFrame()

        // One marker on screen: two 20-segment circle fans, centered mid-viewport.
        XCTAssertEqual(frame.markVertices.count, 2 * 20 * 3 * 6)
        let haloCenterX = frame.markVertices[0]
        let haloCenterY = frame.markVertices[1]
        XCTAssertEqual(haloCenterX, 256, accuracy: 0.5)
        XCTAssertEqual(haloCenterY, 256, accuracy: 0.5)
        // Halo (white) first, then the fill color on top.
        XCTAssertEqual(frame.markVertices[2], 1)
        XCTAssertEqual(frame.markVertices[3], 1)
    }

    func testPolygonTriangulatesIntoShapes() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        engine.polygons = [
            MapPolygon(
                id: "box",
                coordinates: [
                    MapCoordinate(latitude: 37.80, longitude: -122.45),
                    MapCoordinate(latitude: 37.80, longitude: -122.40),
                    MapCoordinate(latitude: 37.76, longitude: -122.40),
                    MapCoordinate(latitude: 37.76, longitude: -122.45),
                ],
                fillColor: MapColor(red: 0, green: 0, blue: 1, alpha: 0.5),
                strokeColor: .blue,
                strokeWidth: 2
            )
        ]
        let frame = engine.buildFrame()
        // A quad fills as 2 triangles (36 values) + 4 stroke edges as
        // 2 triangles each (144 values).
        XCTAssertEqual(frame.shapeVertices.count, 36 + 144)
        XCTAssertEqual(frame.shapeVertices[5], 0.5) // fill alpha rides each vertex
    }

    func testEarClipConcavePolygon() {
        // An L-shape (concave): 6 vertices -> 4 triangles, area preserved.
        let points: [(x: Double, y: Double)] = [
            (0, 0), (4, 0), (4, 2), (2, 2), (2, 4), (0, 4),
        ]
        let indices = Triangulation.earClip(points)
        XCTAssertEqual(indices.count, 4 * 3)
        var area = 0.0
        for i in stride(from: 0, to: indices.count, by: 3) {
            let a = points[indices[i]]
            let b = points[indices[i + 1]]
            let c = points[indices[i + 2]]
            area += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        XCTAssertEqual(area, 12, accuracy: 1e-9) // 4x4 minus the 2x2 notch
    }

    func testOverlaySpecParsing() {
        let (engine, _) = makeEngine()
        engine.setAnnotations(spec: "a|37.7|-122.4|1|0|0|1|8;b|37.8|-122.5|0|0.5|1|1|10")
        XCTAssertEqual(engine.annotations.count, 2)
        XCTAssertEqual(engine.annotations[1].radius, 10)
        XCTAssertEqual(engine.annotations[1].color, MapColor(red: 0, green: 0.5, blue: 1, alpha: 1))

        engine.setPolygons(spec: "p|0.2,0.78,0.35,0.35|0.2,0.78,0.35,1,3|37.77,-122.51;37.77,-122.45;37.76,-122.45\nq|1,0,0,0.2||37.1,-122.1;37.2,-122.1;37.2,-122.2")
        XCTAssertEqual(engine.polygons.count, 2)
        XCTAssertEqual(engine.polygons[0].strokeWidth, 3)
        XCTAssertNil(engine.polygons[1].strokeColor)
    }

    func testPolylineStrokesIntoShapes() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        engine.polylines = [
            MapPolyline(
                id: "route",
                coordinates: [
                    MapCoordinate(latitude: 37.77, longitude: -122.45),
                    MapCoordinate(latitude: 37.78, longitude: -122.43),
                    MapCoordinate(latitude: 37.79, longitude: -122.42),
                ],
                color: .blue,
                width: 4
            )
        ]
        let frame = engine.buildFrame()
        // 2 segments x 2 triangles (72 values) + 3 joint disks x 20
        // segments x 3 vertices (1080 values).
        XCTAssertEqual(frame.shapeVertices.count, 72 + 1080)
    }

    func testAnnotationHitTest() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        engine.annotations = [
            MapAnnotation(id: "center", coordinate: MapCoordinate(latitude: 37.7749, longitude: -122.4194), radius: 8, title: "Center")
        ]
        // The annotation sits at the viewport center (256, 256).
        XCTAssertEqual(engine.annotation(atScreenX: 256, y: 256)?.id, "center")
        XCTAssertEqual(engine.annotation(atScreenX: 260, y: 250)?.title, "Center")
        XCTAssertNil(engine.annotation(atScreenX: 300, y: 256)) // beyond radius + slop
        // Still hittable under rotation + tilt (anchors re-projected).
        engine.rotate(by: 45)
        engine.tilt(by: 40)
        XCTAssertEqual(engine.annotation(atScreenX: 256, y: 256)?.id, "center")
    }

    func testPolylineSpecParsing() {
        let (engine, _) = makeEngine()
        engine.setPolylines(spec: "route|0,0.48,1,0.9|4|37.79,-122.39;37.81,-122.41;37.83,-122.42")
        XCTAssertEqual(engine.polylines.count, 1)
        XCTAssertEqual(engine.polylines[0].coordinates.count, 3)
        XCTAssertEqual(engine.polylines[0].width, 4)

        engine.setAnnotations(spec: "a|37.7|-122.4|1|0|0|1|8|Ferry Building")
        XCTAssertEqual(engine.annotations[0].title, "Ferry Building")
    }

    func testFrameJSONIncludesOverlays() {
        let (engine, _) = makeEngine()
        engine.camera = MapCamera(latitude: 37.7749, longitude: -122.4194, zoom: 11)
        engine.annotations = [MapAnnotation(id: "a", coordinate: MapCoordinate(latitude: 37.7749, longitude: -122.4194), title: "A \"quoted\" title")]
        let json = engine.frameJSON()
        XCTAssertTrue(json.contains("\"sm\":["))
        XCTAssertTrue(json.contains("\"marks\":["))
        XCTAssertTrue(json.contains("\"shapes\":[]"))
        // The anchors list carries id/position/escaped title for host callouts.
        XCTAssertTrue(json.contains("\"anns\":[{\"i\":\"a\",\"x\":256,\"y\":256,\"t\":\"A \\\"quoted\\\" title\"}]"))
    }

    /// Inverse of the engine's screen mapping for tilt = 0 (bearing-aware),
    /// via public camera state only.
    private func geographicPoint(of engine: MapEngine, atScreenX x: Double, y: Double) -> (latitude: Double, longitude: Double) {
        let camera = engine.camera
        let rho = -camera.bearing * Double.pi / 180
        let flatX = cos(rho) * (x - 256) + sin(rho) * (y - 256)
        let flatY = -sin(rho) * (x - 256) + cos(rho) * (y - 256)
        let world = TileMath.worldSize(zoom: camera.zoom, tileSize: 256)
        let merc = TileMath.normalizedMercator(latitude: camera.latitude, longitude: camera.longitude)
        return TileMath.coordinate(
            fromNormalizedX: merc.x + flatX / world,
            y: merc.y + flatY / world
        )
    }
}
