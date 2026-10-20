// Materials and Liquid Glass: SwiftUI's frosted fills. The web draws them
// frosted (a translucent tint over a blur of what lies behind, the same
// material as the bar buttons); hosts that can't blur the backdrop fill
// with the tint alone. Real SwiftUI is used on Apple.

/// A frosted fill: `.background(.thinMaterial, in: RoundedRectangle(…))`.
public struct Material: PaintStyle, Sendable {
    let name: String
    /// The tint's opacity over the blur, light and dark.
    let light: Double
    let dark: Double

    public static let ultraThin = Material(name: "ultraThin", light: 0.55, dark: 0.45)
    public static let thin = Material(name: "thin", light: 0.72, dark: 0.55)
    public static let regular = Material(name: "regular", light: 0.8, dark: 0.65)
    public static let thick = Material(name: "thick", light: 0.88, dark: 0.75)
    public static let ultraThick = Material(name: "ultraThick", light: 0.94, dark: 0.85)
    public static let bar = Material(name: "bar", light: 0.8, dark: 0.7)
    /// Liquid Glass's material (`.glassEffect`): lighter than the thin
    /// material, the bar buttons' glass.
    static let glass = Material(name: "glass", light: 0.6, dark: 0.5)

    func resolvePaint() -> GradientPaint {
        let tint = Color.dynamic(
            light: Color(red: 1, green: 1, blue: 1, opacity: light),
            dark: Color(red: 60 / 255, green: 60 / 255, blue: 67 / 255, opacity: dark))
        return GradientPaint(kind: .solid, stops: [Gradient.Stop(color: tint, location: 0)], material: name)
    }
}

extension ShapeStyle where Self == Material {
    public static var ultraThinMaterial: Material { .ultraThin }
    public static var thinMaterial: Material { .thin }
    public static var regularMaterial: Material { .regular }
    public static var thickMaterial: Material { .thick }
    public static var ultraThickMaterial: Material { .ultraThick }
    public static var bar: Material { .bar }
}

/// Liquid Glass (`.glassEffect(_:in:)`): the glass material (what lies
/// behind, blurred, under a light tint, with a bright rim; the bar buttons'
/// glass), with an optional tint laid over it.
public struct Glass: Sendable {
    let variant: String
    let tintColor: Color?
    var isInteractive = false

    public static let regular = Glass(variant: "regular", tintColor: nil)
    public static let clear = Glass(variant: "clear", tintColor: nil)
    public static let identity = Glass(variant: "identity", tintColor: nil)

    public func tint(_ color: Color?) -> Glass { Glass(variant: variant, tintColor: color, isInteractive: isInteractive) }
    public func interactive(_ isEnabled: Bool = true) -> Glass { Glass(variant: variant, tintColor: tintColor, isInteractive: isEnabled) }
}

extension View {
    /// A background of `style` in `shape`: `.background(.thinMaterial,
    /// in: RoundedRectangle(cornerRadius: 24))`.
    nonisolated public func background<S: ShapeStyle, T: Shape>(_ style: S, in shape: T, fillStyle: FillStyle = FillStyle()) -> some View {
        background(shape.fill(style))
    }

    /// Liquid Glass behind the view, in `shape` (a capsule by default).
    nonisolated public func glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View {
        background(_GlassFill(glass: glass, shape: shape))
    }
}

/// The shape glass takes when none is given: a capsule.
public struct DefaultGlassEffectShape {
    public init() {}
}

// In an extension, as the views' are: declared on the type it would make its
// initializer main-actor isolated, and it is a default argument.
extension DefaultGlassEffectShape: PrimitiveShape {
    var primitiveKind: ShapeKind { .capsule }
    nonisolated public func path(in rect: CGRect) -> Path { Path(primitiveKind, in: rect) }
}

/// The glass's material, with its tint (if any) over it.
struct _GlassFill<Outline: Shape> {
    let glass: Glass
    let shape: Outline

    var body: some View {
        shape.fill(_GlassStyle(glass: glass))
    }
}

/// The glass as a fill: the glass material (or the thin one with the tint
/// mixed in), with the glass itself named for hosts that have it.
struct _GlassStyle: PaintStyle {
    let glass: Glass

    func resolvePaint() -> GradientPaint {
        var paint = glass.tintColor.map { _TintedMaterial(tint: $0).resolvePaint() } ?? Material.glass.resolvePaint()
        paint.glass = glass.variant
        paint.glassTint = glass.tintColor
        paint.glassInteractive = glass.isInteractive
        return paint
    }
}

/// The thin material with a tint mixed into it.
struct _TintedMaterial: PaintStyle {
    let tint: Color

    func resolvePaint() -> GradientPaint {
        GradientPaint(kind: .solid, stops: [Gradient.Stop(color: tint.opacity(0.8), location: 0)], material: "thin")
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _GlassFill: View {}

/// `GlassEffectContainer`: groups glass shapes so they blend into one
/// another as they near (`spacing`). Here each keeps its own glass and the
/// container lays its content out as given.
public struct GlassEffectContainer<Content: View> {
    let content: Content

    nonisolated public init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
    }
}

extension GlassEffectContainer: View {
    public var body: some View { content }
}
