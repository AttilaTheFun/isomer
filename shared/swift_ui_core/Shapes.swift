import Foundation

public protocol Shape: View {
    /// The shape's outline in `rect`, as SwiftUI asks for it. An app's own
    /// shape implements this and nothing else.
    nonisolated func path(in rect: CGRect) -> Path
}

/// A built-in shape, which the hosts draw by kind (a rectangle, a circle…).
protocol PrimitiveShape: Shape {
    nonisolated var primitiveKind: ShapeKind { get }
}

extension Shape {
    nonisolated public var body: Never { fatalError("primitive view") }

    /// What the hosts draw: a built-in shape's kind, or an app's own shape's
    /// path, asked for once in the unit square and scaled to the frame the
    /// view gets. Geometry proportional to the rect (a QR code's grid, a
    /// chevron) draws exactly; a shape that wants a fixed inset or
    /// `min(width, height)` in a non-square frame should be given its
    /// aspect ratio (`.aspectRatio(1, contentMode: .fit)`).
    nonisolated var shapeKind: ShapeKind {
        (self as? any PrimitiveShape)?.primitiveKind ?? .path(path(in: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    /// `.trim(from:to:)`: the fraction of the shape's outline to draw, from
    /// its start (a circle's is at 3 o'clock, as in SwiftUI). Hosts draw a
    /// trimmed circle as an arc; other shapes ignore it for now. `fill` and
    /// `stroke` find the range on the shape they are called on (`shapeTrim`).
    nonisolated public func trim(from start: CGFloat = 0, to end: CGFloat = 1) -> some Shape {
        _TrimmedShape(kind: shapeKind, start: start, end: end)
    }

    /// The `.trim` range the shape came through, if any.
    nonisolated var shapeTrim: (CGFloat, CGFloat)? {
        (self as? _TrimmedShape).map { ($0.start, $0.end) } ?? (self as? _StrokedShape)?.trim
    }

    /// The shape filled with `content`: a colour (adaptive and named
    /// colours kept as they are), a gradient, a material.
    @_disfavoredOverload
    nonisolated public func fill<S: ShapeStyle>(_ content: S, style: FillStyle = FillStyle()) -> some View {
        _ShapeFill(kind: shapeKind, content: content, trim: shapeTrim)
    }

    /// The shape filled with the foreground style.
    nonisolated public func fill(style: FillStyle = FillStyle()) -> some View {
        _ForegroundFill(kind: shapeKind)
    }

    /// `stroke(_:lineWidth:)`: the outline in `content` (a colour; another
    /// style draws as its colour).
    nonisolated public func stroke<S: ShapeStyle>(
        _ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true
    ) -> StrokeShapeView<Self, S, EmptyView> {
        StrokeShapeView(shape: self, style: content, strokeStyle: StrokeStyle(lineWidth: lineWidth),
                        isAntialiased: antialiased, background: EmptyView())
    }

    /// `stroke(_:style:)`: the outline at the style's width (its caps,
    /// joins and dashes are the hosts' plain line's).
    nonisolated public func stroke<S: ShapeStyle>(
        _ content: S, style: StrokeStyle, antialiased: Bool = true
    ) -> StrokeShapeView<Self, S, EmptyView> {
        StrokeShapeView(shape: self, style: content, strokeStyle: style, isAntialiased: antialiased, background: EmptyView())
    }

    /// `stroke(lineWidth:)`: the outline, a shape of its own (as Apple's),
    /// drawn in the foreground colour.
    nonisolated public func stroke(lineWidth: CGFloat = 1) -> some Shape {
        _StrokedShape(kind: shapeKind, lineWidth: lineWidth, trim: shapeTrim)
    }

    nonisolated public func stroke(style: StrokeStyle) -> some Shape {
        _StrokedShape(kind: shapeKind, lineWidth: style.lineWidth, trim: shapeTrim)
    }

}

/// A shape that can be inset (and so stroked inside its edge).
public protocol InsettableShape: Shape {
    associatedtype InsetShape: InsettableShape
    nonisolated func inset(by amount: CGFloat) -> InsetShape
}

extension InsettableShape {
    /// `strokeBorder(_:lineWidth:)`: the outline drawn inside the shape's
    /// edge (here, on it).
    nonisolated public func strokeBorder<S: ShapeStyle>(_ content: S, lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        _ShapeView(kind: shapeKind, fill: nil, stroke: (resolveStyleColor(content), lineWidth))
    }

    nonisolated public func strokeBorder<S: ShapeStyle>(_ content: S, style: StrokeStyle, antialiased: Bool = true) -> some View {
        _ShapeView(kind: shapeKind, fill: nil, stroke: (resolveStyleColor(content), style.lineWidth))
    }

    nonisolated public func strokeBorder(lineWidth: CGFloat = 1, antialiased: Bool = true) -> some View {
        _ForegroundStroke(kind: shapeKind, lineWidth: lineWidth)
    }

    nonisolated public func strokeBorder(style: StrokeStyle, antialiased: Bool = true) -> some View {
        _ForegroundStroke(kind: shapeKind, lineWidth: style.lineWidth)
    }
}

/// A shape filled with a style: a colour as a shape node (adaptive and
/// named colours kept), any other style as a gradient paint.
struct _ShapeFill<S: ShapeStyle> {
    let kind: ShapeKind
    let content: S
    /// The `.trim` range, when the shape came through one.
    var trim: (CGFloat, CGFloat)? = nil

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ShapeFill: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        if let color = styleColor(content) {
            var view = _ShapeView(kind: kind, fill: color, stroke: nil)
            view.trim = trim
            return view.makeNode(&ctx)
        }
        let unwrapped: any ShapeStyle = (content as? AnyShapeStyle)?.base ?? content
        return _GradientShapeView(kind: kind, paint: paint(of: unwrapped)).makeNode(&ctx)
    }
}

/// A shape filled with the foreground colour in effect.
struct _ForegroundFill {
    let kind: ShapeKind

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ForegroundFill: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        _ShapeView(kind: kind, fill: ctx.env.foregroundColor, stroke: nil).makeNode(&ctx)
    }
}

/// How a shape is filled: the even-odd rule, antialiasing (the hosts fill
/// non-zero and antialias whatever this says).
public struct FillStyle: Equatable, Sendable {
    public var isEOFilled: Bool
    public var isAntialiased: Bool
    public init(eoFill: Bool = false, antialiased: Bool = true) {
        isEOFilled = eoFill
        isAntialiased = antialiased
    }
}

/// How a shape's outline is drawn (`StrokeStyle`): its width is drawn; caps,
/// joins and dashes are taken for source compatibility.
public struct StrokeStyle: Equatable, Sendable {
    public var lineWidth: CGFloat
    public var lineCap: CGLineCap
    public var lineJoin: CGLineJoin
    public var miterLimit: CGFloat
    public var dash: [CGFloat]
    public var dashPhase: CGFloat

    public init(lineWidth: CGFloat = 1, lineCap: CGLineCap = .butt, lineJoin: CGLineJoin = .miter,
                miterLimit: CGFloat = 10, dash: [CGFloat] = [], dashPhase: CGFloat = 0) {
        self.lineWidth = lineWidth
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.miterLimit = miterLimit
        self.dash = dash
        self.dashPhase = dashPhase
    }
}

/// A shape's outline in the foreground colour in effect.
struct _ForegroundStroke {
    let kind: ShapeKind
    let lineWidth: CGFloat

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ForegroundStroke: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        _ShapeView(kind: kind, fill: nil, stroke: (ctx.env.foregroundColor, lineWidth)).makeNode(&ctx)
    }
}

extension _ForegroundStroke: View {}

struct _GradientShapeView {
    let kind: ShapeKind
    let paint: GradientPaint

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _GradientShapeView: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        RenderNode(kind: .gradient(kind, paint.withOpacity(ctx.env.opacity)))
    }
}

/// Apple's: a shape's outline in a style (what `stroke(_:lineWidth:)`
/// returns). Drawn at the stroke style's width in the style's colour.
public struct StrokeShapeView<Content: Shape, Style: ShapeStyle, Background: View> {
    let shape: Content
    let style: Style
    let strokeStyle: StrokeStyle
    let isAntialiased: Bool
    let background: Background

    nonisolated init(shape: Content, style: Style, strokeStyle: StrokeStyle, isAntialiased: Bool, background: Background) {
        self.shape = shape
        self.style = style
        self.strokeStyle = strokeStyle
        self.isAntialiased = isAntialiased
        self.background = background
    }

    public typealias Body = Never
}

extension StrokeShapeView: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var view = _ShapeView(kind: shape.shapeKind, fill: nil, stroke: (resolveStyleColor(style), strokeStyle.lineWidth))
        view.trim = shape.shapeTrim
        return view.makeNode(&ctx)
    }
}

extension StrokeShapeView: View {}

/// A shape with `.trim` applied; `fill` and `stroke` carry the range along.
struct _TrimmedShape {
    let kind: ShapeKind
    let start: CGFloat
    let end: CGFloat

    typealias Body = Never
    var primitiveKind: ShapeKind { kind }
    nonisolated func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

/// A shape's outline (`stroke(lineWidth:)`), drawn in the foreground colour.
/// Its path is the shape's: the hosts stroke it rather than fill an outline.
struct _StrokedShape {
    let kind: ShapeKind
    let lineWidth: CGFloat
    let trim: (CGFloat, CGFloat)?

    typealias Body = Never
    var primitiveKind: ShapeKind { kind }
    nonisolated func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

extension _StrokedShape: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var view = _ShapeView(kind: kind, fill: nil, stroke: (ctx.env.foregroundColor, lineWidth))
        view.trim = trim
        return view.makeNode(&ctx)
    }
}

public struct Rectangle {
    public init() {}
    public typealias Body = Never
    var primitiveKind: ShapeKind { .rectangle }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

public struct RoundedRectangle {
    package let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        self.cornerRadius = cornerRadius
    }

    public typealias Body = Never
    var primitiveKind: ShapeKind { .roundedRectangle(cornerRadius) }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

public struct Circle {
    public init() {}
    public typealias Body = Never
    var primitiveKind: ShapeKind { .circle }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

public struct Capsule {
    public init(style: RoundedCornerStyle = .continuous) {}
    public typealias Body = Never
    var primitiveKind: ShapeKind { .capsule }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

/// `Ellipse`: the ellipse that fills its frame.
public struct Ellipse {
    public init() {}
    public typealias Body = Never
    var primitiveKind: ShapeKind { .path(Path(ellipseIn: CGRect(x: 0, y: 0, width: 1, height: 1))) }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

/// An outline: SwiftUI's `Path`, the subset the hosts draw — subpaths of
/// lines, and rects, rounded rects and ellipses added whole. The host
/// scales a custom shape's path from the unit square to the frame; the
/// SwiftGPU renderer draws its rects, rounded rects and ellipses (a
/// polygon of lines is not filled there yet).
public struct Path: Equatable, Sendable {
    /// A path's parts as Apple's `Path.forEach` gives them.
    public enum Element: Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case quadCurve(to: CGPoint, control: CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case closeSubpath
    }

    /// What the path holds: lines, and the shapes the hosts draw whole
    /// (a rect, a rounded rect, an ellipse) kept as they are.
    enum Segment: Equatable, Sendable {
        case move(to: CGPoint)
        case line(to: CGPoint)
        case rect(CGRect)
        case roundedRect(CGRect, cornerRadius: CGFloat)
        case ellipse(in: CGRect)
        case closeSubpath
    }

    private(set) var elements: [Segment] = []

    public init() {}
    public init(_ rect: CGRect) { addRect(rect) }
    public init(roundedRect rect: CGRect, cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) {
        addRoundedRect(in: rect, cornerSize: CGSize(width: cornerRadius, height: cornerRadius), style: style)
    }
    public init(roundedRect rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous) {
        addRoundedRect(in: rect, cornerSize: cornerSize, style: style)
    }
    public init(ellipseIn rect: CGRect) { addEllipse(in: rect) }
    public init(_ callback: (inout Path) -> Void) { callback(&self) }

    /// A built-in kind's outline in `rect`.
    init(_ kind: ShapeKind, in rect: CGRect) {
        switch kind {
        case .rectangle: addRect(rect)
        case .roundedRectangle(let radius): addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        case .circle:
            let d = min(rect.width, rect.height)
            addEllipse(in: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d))
        case .capsule:
            let radius = min(rect.width, rect.height) / 2
            addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        case .path(let path): elements = path.elements
        }
    }

    public var isEmpty: Bool { elements.isEmpty }

    /// The smallest rect around every point of the path.
    public var boundingRect: CGRect {
        var minX = CGFloat.infinity, minY = CGFloat.infinity, maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        func take(_ p: CGPoint) { minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y) }
        func take(_ r: CGRect) { take(r.origin); take(CGPoint(x: r.maxX, y: r.maxY)) }
        for element in elements {
            switch element {
            case .move(let p), .line(let p): take(p)
            case .rect(let r), .roundedRect(let r, _), .ellipse(let r): take(r)
            case .closeSubpath: break
            }
        }
        return minX <= maxX ? CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY) : .zero
    }

    public mutating func move(to point: CGPoint) { elements.append(.move(to: point)) }
    public mutating func addLine(to point: CGPoint) { elements.append(.line(to: point)) }
    public mutating func addLines(_ points: [CGPoint]) {
        for (i, point) in points.enumerated() { if i == 0 { move(to: point) } else { addLine(to: point) } }
    }
    public mutating func addRect(_ rect: CGRect, transform: CGAffineTransform = .identity) {
        append(.rect(rect), transform)
    }
    public mutating func addRects(_ rects: [CGRect], transform: CGAffineTransform = .identity) {
        for rect in rects { addRect(rect, transform: transform) }
    }
    public mutating func addRoundedRect(
        in rect: CGRect, cornerSize: CGSize, style: RoundedCornerStyle = .continuous,
        transform: CGAffineTransform = .identity
    ) {
        append(.roundedRect(rect, cornerRadius: min(cornerSize.width, cornerSize.height)), transform)
    }
    public mutating func addEllipse(in rect: CGRect, transform: CGAffineTransform = .identity) {
        append(.ellipse(in: rect), transform)
    }
    public mutating func closeSubpath() { elements.append(.closeSubpath) }
    public mutating func addPath(_ path: Path, transform: CGAffineTransform = .identity) {
        for segment in path.elements { append(segment, transform) }
    }

    /// A segment, transformed: a whole shape stays one while the transform
    /// only moves it; otherwise it becomes the lines of its outline.
    private mutating func append(_ segment: Segment, _ transform: CGAffineTransform) {
        if transform.isIdentity {
            elements.append(segment)
            return
        }
        switch segment {
        case .move(let p): elements.append(.move(to: p.applying(transform)))
        case .line(let p): elements.append(.line(to: p.applying(transform)))
        case .closeSubpath: elements.append(.closeSubpath)
        case .rect, .roundedRect, .ellipse:
            let points = Path.outline(segment)
            for (i, p) in points.enumerated() {
                elements.append(i == 0 ? .move(to: p.applying(transform)) : .line(to: p.applying(transform)))
            }
            elements.append(.closeSubpath)
        }
    }

    /// A whole shape's outline as points (curves as short lines).
    static func outline(_ segment: Segment) -> [CGPoint] {
        switch segment {
        case .rect(let r):
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        case .ellipse(let r):
            return (0..<64).map { step in
                let angle = Double(step) / 64 * 2 * Double.pi
                return CGPoint(x: r.midX + r.width / 2 * CGFloat(_cosine(angle)),
                               y: r.midY + r.height / 2 * CGFloat(_sine(angle)))
            }
        case .roundedRect(let r, let radius):
            let radius = min(radius, min(r.width, r.height) / 2)
            var points: [CGPoint] = []
            let corners: [(CGPoint, Double)] = [
                (CGPoint(x: r.maxX - radius, y: r.minY + radius), -Double.pi / 2),
                (CGPoint(x: r.maxX - radius, y: r.maxY - radius), 0),
                (CGPoint(x: r.minX + radius, y: r.maxY - radius), Double.pi / 2),
                (CGPoint(x: r.minX + radius, y: r.minY + radius), Double.pi),
            ]
            for (center, start) in corners {
                for step in 0...8 {
                    let angle = start + Double(step) / 8 * Double.pi / 2
                    points.append(CGPoint(x: center.x + radius * CGFloat(_cosine(angle)),
                                          y: center.y + radius * CGFloat(_sine(angle))))
                }
            }
            return points
        case .move(let p), .line(let p): return [p]
        case .closeSubpath: return []
        }
    }

    /// Each part of the path, as Apple's `Path.Element`: a rect as its four
    /// lines, a rounded rect's corners and an ellipse as cubic curves.
    public func forEach(_ body: (Path.Element) -> Void) {
        // A quarter circle's control-point distance, per unit radius.
        let k: CGFloat = 0.5522847498
        for segment in elements {
            switch segment {
            case .move(let p): body(.move(to: p))
            case .line(let p): body(.line(to: p))
            case .closeSubpath: body(.closeSubpath)
            case .rect:
                for (i, p) in Path.outline(segment).enumerated() { body(i == 0 ? .move(to: p) : .line(to: p)) }
                body(.closeSubpath)
            case .ellipse(let r):
                let rx = r.width / 2, ry = r.height / 2, cx = r.midX, cy = r.midY
                body(.move(to: CGPoint(x: cx + rx, y: cy)))
                body(.curve(to: CGPoint(x: cx, y: cy + ry), control1: CGPoint(x: cx + rx, y: cy + ry * k), control2: CGPoint(x: cx + rx * k, y: cy + ry)))
                body(.curve(to: CGPoint(x: cx - rx, y: cy), control1: CGPoint(x: cx - rx * k, y: cy + ry), control2: CGPoint(x: cx - rx, y: cy + ry * k)))
                body(.curve(to: CGPoint(x: cx, y: cy - ry), control1: CGPoint(x: cx - rx, y: cy - ry * k), control2: CGPoint(x: cx - rx * k, y: cy - ry)))
                body(.curve(to: CGPoint(x: cx + rx, y: cy), control1: CGPoint(x: cx + rx * k, y: cy - ry), control2: CGPoint(x: cx + rx, y: cy - ry * k)))
                body(.closeSubpath)
            case .roundedRect(let r, let radius):
                let c = min(radius, min(r.width, r.height) / 2), d = c * k
                body(.move(to: CGPoint(x: r.minX + c, y: r.minY)))
                body(.line(to: CGPoint(x: r.maxX - c, y: r.minY)))
                body(.curve(to: CGPoint(x: r.maxX, y: r.minY + c), control1: CGPoint(x: r.maxX - c + d, y: r.minY), control2: CGPoint(x: r.maxX, y: r.minY + c - d)))
                body(.line(to: CGPoint(x: r.maxX, y: r.maxY - c)))
                body(.curve(to: CGPoint(x: r.maxX - c, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - c + d), control2: CGPoint(x: r.maxX - c + d, y: r.maxY)))
                body(.line(to: CGPoint(x: r.minX + c, y: r.maxY)))
                body(.curve(to: CGPoint(x: r.minX, y: r.maxY - c), control1: CGPoint(x: r.minX + c - d, y: r.maxY), control2: CGPoint(x: r.minX, y: r.maxY - c + d)))
                body(.line(to: CGPoint(x: r.minX, y: r.minY + c)))
                body(.curve(to: CGPoint(x: r.minX + c, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + c - d), control2: CGPoint(x: r.minX + c - d, y: r.minY)))
                body(.closeSubpath)
            }
        }
    }

    /// Where the path ends: the last point added (a closed subpath's
    /// start), nil for an empty path.
    public var currentPoint: CGPoint? {
        var start: CGPoint?
        var current: CGPoint?
        for element in elements {
            switch element {
            case .move(let p): start = p; current = p
            case .line(let p): current = p
            case .closeSubpath: current = start
            case .rect(let r), .roundedRect(let r, _), .ellipse(let r): start = r.origin; current = r.origin
            }
        }
        return current
    }

    // Curves are drawn as runs of short lines (the hosts draw lines), fine
    // enough that they read as curves at any size a view is drawn.

    /// A line to the curve's start when the path has a point, else a move.
    private mutating func begin(at point: CGPoint) {
        if currentPoint == nil { move(to: point) } else { addLine(to: point) }
    }

    /// `addArc(center:radius:startAngle:endAngle:clockwise:)`, as Core
    /// Graphics draws it: angles from the x axis toward y, `clockwise`
    /// sweeping toward smaller angles (which, y pointing down as it does
    /// here, turns counterclockwise on screen, as in SwiftUI).
    public mutating func addArc(
        center: CGPoint, radius: CGFloat, startAngle: Angle, endAngle: Angle, clockwise: Bool,
        transform: CGAffineTransform = .identity
    ) {
        let start = startAngle.radians, end = endAngle.radians
        var sweep = clockwise ? start - end : end - start
        let full = 2 * Double.pi
        sweep = sweep.truncatingRemainder(dividingBy: full)
        if sweep < 0 { sweep += full }
        if sweep == 0 && start != end { sweep = full }
        let direction: Double = clockwise ? -1 : 1
        let steps = Swift.max(1, Int((sweep / (Double.pi / 32)).rounded(.up)))
        func point(_ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * CGFloat(_cosine(angle)), y: center.y + radius * CGFloat(_sine(angle)))
                .applying(transform)
        }
        begin(at: point(start))
        for step in 1...steps { addLine(to: point(start + direction * sweep * Double(step) / Double(steps))) }
    }

    /// `addQuadCurve(to:control:)`: a quadratic Bézier from the current point.
    public mutating func addQuadCurve(to end: CGPoint, control: CGPoint) {
        let from = currentPoint ?? end
        if currentPoint == nil { move(to: end) }
        let steps = 24
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps), u = 1 - t
            addLine(to: CGPoint(x: u * u * from.x + 2 * u * t * control.x + t * t * end.x,
                                y: u * u * from.y + 2 * u * t * control.y + t * t * end.y))
        }
    }

    /// `addCurve(to:control1:control2:)`: a cubic Bézier from the current point.
    public mutating func addCurve(to end: CGPoint, control1: CGPoint, control2: CGPoint) {
        let from = currentPoint ?? end
        if currentPoint == nil { move(to: end) }
        let steps = 32
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps), u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            addLine(to: CGPoint(x: a * from.x + b * control1.x + c * control2.x + d * end.x,
                                y: a * from.y + b * control1.y + c * control2.y + d * end.y))
        }
    }

    /// The path scaled from the unit square to `rect` (what a host does).
    func scaled(to rect: CGRect) -> Path {
        func point(_ p: CGPoint) -> CGPoint { CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height) }
        func box(_ r: CGRect) -> CGRect { CGRect(x: rect.minX + r.minX * rect.width, y: rect.minY + r.minY * rect.height, width: r.width * rect.width, height: r.height * rect.height) }
        var out = Path()
        for element in elements {
            switch element {
            case .move(let p): out.elements.append(.move(to: point(p)))
            case .line(let p): out.elements.append(.line(to: point(p)))
            case .rect(let r): out.elements.append(.rect(box(r)))
            case .roundedRect(let r, let radius): out.elements.append(.roundedRect(box(r), cornerRadius: radius * min(rect.width, rect.height)))
            case .ellipse(let r): out.elements.append(.ellipse(in: box(r)))
            case .closeSubpath: out.elements.append(.closeSubpath)
            }
        }
        return out
    }

    /// The path as the tree carries it (the `path` param of a shape node):
    /// `M x y`, `L x y`, `Z`, `R x y w h`, `Q x y w h r`, `E x y w h`,
    /// space-separated, in the unit square.
    var serialized: String {
        // Through Double: under the full Foundation on wasm/Android CGFloat
        // is Foundation's own struct.
        func f(_ v: CGFloat) -> String {
            let rounded = (Double(v) * 100000).rounded() / 100000
            if rounded == rounded.rounded() { return String(Int(rounded)) }
            return String(rounded)
        }
        var parts: [String] = []
        for element in elements {
            switch element {
            case .move(let p): parts.append("M \(f(p.x)) \(f(p.y))")
            case .line(let p): parts.append("L \(f(p.x)) \(f(p.y))")
            case .rect(let r): parts.append("R \(f(r.minX)) \(f(r.minY)) \(f(r.width)) \(f(r.height))")
            case .roundedRect(let r, let radius): parts.append("Q \(f(r.minX)) \(f(r.minY)) \(f(r.width)) \(f(r.height)) \(f(radius))")
            case .ellipse(let r): parts.append("E \(f(r.minX)) \(f(r.minY)) \(f(r.width)) \(f(r.height))")
            case .closeSubpath: parts.append("Z")
            }
        }
        return parts.joined(separator: " ")
    }

    init?(serialized text: String) {
        let tokens = text.split(separator: " ")
        var i = 0
        func number() -> CGFloat? {
            guard i < tokens.count, let v = Double(tokens[i]) else { return nil }
            i += 1
            return CGFloat(v)
        }
        while i < tokens.count {
            let op = tokens[i]
            i += 1
            switch op {
            case "M": guard let x = number(), let y = number() else { return nil }; move(to: CGPoint(x: x, y: y))
            case "L": guard let x = number(), let y = number() else { return nil }; addLine(to: CGPoint(x: x, y: y))
            case "R": guard let x = number(), let y = number(), let w = number(), let h = number() else { return nil }; addRect(CGRect(x: x, y: y, width: w, height: h))
            case "Q": guard let x = number(), let y = number(), let w = number(), let h = number(), let r = number() else { return nil }; elements.append(.roundedRect(CGRect(x: x, y: y, width: w, height: h), cornerRadius: r))
            case "E": guard let x = number(), let y = number(), let w = number(), let h = number() else { return nil }; addEllipse(in: CGRect(x: x, y: y, width: w, height: h))
            case "Z": closeSubpath()
            default: return nil
            }
        }
    }
}

/// Sine and cosine without the platform's math library (the wasm build's
/// Foundation has none): reduced to a quarter turn, then a series accurate
/// far past what a drawn point needs.
func _sine(_ x: Double) -> Double {
    let full = 2 * Double.pi
    var a = x.truncatingRemainder(dividingBy: full)
    if a < 0 { a += full }
    var sign = 1.0
    if a > .pi { a -= .pi; sign = -1 }
    if a > .pi / 2 { a = .pi - a }
    let a2 = a * a
    // Taylor terms to a^13: error below 1e-10 on [0, π/2].
    var term = a, sum = a
    for n in stride(from: 2, through: 12, by: 2) {
        term *= -a2 / Double(n * (n + 1))
        sum += term
    }
    return sign * sum
}

func _cosine(_ x: Double) -> Double { _sine(x + .pi / 2) }

/// How a rounded corner curves (accepted; hosts draw circular corners).
public enum RoundedCornerStyle: Sendable {
    case circular
    case continuous
}

// SwiftUI's shape shorthands: `.rect(cornerRadius: 24)`, `.capsule`, `.circle`.
extension Shape where Self == Rectangle {
    nonisolated public static var rect: Rectangle { Rectangle() }
}

extension Shape where Self == RoundedRectangle {
    nonisolated public static func rect(cornerRadius: CGFloat, style: RoundedCornerStyle = .continuous) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: style)
    }
}

extension Shape where Self == Capsule {
    nonisolated public static var capsule: Capsule { Capsule() }
}

extension Shape where Self == Circle {
    nonisolated public static var circle: Circle { Circle() }
}

struct _ShapeView {
    let kind: ShapeKind
    let fill: Color?
    let stroke: (Color, CGFloat)?
    /// The `.trim` range, when the shape came through one.
    var trim: (CGFloat, CGFloat)?

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _ShapeView: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let opacity = ctx.env.opacity
        let node = RenderNode(kind: .shape(
            kind,
            fill: fill.map { $0.opacity(opacity) },
            stroke: stroke.map { ($0.0.opacity(opacity), $0.1) }
        ))
        node.trim = trim
        return node
    }
}

// A bare shape (e.g. `Circle()`) fills with the inherited foreground color.
extension Rectangle: _PrimitiveView {}
extension RoundedRectangle: _PrimitiveView {}
extension Circle: _PrimitiveView {}
extension Capsule: _PrimitiveView {}
extension Ellipse: _PrimitiveView {}

extension Shape {
    nonisolated func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let node = RenderNode(kind: .shape(
            shapeKind,
            fill: ctx.env.foregroundColor.opacity(ctx.env.opacity),
            stroke: nil
        ))
        node.trim = shapeTrim
        return node
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _GradientShapeView: View {}
extension _TrimmedShape: PrimitiveShape {}
extension _TrimmedShape: _PrimitiveView {}
extension _StrokedShape: PrimitiveShape {}
extension Rectangle: PrimitiveShape {}
extension RoundedRectangle: PrimitiveShape {}
extension Circle: PrimitiveShape {}
extension Capsule: PrimitiveShape {}
extension Ellipse: PrimitiveShape {}
extension Rectangle: InsettableShape {
    /// The shape inset by `amount` (frames lay a stroke on the edge, so
    /// the inset shape draws as the shape).
    nonisolated public func inset(by amount: CGFloat) -> some InsettableShape { self }
}
extension RoundedRectangle: InsettableShape {
    /// The shape inset by `amount` (frames lay a stroke on the edge, so
    /// the inset shape draws as the shape).
    nonisolated public func inset(by amount: CGFloat) -> some InsettableShape { self }
}
extension Circle: InsettableShape {
    /// The shape inset by `amount` (frames lay a stroke on the edge, so
    /// the inset shape draws as the shape).
    nonisolated public func inset(by amount: CGFloat) -> some InsettableShape { self }
}
extension Capsule: InsettableShape {
    /// The shape inset by `amount` (frames lay a stroke on the edge, so
    /// the inset shape draws as the shape).
    nonisolated public func inset(by amount: CGFloat) -> some InsettableShape { self }
}
extension Ellipse: InsettableShape {
    /// The shape inset by `amount` (frames lay a stroke on the edge, so
    /// the inset shape draws as the shape).
    nonisolated public func inset(by amount: CGFloat) -> some InsettableShape { self }
}
extension _ShapeFill: View {}
extension _ForegroundFill: View {}
extension _ShapeView: View {}
