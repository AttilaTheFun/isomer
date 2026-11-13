// Gradients and shape styles. API-compatible with the SwiftUI types so the
// shared example compiles against the real SwiftUI on Apple and against this
// reimplementation on web/Android.

public struct UnitPoint: Equatable, Sendable {
    public var x: CGFloat
    public var y: CGFloat

    public init(x: CGFloat, y: CGFloat) {
        self.x = x
        self.y = y
    }

    public static let zero = UnitPoint(x: 0, y: 0)
    public static let center = UnitPoint(x: 0.5, y: 0.5)
    public static let leading = UnitPoint(x: 0, y: 0.5)
    public static let trailing = UnitPoint(x: 1, y: 0.5)
    public static let top = UnitPoint(x: 0.5, y: 0)
    public static let bottom = UnitPoint(x: 0.5, y: 1)
    public static let topLeading = UnitPoint(x: 0, y: 0)
    public static let topTrailing = UnitPoint(x: 1, y: 0)
    public static let bottomLeading = UnitPoint(x: 0, y: 1)
    public static let bottomTrailing = UnitPoint(x: 1, y: 1)
}

public struct Angle: Equatable, Sendable {
    public var radians: Double

    public init(radians: Double) {
        self.radians = radians
    }

    public init(degrees: Double) {
        self.radians = degrees * .pi / 180
    }

    public var degrees: Double { radians * 180 / .pi }

    public static func radians(_ value: Double) -> Angle { Angle(radians: value) }
    public static func degrees(_ value: Double) -> Angle { Angle(degrees: value) }
    public static let zero = Angle(radians: 0)
}

public struct Gradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: Color
        public var location: CGFloat

        public init(color: Color, location: CGFloat) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]
    /// The colour a `Color.gradient` was made from (its stops are Isomer's
    /// guess at the system's shading), for hosts that draw that colour's own
    /// gradient (Apple's: GradientPaint's `anyBase`).
    var anyBase: Color?

    public init(stops: [Stop]) {
        self.stops = stops
    }

    public init(colors: [Color]) {
        let count = max(colors.count - 1, 1)
        stops = colors.enumerated().map { index, color in
            Stop(color: color, location: CGFloat(index) / CGFloat(count))
        }
    }
}

/// A style that fills a region (a colour, a gradient, a material). Apple's
/// protocol asks nothing Isomer reads; Isomer's own styles are
/// `PaintStyle`s, and a style an app defines paints as `.primary`.
public protocol ShapeStyle {}

/// What a style paints with: Isomer's styles know theirs.
protocol PaintStyle: ShapeStyle {
    func resolvePaint() -> GradientPaint
}

/// The paint for any style (`.primary` for one an app defines).
func paint(of style: any ShapeStyle) -> GradientPaint {
    (style as? any PaintStyle)?.resolvePaint()
        ?? GradientPaint(kind: .solid, stops: [Gradient.Stop(color: .primary, location: 0)])
}

/// Runtime description of a paint, handed to the host renderer.
struct GradientPaint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case solid
        case linear(start: UnitPoint, end: UnitPoint)
        case radial(center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat)
        case angular(center: UnitPoint, startAngle: Angle, endAngle: Angle)
        /// A radial gradient stretched to the bounds: radii fractions of them.
        case elliptical(center: UnitPoint, startFraction: CGFloat, endFraction: CGFloat)
    }

    public var kind: Kind
    public var stops: [Gradient.Stop]
    /// A `Material` (or glass): hosts that can blur what lies behind draw
    /// it frosted; the stops hold the tint the others fill with.
    public var material: String? = nil
    /// Liquid Glass as it was asked for (`.glassEffect`): its variant
    /// ("regular", "clear"), tint and interactivity, for hosts that have
    /// the glass itself (JSON "glass", "glassTint", "interactive"); the
    /// material and stops above are what the others draw.
    var glass: String? = nil
    var glassTint: Color? = nil
    var glassInteractive = false
    /// A `Color.gradient`'s colour (Gradient's `anyBase`): JSON "anyName"
    /// (the system colour's name) and "anyColor" (its RGBA).
    var anyBase: Color? = nil

    func withOpacity(_ opacity: Double) -> GradientPaint {
        guard opacity < 1 else { return self }
        var faded = self
        faded.stops = stops.map { Gradient.Stop(color: $0.color.opacity(opacity), location: $0.location) }
        return faded
    }
}

extension Color: PaintStyle {
    func resolvePaint() -> GradientPaint {
        GradientPaint(kind: .solid, stops: [Gradient.Stop(color: self, location: 0)])
    }
}

// MARK: - Gradient view types

public struct LinearGradient: PaintStyle {
    let gradient: Gradient
    let startPoint: UnitPoint
    let endPoint: UnitPoint

    public init(gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) {
        self.gradient = gradient
        self.startPoint = startPoint
        self.endPoint = endPoint
    }

    public init(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(colors: colors), startPoint: startPoint, endPoint: endPoint)
    }

    public init(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) {
        self.init(gradient: Gradient(stops: stops), startPoint: startPoint, endPoint: endPoint)
    }

    func resolvePaint() -> GradientPaint {
        GradientPaint(kind: .linear(start: startPoint, end: endPoint), stops: gradient.stops, anyBase: gradient.anyBase)
    }

    public typealias Body = Never
}

public struct RadialGradient: PaintStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startRadius: CGFloat
    let endRadius: CGFloat

    public init(gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.gradient = gradient
        self.center = center
        self.startRadius = startRadius
        self.endRadius = endRadius
    }

    public init(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(colors: colors), center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public init(stops: [Gradient.Stop], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) {
        self.init(gradient: Gradient(stops: stops), center: center, startRadius: startRadius, endRadius: endRadius)
    }

    func resolvePaint() -> GradientPaint {
        GradientPaint(
            kind: .radial(center: center, startRadius: startRadius, endRadius: endRadius),
            stops: gradient.stops,
            anyBase: gradient.anyBase
        )
    }

    public typealias Body = Never
}

public struct AngularGradient: PaintStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startAngle: Angle
    let endAngle: Angle

    public init(gradient: Gradient, center: UnitPoint, startAngle: Angle, endAngle: Angle) {
        self.gradient = gradient
        self.center = center
        self.startAngle = startAngle
        self.endAngle = endAngle
    }

    public init(gradient: Gradient, center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: gradient, center: center, startAngle: angle, endAngle: Angle(degrees: angle.degrees + 360))
    }

    public init(colors: [Color], center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = Angle(degrees: 360)) {
        self.init(gradient: Gradient(colors: colors), center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public init(stops: [Gradient.Stop], center: UnitPoint, startAngle: Angle = .zero, endAngle: Angle = Angle(degrees: 360)) {
        self.init(gradient: Gradient(stops: stops), center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public init(colors: [Color], center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: Gradient(colors: colors), center: center, angle: angle)
    }

    public init(stops: [Gradient.Stop], center: UnitPoint, angle: Angle = .zero) {
        self.init(gradient: Gradient(stops: stops), center: center, angle: angle)
    }

    func resolvePaint() -> GradientPaint {
        GradientPaint(
            kind: .angular(center: center, startAngle: startAngle, endAngle: endAngle),
            stops: gradient.stops,
            anyBase: gradient.anyBase
        )
    }

    public typealias Body = Never
}

// The gradients as `ShapeStyle` shorthands (`.fill(.linearGradient(…))`,
// `.foregroundStyle(.radialGradient(…))`), as Apple's.
extension ShapeStyle where Self == LinearGradient {
    public static func linearGradient(_ gradient: Gradient, startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(gradient: gradient, startPoint: startPoint, endPoint: endPoint)
    }

    public static func linearGradient(colors: [Color], startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(colors: colors, startPoint: startPoint, endPoint: endPoint)
    }

    public static func linearGradient(stops: [Gradient.Stop], startPoint: UnitPoint, endPoint: UnitPoint) -> LinearGradient {
        LinearGradient(stops: stops, startPoint: startPoint, endPoint: endPoint)
    }
}

extension ShapeStyle where Self == RadialGradient {
    public static func radialGradient(_ gradient: Gradient, center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(gradient: gradient, center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public static func radialGradient(colors: [Color], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(colors: colors, center: center, startRadius: startRadius, endRadius: endRadius)
    }

    public static func radialGradient(stops: [Gradient.Stop], center: UnitPoint, startRadius: CGFloat, endRadius: CGFloat) -> RadialGradient {
        RadialGradient(stops: stops, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

extension ShapeStyle where Self == AngularGradient {
    public static func angularGradient(_ gradient: Gradient, center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(gradient: gradient, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func angularGradient(colors: [Color], center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(colors: colors, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func angularGradient(stops: [Gradient.Stop], center: UnitPoint, startAngle: Angle, endAngle: Angle) -> AngularGradient {
        AngularGradient(stops: stops, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func conicGradient(_ gradient: Gradient, center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(gradient: gradient, center: center, angle: angle)
    }

    public static func conicGradient(colors: [Color], center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(colors: colors, center: center, angle: angle)
    }

    public static func conicGradient(stops: [Gradient.Stop], center: UnitPoint, angle: Angle = .zero) -> AngularGradient {
        AngularGradient(stops: stops, center: center, angle: angle)
    }
}

// Gradients render as a `.gradient` node filling their proposed rect.
extension LinearGradient: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        gradientNode(resolvePaint(), ctx: ctx)
    }
}

extension RadialGradient: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        gradientNode(resolvePaint(), ctx: ctx)
    }
}

/// A radial gradient stretched to its shape's bounds, as Apple's: its radii
/// fractions of them on each axis (0.5, the ellipse the bounds hold).
public struct EllipticalGradient: PaintStyle {
    let gradient: Gradient
    let center: UnitPoint
    let startRadiusFraction: CGFloat
    let endRadiusFraction: CGFloat

    public init(gradient: Gradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) {
        self.gradient = gradient
        self.center = center
        self.startRadiusFraction = startRadiusFraction
        self.endRadiusFraction = endRadiusFraction
    }

    public init(colors: [Color], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) {
        self.init(gradient: Gradient(colors: colors), center: center,
                  startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }

    public init(stops: [Gradient.Stop], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0, endRadiusFraction: CGFloat = 0.5) {
        self.init(gradient: Gradient(stops: stops), center: center,
                  startRadiusFraction: startRadiusFraction, endRadiusFraction: endRadiusFraction)
    }

    func resolvePaint() -> GradientPaint {
        GradientPaint(
            kind: .elliptical(center: center, startFraction: startRadiusFraction, endFraction: endRadiusFraction),
            stops: gradient.stops,
            anyBase: gradient.anyBase
        )
    }

    public typealias Body = Never
}

extension EllipticalGradient: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        gradientNode(resolvePaint(), ctx: ctx)
    }
}

extension ShapeStyle where Self == EllipticalGradient {
    public static func ellipticalGradient(_ gradient: Gradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                                          endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(gradient: gradient, center: center, startRadiusFraction: startRadiusFraction,
                           endRadiusFraction: endRadiusFraction)
    }

    public static func ellipticalGradient(colors: [Color], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                                          endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(colors: colors, center: center, startRadiusFraction: startRadiusFraction,
                           endRadiusFraction: endRadiusFraction)
    }

    public static func ellipticalGradient(stops: [Gradient.Stop], center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                                          endRadiusFraction: CGFloat = 0.5) -> EllipticalGradient {
        EllipticalGradient(stops: stops, center: center, startRadiusFraction: startRadiusFraction,
                           endRadiusFraction: endRadiusFraction)
    }

    public static func ellipticalGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startRadiusFraction: CGFloat = 0,
                                          endRadiusFraction: CGFloat = 0.5) -> some ShapeStyle {
        EllipticalGradient(gradient: gradient.gradient, center: center, startRadiusFraction: startRadiusFraction,
                           endRadiusFraction: endRadiusFraction)
    }
}

/// A gradient as a style of its own (`Color.gradient`, `AnyGradient(_:)`):
/// filled top to bottom, or given a shape by the gradient styles' forms
/// that take one, as Apple's.
public struct AnyGradient: Hashable, PaintStyle, Sendable {
    let gradient: Gradient

    public init(_ gradient: Gradient) {
        self.gradient = gradient
    }

    func resolvePaint() -> GradientPaint {
        GradientPaint(kind: .linear(start: .top, end: .bottom), stops: gradient.stops, anyBase: gradient.anyBase)
    }
}

extension Color {
    /// A gradient of the colour, lighter at the top: the system's own
    /// shading of a fill, as Apple's (whose exact mix is its own).
    public var gradient: AnyGradient {
        var gradient = Gradient(colors: [mix(with: .white, by: 0.2), self])
        gradient.anyBase = self
        return AnyGradient(gradient)
    }
}

extension ShapeStyle where Self == LinearGradient {
    public static func linearGradient(_ gradient: AnyGradient, startPoint: UnitPoint, endPoint: UnitPoint) -> some ShapeStyle {
        LinearGradient(gradient: gradient.gradient, startPoint: startPoint, endPoint: endPoint)
    }
}

extension ShapeStyle where Self == RadialGradient {
    public static func radialGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startRadius: CGFloat = 0,
                                      endRadius: CGFloat) -> some ShapeStyle {
        RadialGradient(gradient: gradient.gradient, center: center, startRadius: startRadius, endRadius: endRadius)
    }
}

extension ShapeStyle where Self == AngularGradient {
    public static func angularGradient(_ gradient: AnyGradient, center: UnitPoint = .center, startAngle: Angle,
                                       endAngle: Angle) -> some ShapeStyle {
        AngularGradient(gradient: gradient.gradient, center: center, startAngle: startAngle, endAngle: endAngle)
    }

    public static func conicGradient(_ gradient: AnyGradient, center: UnitPoint = .center, angle: Angle = .zero) -> some ShapeStyle {
        AngularGradient(gradient: gradient.gradient, center: center, angle: angle)
    }
}

extension AngularGradient: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        gradientNode(resolvePaint(), ctx: ctx)
    }
}

func gradientNode(_ paint: GradientPaint, ctx: BuildContext, shape: ShapeKind = .rectangle) -> RenderNode {
    let node = RenderNode(kind: .gradient(shape, paint.withOpacity(ctx.env.opacity)))
    return node
}

// MARK: - JSON serialization for the host boundary

extension GradientPaint {
    /// Compact JSON the host parses to set up a gradient fill.
    func json() -> String {
        var fields: [String] = []
        switch kind {
        case .solid:
            fields.append("\"kind\":\"solid\"")
        case .linear(let start, let end):
            fields.append("\"kind\":\"linear\"")
            fields.append("\"p0\":[\(num(start.x)),\(num(start.y))]")
            fields.append("\"p1\":[\(num(end.x)),\(num(end.y))]")
        case .radial(let center, let startRadius, let endRadius):
            fields.append("\"kind\":\"radial\"")
            fields.append("\"c\":[\(num(center.x)),\(num(center.y))]")
            fields.append("\"sr\":\(num(startRadius))")
            fields.append("\"er\":\(num(endRadius))")
        case .elliptical(let center, let startFraction, let endFraction):
            // A radial gradient whose radii are fractions of the bounds
            // ("ell": start, end), which the hosts stretch to an ellipse.
            fields.append("\"kind\":\"radial\"")
            fields.append("\"c\":[\(num(center.x)),\(num(center.y))]")
            fields.append("\"ell\":[\(num(startFraction)),\(num(endFraction))]")
        case .angular(let center, let startAngle, let endAngle):
            fields.append("\"kind\":\"angular\"")
            fields.append("\"c\":[\(num(center.x)),\(num(center.y))]")
            fields.append("\"a0\":\(num(startAngle.radians))")
            fields.append("\"a1\":\(num(endAngle.radians))")
        }
        // A system colour's stop also carries its name ("n", as `fillName`
        // names a fill): hosts with the system's colours draw those (Apple's
        // change from release to release; the RGBA is Isomer's table's).
        let stopJSON = stops.map { stop in
            let c = stop.color
            let name = systemColorName(c).map { ",\"n\":\(jsonString($0))" } ?? ""
            return "{\"c\":[\(num(c.red)),\(num(c.green)),\(num(c.blue)),\(num(c.alpha))],\"l\":\(num(stop.location))\(name)}"
        }.joined(separator: ",")
        fields.append("\"stops\":[\(stopJSON)]")
        if let base = anyBase {
            if let name = systemColorName(base) { fields.append("\"anyName\":\(jsonString(name))") }
            fields.append("\"anyColor\":[\(num(base.red)),\(num(base.green)),\(num(base.blue)),\(num(base.alpha))]")
        }
        if let material { fields.append("\"material\":\(jsonString(material))") }
        if let glass {
            fields.append("\"glass\":\(jsonString(glass))")
            if let c = glassTint { fields.append("\"glassTint\":[\(num(c.red)),\(num(c.green)),\(num(c.blue)),\(num(c.alpha))]") }
            if glassInteractive { fields.append("\"interactive\":1") }
        }
        return "{" + fields.joined(separator: ",") + "}"
    }
}

/// Minimal float formatter (avoids Foundation; good enough for the wire).
func num(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(Int64(value))
    }
    let scaled = (value * 10000).rounded() / 10000
    return String(scaled)
}

/// JSON-escapes a string for the host-view payload.
func jsonString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += "\\u"
                let hex = String(scalar.value, radix: 16)
                out += String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension LinearGradient: View {}
extension RadialGradient: View {}
extension AngularGradient: View {}
