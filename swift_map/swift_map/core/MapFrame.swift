/// One tile draw: a screen-space square filled with (a sub-rectangle of) a
/// tile texture. `textureKey` names the texture the host holds; while a tile
/// is still loading it may be an ancestor tile, with `u`/`v`/`uvSize`
/// selecting the matching quadrant.
public struct TileQuad: Equatable, Sendable {
    /// Host texture identifier (a `TileKey.id`, e.g. "11/602/770").
    public let textureKey: String
    /// Screen position of the quad's top-left corner, in points.
    public let x: Double
    public let y: Double
    /// The quad is square: its side length in points.
    public let size: Double
    /// Top-left of the texture sub-rectangle, in [0, 1] texture space.
    public let u: Double
    public let v: Double
    /// Side length of the (square) texture sub-rectangle.
    public let uvSize: Double
}

/// Everything a renderer needs to draw one map frame, in paint order:
/// tiles, then `shapeVertices` (polygons, on the map plane, transformed by
/// `matrix`), then `markVertices` (billboarded annotation markers, already
/// in screen points, transformed by `screenMatrix`).
public struct MapFrame: Sendable {
    public let width: Double
    public let height: Double
    public let camera: MapCamera
    public let quads: [TileQuad]
    /// Column-major 4x4 taking quad positions (x, y, 0, 1) — flat screen
    /// points — to clip space (bearing rotation + tilt perspective + NDC).
    public let matrix: [Double]
    /// Overlay triangles, stride 6 (x, y, red, green, blue, alpha), straight
    /// alpha. `shapeVertices` share the quads' flat space; `markVertices`
    /// are final screen points.
    public let shapeVertices: [Double]
    public let markVertices: [Double]
    /// The plain NDC mapping (the `matrix` of an untilted, unrotated
    /// camera), for `markVertices`.
    public let screenMatrix: [Double]
    /// Screen positions of the on-screen annotations, in draw order — for
    /// host-side native-text callouts and custom annotation views.
    public let annotationAnchors: [AnnotationAnchor]

    /// The slim per-frame payload FFI hosts still need now that rendering
    /// happens in Swift (through SwiftGPU): camera state + projected
    /// annotation anchors for native-text callouts.
    /// `{"lat":,"lon":,"zoom":,"bearing":,"tilt":,"anns":[{"i":,"x":,"y":,"t":}]}`
    public func infoJSON() -> String {
        var out = "{\"lat\":\(num(camera.latitude)),\"lon\":\(num(camera.longitude)),\"zoom\":\(num(camera.zoom))"
        out += ",\"bearing\":\(num(camera.bearing)),\"tilt\":\(num(camera.tilt))"
        out += ",\"anns\":["
        var first = true
        for anchor in annotationAnchors {
            if !first { out += "," }
            first = false
            out += "{\"i\":\"\(jsonEscaped(anchor.id))\",\"x\":\(num(anchor.x)),\"y\":\(num(anchor.y))"
            out += ",\"t\":\"\(jsonEscaped(anchor.title))\"}"
        }
        out += "]}"
        return out
    }

    /// Compact JSON for the FFI hosts (WebGPU / OpenGL renderers decode it
    /// on the other side of the bridge):
    /// `{"w":,"h":,"lat":,"lon":,"zoom":,"bearing":,"tilt":,"m":[16],"quads":[{"k":,"x":,"y":,"s":,"u":,"v":,"d":}]}`
    public func json() -> String {
        var out = "{\"w\":\(num(width)),\"h\":\(num(height))"
        out += ",\"lat\":\(num(camera.latitude)),\"lon\":\(num(camera.longitude)),\"zoom\":\(num(camera.zoom))"
        out += ",\"bearing\":\(num(camera.bearing)),\"tilt\":\(num(camera.tilt))"
        out += ",\"m\":" + numberArray(matrix, formatter: matrixNum)
        out += ",\"sm\":" + numberArray(screenMatrix, formatter: matrixNum)
        out += ",\"shapes\":" + numberArray(shapeVertices, formatter: num)
        out += ",\"marks\":" + numberArray(markVertices, formatter: num)
        out += ",\"anns\":["
        var firstAnchor = true
        for anchor in annotationAnchors {
            if !firstAnchor { out += "," }
            firstAnchor = false
            out += "{\"i\":\"\(jsonEscaped(anchor.id))\",\"x\":\(num(anchor.x)),\"y\":\(num(anchor.y))"
            out += ",\"t\":\"\(jsonEscaped(anchor.title))\"}"
        }
        out += "]"
        out += ",\"quads\":["
        var first = true
        for quad in quads {
            if !first { out += "," }
            first = false
            out += "{\"k\":\"\(quad.textureKey)\",\"x\":\(num(quad.x)),\"y\":\(num(quad.y))"
            out += ",\"s\":\(num(quad.size)),\"u\":\(num(quad.u)),\"v\":\(num(quad.v)),\"d\":\(num(quad.uvSize))}"
        }
        out += "]}"
        return out
    }
}

/// One on-screen annotation's projected position (screen points).
public struct AnnotationAnchor: Equatable, Sendable {
    public let id: String
    public let x: Double
    public let y: Double
    public let title: String

    public init(id: String, x: Double, y: Double, title: String) {
        self.id = id
        self.x = x
        self.y = y
        self.title = title
    }
}

/// Minimal JSON string escaping (ids/titles): backslash, quote, newline.
private func jsonEscaped(_ text: String) -> String {
    var out = ""
    for character in text {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        default: out.append(character)
        }
    }
    return out
}

private func numberArray(_ values: [Double], formatter: (Double) -> String) -> String {
    var out = "["
    var first = true
    for value in values {
        if !first { out += "," }
        first = false
        out += formatter(value)
    }
    return out + "]"
}

/// Foundation-free numeric formatting: round to a fixed epsilon so the JSON
/// stays compact and never grows scientific notation for screen-scale values.
private func num(_ value: Double) -> String {
    let rounded = (value * 10000).rounded() / 10000
    if rounded == rounded.rounded() && abs(rounded) < 1e15 {
        return "\(Int(rounded))"
    }
    return "\(rounded)"
}

/// Matrix entries span many magnitudes (NDC scales ~1e-3, the perspective
/// w-row ~1e-4, translations ~1e3), so keep more precision but still avoid
/// scientific notation (JSON.parse accepts it, but org.json is stricter
/// about some forms — and tiny values can round to noise).
private func matrixNum(_ value: Double) -> String {
    if value == 0 { return "0" }
    let rounded = (value * 1e9).rounded() / 1e9
    if rounded == 0 { return "0.000000001" }
    if rounded == rounded.rounded() && abs(rounded) < 1e15 {
        return "\(Int(rounded))"
    }
    var text = "\(rounded)"
    if text.contains("e") || text.contains("E") {
        // Expand the rare exponent form manually: values here are < 1.
        text = expandSmallDecimal(rounded)
    }
    return text
}

/// Render a small (|v| < 1) double as plain decimal digits.
private func expandSmallDecimal(_ value: Double) -> String {
    let negative = value < 0
    var magnitude = abs(value)
    var digits = ""
    for _ in 0..<12 {
        magnitude *= 10
        let digit = Int(magnitude)
        digits += "\(digit)"
        magnitude -= Double(digit)
    }
    return (negative ? "-0." : "0.") + digits
}
