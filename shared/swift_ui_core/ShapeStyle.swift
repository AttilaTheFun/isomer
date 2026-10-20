// ShapeStyle — the style vocabulary `.foregroundStyle` takes, mirroring real
// SwiftUI's shape so existing code compiles unchanged: colors are styles, and
// the hierarchical levels (`.primary` ... `.quaternary`) resolve adaptively
// against the current color scheme at draw time (they are `Color.dynamic`
// values underneath, like the rest of the semantic palette).
//
// The `ShapeStyle` protocol itself lives in Paint.swift (colors + the
// gradient views conform; `Shape.fill` takes it). This file adds the
// hierarchy levels and the leading-dot statics for generic style positions.
// Foreground resolution collapses a style to a `Color` (the environment
// carries a color): gradients resolve to their first stop.

/// The foreground hierarchy: `.primary` (labels), `.secondary` (secondary
/// labels), `.tertiary` / `.quaternary` (progressively subtler fills), each
/// with distinct light/dark values matching the Apple system palette.
public struct HierarchicalShapeStyle: PaintStyle {
    let level: Int
    init(level: Int) { self.level = level }

    func resolvePaint() -> GradientPaint {
        color.resolvePaint()
    }

    public static let primary = HierarchicalShapeStyle(level: 0)
    public static let secondary = HierarchicalShapeStyle(level: 1)
    public static let tertiary = HierarchicalShapeStyle(level: 2)
    public static let quaternary = HierarchicalShapeStyle(level: 3)

    var color: Color {
        switch level {
        case 0: return .primary
        case 1: return .secondary
        case 2: return Color.tertiaryStyle
        default: return Color.quaternaryStyle
        }
    }

    /// This level of a foreground colour: the colour itself, then fainter.
    func of(_ base: Color) -> Color {
        level == 0 ? base : base.opacity(fading)
    }
}

/// `AnyShapeStyle`: a style of any kind behind one type (a property that is
/// a colour on one branch and a hierarchical level on another). It is
/// whatever it wraps: `.foregroundStyle(AnyShapeStyle(.primary))` is the
/// level, as the bare `.primary` is.
public struct AnyShapeStyle: PaintStyle {
    let base: any ShapeStyle

    public init<S: ShapeStyle>(_ style: S) {
        base = (style as? AnyShapeStyle)?.base ?? style
    }

    func resolvePaint() -> GradientPaint { paint(of: base) }
}

// Leading-dot syntax in generic style positions, the way real SwiftUI does it:
// `.foregroundStyle(.tertiary)` / `.foregroundStyle(.red)`.
extension ShapeStyle where Self == HierarchicalShapeStyle {
    public static var primary: HierarchicalShapeStyle { .primary }
    public static var secondary: HierarchicalShapeStyle { .secondary }
    public static var tertiary: HierarchicalShapeStyle { .tertiary }
    public static var quaternary: HierarchicalShapeStyle { .quaternary }
}

extension ShapeStyle where Self == Color {
    public static var red: Color { .red }
    public static var orange: Color { .orange }
    public static var yellow: Color { .yellow }
    public static var green: Color { .green }
    public static var mint: Color { .mint }
    public static var teal: Color { .teal }
    public static var cyan: Color { .cyan }
    public static var blue: Color { .blue }
    public static var indigo: Color { .indigo }
    public static var purple: Color { .purple }
    public static var pink: Color { .pink }
    public static var brown: Color { .brown }
    public static var white: Color { .white }
    public static var gray: Color { .gray }
    public static var black: Color { .black }
    public static var clear: Color { .clear }
}

extension Color {
    // The lower hierarchy levels (Apple's tertiary/quaternary label values).
    // Not public: real SwiftUI exposes them only as hierarchical styles.
    static let tertiaryStyle = Color.dynamic(
        light: (0.24, 0.24, 0.26, 0.3), dark: (0.92, 0.92, 0.96, 0.3))
    static let quaternaryStyle = Color.dynamic(
        light: (0.24, 0.24, 0.26, 0.18), dark: (0.92, 0.92, 0.96, 0.16))
}

// A style made from another, as SwiftUI's: `.secondary.opacity(0.1)`,
// `Color.red.secondary`. What they return is opaque, as Apple's is.
extension ShapeStyle {
    public func opacity(_ opacity: Double) -> some ShapeStyle {
        _DerivedStyle(base: self, opacity: opacity, level: 0)
    }

    public var secondary: some ShapeStyle { _DerivedStyle(base: self, opacity: 1, level: 1) }
    public var tertiary: some ShapeStyle { _DerivedStyle(base: self, opacity: 1, level: 2) }
    public var quaternary: some ShapeStyle { _DerivedStyle(base: self, opacity: 1, level: 3) }
}

/// A style at an opacity, or at a level of its own hierarchy (the level's
/// fading applied to it).
struct _DerivedStyle<Base: ShapeStyle>: PaintStyle {
    let base: Base
    let opacity: Double
    let level: Int

    func resolvePaint() -> GradientPaint {
        // The background's levels are grounds of their own (iOS's secondary
        // and tertiary system backgrounds), not the background faded.
        if base is BackgroundStyle { return BackgroundStyle.ground(level).resolvePaint().withOpacity(opacity) }
        return paint(of: base).withOpacity(opacity * HierarchicalShapeStyle(level: level).fading)
    }
}

/// `.tint`: the colour controls take, the accent. (Resolved as the accent:
/// a style is resolved without the environment's `.tint(_:)`.)
public struct TintShapeStyle: PaintStyle {
    nonisolated public init() {}
    func resolvePaint() -> GradientPaint { Color.accentColor.resolvePaint() }
}

extension ShapeStyle where Self == TintShapeStyle {
    public static var tint: TintShapeStyle { TintShapeStyle() }
}

/// `.background`: the window's background; `.background.secondary` and
/// `.tertiary` the grounds iOS raises on it (its secondary and tertiary
/// system backgrounds), for cards on a screen.
public struct BackgroundStyle: PaintStyle {
    nonisolated public init() {}
    func resolvePaint() -> GradientPaint { Self.ground(0).resolvePaint() }

    static func ground(_ level: Int) -> Color {
        switch level {
        case 0: return .windowBackground
        case 1: return Color.dynamic(light: (0.95, 0.95, 0.97, 1), dark: (0.11, 0.11, 0.12, 1))
        default: return Color.dynamic(light: (1, 1, 1, 1), dark: (0.17, 0.17, 0.18, 1))
        }
    }
}

extension ShapeStyle where Self == BackgroundStyle {
    public static var background: BackgroundStyle { BackgroundStyle() }
}

/// What the derived styles have in common, for code that does not know
/// their base's type.
protocol _AnyDerivedStyle {
    var baseStyle: any ShapeStyle { get }
    func derive(_ color: Color) -> Color
}

extension _DerivedStyle: _AnyDerivedStyle {
    var baseStyle: any ShapeStyle { base }
    func derive(_ color: Color) -> Color {
        HierarchicalShapeStyle(level: level).of(color).opacity(opacity)
    }
}

extension HierarchicalShapeStyle {
    /// The opacity `of(_:)` gives a colour at this level.
    var fading: Double {
        switch level {
        case 0: return 1
        case 1: return 0.6
        case 2: return 0.3
        default: return 0.18
        }
    }
}

/// A style as one colour, when it is one: a colour, a hierarchy level (of
/// `foreground`, or with none the system's label colours), or one of those
/// at an opacity or level; nil for gradients and materials.
func styleColor(_ style: any ShapeStyle, foreground: Color? = nil) -> Color? {
    if let erased = style as? AnyShapeStyle { return styleColor(erased.base, foreground: foreground) }
    if let color = style as? Color { return color }
    if let level = style as? HierarchicalShapeStyle { return foreground.map(level.of) ?? level.color }
    if let derived = style as? _AnyDerivedStyle {
        return styleColor(derived.baseStyle, foreground: foreground).map(derived.derive)
    }
    return nil
}

/// Collapses any style to a foreground color (the environment carries a
/// color): colors pass through, hierarchy levels pick their adaptive color,
/// gradients resolve to their first stop.
func resolveStyleColor(_ style: any ShapeStyle) -> Color {
    styleColor(style) ?? paint(of: style).stops.first?.color ?? .primary
}
