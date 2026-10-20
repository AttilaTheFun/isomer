public enum ColorScheme: Equatable, Sendable {
    case light
    case dark
}

/// An sRGB color (0...1 components) that can carry a separate **dark-scheme**
/// variant. The `red`/`green`/`blue`/`alpha` accessors (Isomer's, not
/// Apple's: `package`) resolve against the runtime's current `colorScheme`,
/// so every host draw call adapts to dark mode automatically. Semantic colors (`.primary`, `.secondary`, the bar
/// / background / separator fills) define both variants.
public struct Color: Hashable, Sendable {
    let lr: Double, lg: Double, lb: Double, la: Double
    let dr: Double, dg: Double, db: Double, da: Double
    let hasDark: Bool
    /// A system colour's name ("green", "accentColor", "primary"…), with the
    /// opacity applied to it: hosts with the system's own colours use it
    /// (dynamic, and treated by glass and vibrancy as the system's are).
    var systemName: String?
    var systemOpacity: Double = 1

    package var red: Double { resolveDark ? dr : lr }
    package var green: Double { resolveDark ? dg : lg }
    package var blue: Double { resolveDark ? db : lb }
    package var alpha: Double { resolveDark ? da : la }

    private var resolveDark: Bool { hasDark && Runtime.shared.colorScheme == .dark }

    /// The colour spaces a colour can be given in. Isomer's hosts draw in
    /// sRGB; the others are taken as sRGB values.
    public enum RGBColorSpace: Hashable, Sendable {
        case sRGB
        case sRGBLinear
        case displayP3
    }

    public init(_ colorSpace: Color.RGBColorSpace = .sRGB, red: Double, green: Double, blue: Double, opacity: Double = 1) {
        lr = red; lg = green; lb = blue; la = opacity
        dr = red; dg = green; db = blue; da = opacity
        hasDark = false
    }

    public init(_ colorSpace: Color.RGBColorSpace = .sRGB, white: Double, opacity: Double = 1) {
        self.init(colorSpace, red: white, green: white, blue: white, opacity: opacity)
    }

    private init(
        l: (Double, Double, Double, Double),
        d: (Double, Double, Double, Double)
    ) {
        lr = l.0; lg = l.1; lb = l.2; la = l.3
        dr = d.0; dg = d.1; db = d.2; da = d.3
        hasDark = true
    }

    /// A scheme-adaptive color: distinct light and dark values.
    static func dynamic(
        light: (Double, Double, Double, Double),
        dark: (Double, Double, Double, Double)
    ) -> Color {
        Color(l: light, d: dark)
    }

    /// A scheme-adaptive color from two concrete colors: `light` under the
    /// light scheme, `dark` under the dark one (an adaptive argument gives
    /// its matching variant). Apps reach it as the Isomer module's
    /// `Color.dynamic(light:dark:)`.
    static func dynamic(light: Color, dark: Color) -> Color {
        Color(
            l: (light.lr, light.lg, light.lb, light.la),
            d: (dark.dr, dark.dg, dark.db, dark.da)
        )
    }

    package static func _dynamic(light: Color, dark: Color) -> Color {
        dynamic(light: light, dark: dark)
    }

    public func opacity(_ value: Double) -> Color {
        var faded = hasDark
            ? Color(l: (lr, lg, lb, la * value), d: (dr, dg, db, da * value))
            : Color(red: lr, green: lg, blue: lb, opacity: la * value)
        faded.systemName = systemName
        faded.systemOpacity = systemOpacity * value
        return faded
    }

    /// A system colour: Apple's light and dark values, and its name.
    static func system(_ name: String, light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        var color = Color(l: (light.0, light.1, light.2, 1), d: (dark.0, dark.1, dark.2, 1))
        color.systemName = name
        return color
    }

    /// A named colour with no dark variant of its own (black, white, clear).
    private func named(_ name: String) -> Color {
        var color = self
        color.systemName = name
        return color
    }

    public static let clear = Color(white: 0, opacity: 0).named("clear")
    public static let black = Color(white: 0).named("black")
    public static let white = Color(white: 1).named("white")
    // The system colours, Apple's light and dark values.
    public static let gray = Color.system("gray", light: (0.56, 0.56, 0.58), dark: (0.56, 0.56, 0.58))
    public static let red = Color.system("red", light: (1.0, 0.23, 0.19), dark: (1.0, 0.27, 0.23))
    public static let orange = Color.system("orange", light: (1.0, 0.58, 0.0), dark: (1.0, 0.62, 0.04))
    public static let yellow = Color.system("yellow", light: (1.0, 0.8, 0.0), dark: (1.0, 0.84, 0.04))
    public static let green = Color.system("green", light: (0.2, 0.78, 0.35), dark: (0.19, 0.82, 0.35))
    public static let mint = Color.system("mint", light: (0.0, 0.78, 0.75), dark: (0.39, 0.9, 0.89))
    public static let teal = Color.system("teal", light: (0.19, 0.69, 0.78), dark: (0.25, 0.78, 0.88))
    public static let cyan = Color.system("cyan", light: (0.19, 0.68, 0.9), dark: (0.39, 0.82, 1.0))
    public static let blue = Color.system("blue", light: (0.0, 0.48, 1.0), dark: (0.04, 0.52, 1.0))
    public static let indigo = Color.system("indigo", light: (0.35, 0.34, 0.84), dark: (0.37, 0.36, 0.9))
    public static let purple = Color.system("purple", light: (0.69, 0.32, 0.87), dark: (0.75, 0.35, 0.95))
    public static let pink = Color.system("pink", light: (1.0, 0.18, 0.33), dark: (1.0, 0.22, 0.37))
    public static let brown = Color.system("brown", light: (0.64, 0.52, 0.37), dark: (0.67, 0.56, 0.41))

    // Semantic colors (light / dark).
    public static let primary = Color.dynamic(
        light: (0, 0, 0, 0.85), dark: (1, 1, 1, 0.92)).named("primary")
    public static let secondary = Color.dynamic(
        light: (0.24, 0.24, 0.26, 0.6), dark: (0.92, 0.92, 0.96, 0.6)).named("secondary")
    public static let accentColor = Color.system("accentColor", light: (0.0, 0.48, 1.0), dark: (0.04, 0.52, 1.0))

    /// The window/background fill (drawn behind everything each frame).
    static let windowBackground = Color.dynamic(
        light: (1, 1, 1, 1), dark: (0.07, 0.07, 0.08, 1))
    // The grounds below are named on the wire too ("fillName"): a host
    // with a palette of its own for them (the desktop web's, the Mac's)
    // draws them in it; others take the colour.
    /// Grouped-content backdrop (Form, behind sections).
    static let groupedBackground = Color.dynamic(
        light: (0.95, 0.95, 0.96, 1), dark: (0, 0, 0, 1)).named("groupedBackground")
    /// Cards / list rows / sheets / sidebar.
    static let secondaryBackground = Color.dynamic(
        light: (1, 1, 1, 1), dark: (0.11, 0.11, 0.12, 1)).named("secondaryBackground")
    /// The grouped palette in a sheet, raised as iOS raises a sheet's
    /// content in the dark scheme (the same in light).
    static let elevatedGroupedBackground = Color.dynamic(
        light: (0.95, 0.95, 0.96, 1), dark: (0.11, 0.11, 0.12, 1)).named("elevatedGroupedBackground")
    static let elevatedSecondaryBackground = Color.dynamic(
        light: (1, 1, 1, 1), dark: (0.17, 0.17, 0.18, 1)).named("elevatedSecondaryBackground")
    /// Navigation / tab bar.
    static let barBackground = Color.dynamic(
        light: (0.97, 0.97, 0.97, 1), dark: (0.12, 0.12, 0.13, 1)).named("barBackground")
    /// Hairline separators.
    static let separator = Color.dynamic(
        light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.15))
    /// Subtle fill (gallery cards, control backgrounds).
    static let subtleFill = Color.dynamic(
        light: (0, 0, 0, 0.04), dark: (1, 1, 1, 0.08))
}

// `Color` is itself a View in SwiftUI (it fills the proposed space).
extension Color: View {
    public typealias Body = Never
}

extension Color: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // Honor the inherited opacity (`.opacity`/`.disabled`) so a `Color`
        // (including as a `.background`) fades like text and images do.
        RenderNode(kind: .shape(.rectangle, fill: self.opacity(ctx.env.opacity), stroke: nil))
    }
}
