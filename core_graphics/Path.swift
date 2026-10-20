// Isomer's CoreGraphics: CGPath and CGMutablePath as data. Paths are built
// from moves, lines, quadratic and cubic Bézier curves and closes, the
// elements CoreGraphics itself stores; rectangles, ellipses, rounded
// rectangles and arcs become those elements as CoreGraphics makes them
// (arcs and ellipses as cubic curves). A path can be read back
// (`applyWithBlock`), measured (`boundingBox`, `boundingBoxOfPath`) and
// hit-tested (`contains`). Stroking, dashing, flattening and the path
// boolean operations are not provided yet (docs/parity/CoreGraphics.md).

#if ISOMER_CORELIBS_FOUNDATION
// Linux and Windows: CGFloat, CGPoint, CGSize and CGRect are
// swift-corelibs-foundation's; this module adds the rest.
import Foundation
#endif

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Android)
import Android
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Darwin)
import Darwin
#endif

@frozen
public enum CGLineJoin: Int32, Sendable {
    case miter = 0
    case round = 1
    case bevel = 2
}

@frozen
public enum CGLineCap: Int32, Sendable {
    case butt = 0
    case round = 1
    case square = 2
}

/// How a path's inside is decided where it crosses itself.
@frozen
public enum CGPathFillRule: Int, Sendable {
    case winding = 0
    case evenOdd = 1
}

@frozen
public enum CGPathElementType: Int32, Sendable {
    case moveToPoint = 0
    case addLineToPoint = 1
    case addQuadCurveToPoint = 2
    case addCurveToPoint = 3
    case closeSubpath = 4
}

/// One element of a path, as `applyWithBlock` hands it out: its kind and
/// its points (one for a move or a line, two for a quadratic curve, three
/// for a cubic one, none for a close).
public struct CGPathElement {
    public var type: CGPathElementType
    public var points: UnsafeMutablePointer<CGPoint>

    public init(type: CGPathElementType, points: UnsafeMutablePointer<CGPoint>) {
        self.type = type
        self.points = points
    }
}

/// An immutable path.
public class CGPath: Hashable, @unchecked Sendable {
    /// One stored element: what CoreGraphics keeps.
    enum Element: Hashable {
        case move(CGPoint)
        case line(CGPoint)
        case quad(CGPoint, CGPoint)
        case cubic(CGPoint, CGPoint, CGPoint)
        case close

        var points: [CGPoint] {
            switch self {
            case .move(let p), .line(let p): return [p]
            case .quad(let c, let p): return [c, p]
            case .cubic(let c1, let c2, let p): return [c1, c2, p]
            case .close: return []
            }
        }

        var type: CGPathElementType {
            switch self {
            case .move: return .moveToPoint
            case .line: return .addLineToPoint
            case .quad: return .addQuadCurveToPoint
            case .cubic: return .addCurveToPoint
            case .close: return .closeSubpath
            }
        }

        func applying(_ t: CGAffineTransform) -> Element {
            switch self {
            case .move(let p): return .move(p.applying(t))
            case .line(let p): return .line(p.applying(t))
            case .quad(let c, let p): return .quad(c.applying(t), p.applying(t))
            case .cubic(let c1, let c2, let p): return .cubic(c1.applying(t), c2.applying(t), p.applying(t))
            case .close: return .close
            }
        }
    }

    var elements: [Element]

    init(elements: [Element]) {
        self.elements = elements
    }

    /// A rectangle (CGPathCreateWithRect).
    public convenience init(rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let path = CGMutablePath()
        path.addRect(rect, transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    /// An ellipse in a rectangle (CGPathCreateWithEllipseInRect).
    public convenience init(ellipseIn rect: CGRect, transform: UnsafePointer<CGAffineTransform>?) {
        let path = CGMutablePath()
        path.addEllipse(in: rect, transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    /// A rounded rectangle (CGPathCreateWithRoundedRect).
    public convenience init(
        roundedRect rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat,
        transform: UnsafePointer<CGAffineTransform>?
    ) {
        let path = CGMutablePath()
        path.addRoundedRect(
            in: rect, cornerWidth: cornerWidth, cornerHeight: cornerHeight,
            transform: transform?.pointee ?? .identity)
        self.init(elements: path.elements)
    }

    public func copy() -> CGPath? {
        CGPath(elements: elements)
    }

    public func copy(using transform: UnsafePointer<CGAffineTransform>?) -> CGPath? {
        guard let t = transform?.pointee else { return copy() }
        return CGPath(elements: elements.map { $0.applying(t) })
    }

    public func mutableCopy() -> CGMutablePath? {
        CGMutablePath(elements: elements)
    }

    public func mutableCopy(using transform: UnsafePointer<CGAffineTransform>?) -> CGMutablePath? {
        guard let t = transform?.pointee else { return mutableCopy() }
        return CGMutablePath(elements: elements.map { $0.applying(t) })
    }

    public var isEmpty: Bool { elements.isEmpty }

    /// Whether the path is exactly one rectangle; if so, which
    /// (CGPathIsRect).
    public func isRect(_ rect: UnsafeMutablePointer<CGRect>?) -> Bool {
        var points: [CGPoint] = []
        for (index, element) in elements.enumerated() {
            switch element {
            case .move(let p) where index == 0: points.append(p)
            case .line(let p) where index > 0: points.append(p)
            case .close where index == elements.count - 1: break
            default: return false
            }
        }
        if points.count == 5, points[4] == points[0] { points.removeLast() }
        guard points.count == 4 else { return false }
        let horizontalFirst = points[0].y == points[1].y && points[1].x == points[2].x
            && points[2].y == points[3].y && points[3].x == points[0].x
        let verticalFirst = points[0].x == points[1].x && points[1].y == points[2].y
            && points[2].x == points[3].x && points[3].y == points[0].y
        guard horizontalFirst || verticalFirst else { return false }
        if let rect {
            let xs = points.map(\.x), ys = points.map(\.y)
            rect.pointee = CGRect(
                x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        return true
    }

    /// The end of the last element, or `.zero` for an empty path.
    public var currentPoint: CGPoint {
        var start = CGPoint.zero
        var current = CGPoint.zero
        for element in elements {
            switch element {
            case .move(let p):
                start = p
                current = p
            case .close:
                current = start
            default:
                current = element.points.last!
            }
        }
        return current
    }

    /// The smallest rectangle holding every point of the path, Bézier
    /// control points included (CGPathGetBoundingBox).
    public var boundingBox: CGRect {
        let points = elements.flatMap(\.points)
        return CGPath.bounds(of: points)
    }

    /// The smallest rectangle holding the path's drawn outline, without the
    /// curves' control points (CGPathGetPathBoundingBox).
    public var boundingBoxOfPath: CGRect {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        for element in elements {
            switch element {
            case .move(let p):
                points.append(p)
                current = p
                start = p
            case .line(let p):
                points.append(p)
                current = p
            case .quad(let c, let p):
                points.append(p)
                for t in CGPath.quadExtrema(current, c, p) {
                    points.append(CGPath.quadPoint(current, c, p, t))
                }
                current = p
            case .cubic(let c1, let c2, let p):
                points.append(p)
                for t in CGPath.cubicExtrema(current, c1, c2, p) {
                    points.append(CGPath.cubicPoint(current, c1, c2, p, t))
                }
                current = p
            case .close:
                current = start
            }
        }
        return CGPath.bounds(of: points)
    }

    /// Calls `block` with each element in order.
    public func applyWithBlock(_ block: (UnsafePointer<CGPathElement>) -> Void) {
        let buffer = UnsafeMutablePointer<CGPoint>.allocate(capacity: 3)
        defer { buffer.deallocate() }
        for element in elements {
            let points = element.points
            buffer.initialize(repeating: .zero, count: 3)
            for (index, point) in points.enumerated() { buffer[index] = point }
            var pathElement = CGPathElement(type: element.type, points: buffer)
            withUnsafePointer(to: &pathElement) { block($0) }
        }
    }

    /// Whether `point` is inside the path, by `rule`, with the path
    /// transformed by `transform` first.
    public func contains(
        _ point: CGPoint, using rule: CGPathFillRule = .winding, transform: CGAffineTransform = .identity
    ) -> Bool {
        var winding = 0
        var crossings = 0
        for polygon in flattenedSubpaths(transform: transform) {
            guard polygon.count > 1 else { continue }
            for index in polygon.indices {
                let a = polygon[index]
                let b = polygon[(index + 1) % polygon.count]
                if (a.y <= point.y) != (b.y <= point.y) {
                    let x = a.x + (point.y - a.y) / (b.y - a.y) * (b.x - a.x)
                    if point.x < x {
                        crossings += 1
                        winding += b.y > a.y ? 1 : -1
                    }
                }
            }
        }
        switch rule {
        case .winding: return winding != 0
        case .evenOdd: return crossings % 2 == 1
        }
    }

    public static func == (lhs: CGPath, rhs: CGPath) -> Bool {
        lhs.elements == rhs.elements
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(elements)
    }

    // MARK: Geometry helpers

    /// Each subpath as a closed polygon, curves flattened.
    func flattenedSubpaths(transform: CGAffineTransform) -> [[CGPoint]] {
        var polygons: [[CGPoint]] = []
        var polygon: [CGPoint] = []
        var current = CGPoint.zero
        for element in elements.map({ $0.applying(transform) }) {
            switch element {
            case .move(let p):
                if !polygon.isEmpty { polygons.append(polygon) }
                polygon = [p]
                current = p
            case .line(let p):
                if polygon.isEmpty { polygon = [current] }
                polygon.append(p)
                current = p
            case .quad(let c, let p):
                if polygon.isEmpty { polygon = [current] }
                for step in 1...16 {
                    polygon.append(CGPath.quadPoint(current, c, p, CGFloat(step) / 16))
                }
                current = p
            case .cubic(let c1, let c2, let p):
                if polygon.isEmpty { polygon = [current] }
                for step in 1...24 {
                    polygon.append(CGPath.cubicPoint(current, c1, c2, p, CGFloat(step) / 24))
                }
                current = p
            case .close:
                if let first = polygon.first { current = first }
                if !polygon.isEmpty { polygons.append(polygon) }
                polygon = []
            }
        }
        if !polygon.isEmpty { polygons.append(polygon) }
        return polygons
    }

    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x)
            maxX = max(maxX, p.x)
            minY = min(minY, p.y)
            maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    static func quadPoint(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x,
            y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y)
    }

    static func cubicPoint(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(
            x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
            y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
    }

    /// Where a quadratic curve's x or y turns, in (0, 1).
    static func quadExtrema(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint) -> [CGFloat] {
        var ts: [CGFloat] = []
        for (a, b, d) in [(p0.x, c.x, p1.x), (p0.y, c.y, p1.y)] {
            let denominator = a - 2 * b + d
            if denominator != 0 {
                let t = (a - b) / denominator
                if t > 0 && t < 1 { ts.append(t) }
            }
        }
        return ts
    }

    /// Where a cubic curve's x or y turns, in (0, 1).
    static func cubicExtrema(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint) -> [CGFloat] {
        var ts: [CGFloat] = []
        for (a, b, c, d) in [(p0.x, c1.x, c2.x, p1.x), (p0.y, c1.y, c2.y, p1.y)] {
            // The derivative's coefficients: qa·t² + qb·t + qc.
            let qa = 3 * (-a + 3 * b - 3 * c + d)
            let qb = 6 * (a - 2 * b + c)
            let qc = 3 * (b - a)
            if qa == 0 {
                if qb != 0 {
                    let t = -qc / qb
                    if t > 0 && t < 1 { ts.append(t) }
                }
                continue
            }
            let discriminant = qb * qb - 4 * qa * qc
            if discriminant < 0 { continue }
            let root = CGFloat(discriminant.native.squareRoot())
            for t in [(-qb + root) / (2 * qa), (-qb - root) / (2 * qa)] where t > 0 && t < 1 {
                ts.append(t)
            }
        }
        return ts
    }
}

/// A path that can be added to.
public final class CGMutablePath: CGPath, @unchecked Sendable {
    public init() {
        super.init(elements: [])
    }

    override init(elements: [Element]) {
        super.init(elements: elements)
    }

    private var hasCurrentPoint: Bool {
        guard let last = elements.last else { return false }
        if case .close = last { return false }
        return true
    }

    public func move(to point: CGPoint, transform: CGAffineTransform = .identity) {
        elements.append(.move(point.applying(transform)))
    }

    public func addLine(to point: CGPoint, transform: CGAffineTransform = .identity) {
        startIfNeeded()
        elements.append(.line(point.applying(transform)))
    }

    public func addQuadCurve(to end: CGPoint, control: CGPoint, transform: CGAffineTransform = .identity) {
        startIfNeeded()
        elements.append(.quad(control.applying(transform), end.applying(transform)))
    }

    public func addCurve(
        to end: CGPoint, control1: CGPoint, control2: CGPoint, transform: CGAffineTransform = .identity
    ) {
        startIfNeeded()
        elements.append(.cubic(control1.applying(transform), control2.applying(transform), end.applying(transform)))
    }

    public func closeSubpath() {
        if hasCurrentPoint { elements.append(.close) }
    }

    public func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        move(to: CGPoint(x: r.minX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY), transform: transform)
        addLine(to: CGPoint(x: r.minX, y: r.maxY), transform: transform)
        closeSubpath()
    }

    public func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }

    public func addLines(between points: [CGPoint], transform: CGAffineTransform = .identity) {
        guard let first = points.first else { return }
        move(to: first, transform: transform)
        for point in points.dropFirst() { addLine(to: point, transform: transform) }
    }

    /// An ellipse as four cubic curves, from the rectangle's right middle.
    public func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        let r = rect.standardized
        let k: CGFloat = 0.5522847498307936  // 4/3·(√2 − 1): a quarter circle as one cubic
        let rx = r.width / 2, ry = r.height / 2
        let cx = r.midX, cy = r.midY
        move(to: CGPoint(x: cx + rx, y: cy), transform: transform)
        addCurve(
            to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + k * ry),
            control2: CGPoint(x: cx + k * rx, y: cy + ry), transform: transform)
        addCurve(
            to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - k * rx, y: cy + ry),
            control2: CGPoint(x: cx - rx, y: cy + k * ry), transform: transform)
        addCurve(
            to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - k * ry),
            control2: CGPoint(x: cx - k * rx, y: cy - ry), transform: transform)
        addCurve(
            to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + k * rx, y: cy - ry),
            control2: CGPoint(x: cx + rx, y: cy - k * ry), transform: transform)
        closeSubpath()
    }

    public func addRoundedRect(
        in rect: CGRect, cornerWidth: CGFloat, cornerHeight: CGFloat, transform: CGAffineTransform = .identity
    ) {
        let r = rect.standardized
        let cw = min(max(cornerWidth, 0), r.width / 2)
        let ch = min(max(cornerHeight, 0), r.height / 2)
        if cw == 0 || ch == 0 {
            addRect(r, transform: transform)
            return
        }
        let k: CGFloat = 0.5522847498307936
        move(to: CGPoint(x: r.maxX, y: r.midY), transform: transform)
        addLine(to: CGPoint(x: r.maxX, y: r.maxY - ch), transform: transform)
        addCurve(
            to: CGPoint(x: r.maxX - cw, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - ch + k * ch),
            control2: CGPoint(x: r.maxX - cw + k * cw, y: r.maxY), transform: transform)
        addLine(to: CGPoint(x: r.minX + cw, y: r.maxY), transform: transform)
        addCurve(
            to: CGPoint(x: r.minX, y: r.maxY - ch), control1: CGPoint(x: r.minX + cw - k * cw, y: r.maxY),
            control2: CGPoint(x: r.minX, y: r.maxY - ch + k * ch), transform: transform)
        addLine(to: CGPoint(x: r.minX, y: r.minY + ch), transform: transform)
        addCurve(
            to: CGPoint(x: r.minX + cw, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + ch - k * ch),
            control2: CGPoint(x: r.minX + cw - k * cw, y: r.minY), transform: transform)
        addLine(to: CGPoint(x: r.maxX - cw, y: r.minY), transform: transform)
        addCurve(
            to: CGPoint(x: r.maxX, y: r.minY + ch), control1: CGPoint(x: r.maxX - cw + k * cw, y: r.minY),
            control2: CGPoint(x: r.maxX, y: r.minY + ch - k * ch), transform: transform)
        closeSubpath()
    }

    /// An arc of `delta` radians from `startAngle` (positive: towards +y).
    public func addRelativeArc(
        center: CGPoint, radius: CGFloat, startAngle: CGFloat, delta: CGFloat,
        transform: CGAffineTransform = .identity
    ) {
        appendArc(center: center, radius: radius, start: startAngle, sweep: delta, transform: transform)
    }

    /// An arc from `startAngle` to `endAngle`; `clockwise` in CoreGraphics'
    /// own (y-up) sense, which is counterclockwise on a y-down screen.
    public func addArc(
        center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool,
        transform: CGAffineTransform = .identity
    ) {
        let twoPi = 2 * CGFloat.pi
        var sweep = endAngle - startAngle
        if clockwise {
            if sweep > 0 { sweep = sweep.truncatingRemainder(dividingBy: twoPi) - twoPi }
            if sweep < -twoPi { sweep = -twoPi }
            if sweep == 0 && endAngle != startAngle { sweep = -twoPi }
        } else {
            if sweep < 0 { sweep = sweep.truncatingRemainder(dividingBy: twoPi) + twoPi }
            if sweep > twoPi { sweep = twoPi }
            if sweep == 0 && endAngle != startAngle { sweep = twoPi }
        }
        appendArc(center: center, radius: radius, start: startAngle, sweep: sweep, transform: transform)
    }

    /// An arc of `radius` tangent to the lines from the current point to
    /// `tangent1End` and from there to `tangent2End`, after a line to its
    /// start (CGPathAddArcToPoint).
    public func addArc(
        tangent1End: CGPoint, tangent2End: CGPoint, radius: CGFloat, transform: CGAffineTransform = .identity
    ) {
        let inverse = transform.inverted()
        let p0 = hasCurrentPoint ? currentPoint.applying(inverse) : tangent1End
        let p1 = tangent1End, p2 = tangent2End
        let v1 = CGVector(dx: p0.x - p1.x, dy: p0.y - p1.y)
        let v2 = CGVector(dx: p2.x - p1.x, dy: p2.y - p1.y)
        let l1 = CGFloat((v1.dx * v1.dx + v1.dy * v1.dy).native.squareRoot())
        let l2 = CGFloat((v2.dx * v2.dx + v2.dy * v2.dy).native.squareRoot())
        let cross = v1.dx * v2.dy - v1.dy * v2.dx
        if l1 == 0 || l2 == 0 || cross == 0 || radius == 0 {
            addLine(to: p1, transform: transform)
            return
        }
        let cosine = (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2)
        let angle = CGFloat(acos(Double(max(-1, min(1, cosine.native)))))
        let tangentLength = radius / CGFloat(tan(Double((angle / 2).native)))
        let t1 = CGPoint(x: p1.x + v1.dx / l1 * tangentLength, y: p1.y + v1.dy / l1 * tangentLength)
        let t2 = CGPoint(x: p1.x + v2.dx / l2 * tangentLength, y: p1.y + v2.dy / l2 * tangentLength)
        // The center lies along the bisector, `radius` from both tangents.
        let bisector = CGVector(dx: v1.dx / l1 + v2.dx / l2, dy: v1.dy / l1 + v2.dy / l2)
        let bisectorLength = CGFloat((bisector.dx * bisector.dx + bisector.dy * bisector.dy).native.squareRoot())
        let centerDistance = CGFloat(((radius * radius + tangentLength * tangentLength).native).squareRoot())
        let center = CGPoint(
            x: p1.x + bisector.dx / bisectorLength * centerDistance,
            y: p1.y + bisector.dy / bisectorLength * centerDistance)
        let start = CGFloat(atan2(Double((t1.y - center.y).native), Double((t1.x - center.x).native)))
        let end = CGFloat(atan2(Double((t2.y - center.y).native), Double((t2.x - center.x).native)))
        var sweep = end - start
        if sweep > .pi { sweep -= 2 * .pi }
        if sweep < -.pi { sweep += 2 * .pi }
        addLine(to: t1, transform: transform)
        appendArc(center: center, radius: radius, start: start, sweep: sweep, transform: transform)
    }

    public func addPath(_ path: CGPath, transform: CGAffineTransform = .identity) {
        elements.append(contentsOf: path.elements.map { $0.applying(transform) })
    }

    // MARK: Helpers

    /// A path with no current point begins where its first line or curve
    /// would: CoreGraphics adds the move.
    private func startIfNeeded() {
        if !hasCurrentPoint {
            let point = elements.isEmpty ? CGPoint.zero : currentPoint
            elements.append(.move(point))
        }
    }

    /// An arc as cubic curves of at most a quarter turn each, joined to the
    /// path by a line (or begun with a move).
    private func appendArc(
        center: CGPoint, radius: CGFloat, start: CGFloat, sweep: CGFloat, transform: CGAffineTransform
    ) {
        func point(_ angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + radius * CGFloat(cos(angle.native)),
                y: center.y + radius * CGFloat(sin(angle.native)))
        }
        let first = point(start)
        if hasCurrentPoint {
            addLine(to: first, transform: transform)
        } else {
            move(to: first, transform: transform)
        }
        if sweep == 0 { return }
        let segments = max(1, Int((abs(sweep) / (.pi / 2)).native.rounded(.up)))
        let step = sweep / CGFloat(segments)
        let handle = 4.0 / 3.0 * CGFloat(tan((step / 4).native)) * radius
        var angle = start
        for _ in 0..<segments {
            let next = angle + step
            let from = point(angle), to = point(next)
            let control1 = CGPoint(
                x: from.x - handle * CGFloat(sin(angle.native)), y: from.y + handle * CGFloat(cos(angle.native)))
            let control2 = CGPoint(
                x: to.x + handle * CGFloat(sin(next.native)), y: to.y - handle * CGFloat(cos(next.native)))
            addCurve(to: to, control1: control1, control2: control2, transform: transform)
            angle = next
        }
    }
}
