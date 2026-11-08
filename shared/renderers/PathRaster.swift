// Coverage of a path of lines, in device pixels, for the renderers that draw
// an app's `Path` themselves (SwiftGPURenderer: its rects, rounded rects and
// ellipses go through the SDF rect pipeline; a polygon has no pipeline of
// its own, so it is covered here and drawn as a texture). Plain Swift with
// no math library (wasm's Foundation has none): square roots only.

package enum PathRaster {
    /// Rows of samples a pixel (horizontal coverage is exact).
    static let rowsPerPixel = 4

    /// How much of each pixel the subpaths cover, filled by the non-zero
    /// rule (every subpath closed, as a fill closes them). `xs[i]`/`ys[i]`
    /// are subpath i's points, in pixels from the raster's corner.
    package static func fill(xs: [[Double]], ys: [[Double]], width: Int, height: Int) -> [Float] {
        var coverage = [Float](repeating: 0, count: width * height)
        // Each edge as (x0, y0, x1, y1, winding), downward.
        var edges: [(x0: Double, y0: Double, x1: Double, y1: Double, dir: Int)] = []
        for (ring, ringY) in zip(xs, ys) where ring.count > 1 {
            for i in 0..<ring.count {
                let j = (i + 1) % ring.count
                let (ax, ay, bx, by) = (ring[i], ringY[i], ring[j], ringY[j])
                if ay == by { continue }
                edges.append(ay < by ? (ax, ay, bx, by, 1) : (bx, by, ax, ay, -1))
            }
        }
        guard !edges.isEmpty else { return coverage }
        let share = Float(1) / Float(rowsPerPixel)
        var crossings: [(x: Double, dir: Int)] = []
        for row in 0..<height {
            for sub in 0..<rowsPerPixel {
                let y = Double(row) + (Double(sub) + 0.5) / Double(rowsPerPixel)
                crossings.removeAll(keepingCapacity: true)
                for edge in edges where edge.y0 <= y && y < edge.y1 {
                    let t = (y - edge.y0) / (edge.y1 - edge.y0)
                    crossings.append((edge.x0 + (edge.x1 - edge.x0) * t, edge.dir))
                }
                guard crossings.count > 1 else { continue }
                crossings.sort { $0.x < $1.x }
                var winding = 0
                for k in 0..<(crossings.count - 1) {
                    winding += crossings[k].dir
                    guard winding != 0 else { continue }
                    let from = max(0, crossings[k].x), to = min(Double(width), crossings[k + 1].x)
                    guard to > from else { continue }
                    var pixel = Int(from)
                    while Double(pixel) < to, pixel < width {
                        let overlap = min(to, Double(pixel + 1)) - max(from, Double(pixel))
                        if overlap > 0 { coverage[row * width + pixel] += share * Float(overlap) }
                        pixel += 1
                    }
                }
            }
        }
        for i in coverage.indices where coverage[i] > 1 { coverage[i] = 1 }
        return coverage
    }

    /// How much of each pixel a stroke `halfWidth` either side of the
    /// segments covers (round joins and ends, from the distance to the
    /// nearest segment).
    package static func stroke(
        xs: [[Double]], ys: [[Double]], closed: [Bool], halfWidth: Double, width: Int, height: Int
    ) -> [Float] {
        var coverage = [Float](repeating: 0, count: width * height)
        func segment(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) {
            let reach = halfWidth + 1
            let left = max(0, Int(min(ax, bx) - reach)), right = min(width - 1, Int(max(ax, bx) + reach))
            let top = max(0, Int(min(ay, by) - reach)), bottom = min(height - 1, Int(max(ay, by) + reach))
            guard left <= right, top <= bottom else { return }
            let dx = bx - ax, dy = by - ay
            let length2 = dx * dx + dy * dy
            for py in top...bottom {
                for px in left...right {
                    let cx = Double(px) + 0.5, cy = Double(py) + 0.5
                    var t = length2 > 0 ? ((cx - ax) * dx + (cy - ay) * dy) / length2 : 0
                    t = min(1, max(0, t))
                    let ex = cx - (ax + dx * t), ey = cy - (ay + dy * t)
                    let distance = (ex * ex + ey * ey).squareRoot()
                    let covered = Float(min(1, max(0, halfWidth + 0.5 - distance)))
                    let index = py * width + px
                    if covered > coverage[index] { coverage[index] = covered }
                }
            }
        }
        for (n, (ring, ringY)) in zip(xs, ys).enumerated() where !ring.isEmpty {
            if ring.count == 1 { segment(ring[0], ringY[0], ring[0], ringY[0]); continue }
            for i in 0..<(ring.count - 1) { segment(ring[i], ringY[i], ring[i + 1], ringY[i + 1]) }
            if n < closed.count, closed[n] {
                segment(ring[ring.count - 1], ringY[ring.count - 1], ring[0], ringY[0])
            }
        }
        return coverage
    }
}
