// `Image.Scale` and `.imageScale(_:)`: an SF Symbol's size beside the text
// of its font, as Apple's. The scale travels to the host with the symbol
// (param "imageScale"); a host with the system's symbols scales them as it
// does (Apple's), the others draw the symbol's glyph at its font's size.

extension Image {
    /// How big a symbol is beside text of its font.
    public enum Scale: Hashable, Sendable {
        case small
        case medium
        case large
    }
}

struct _ImageScaleKey: EnvironmentKey {
    static let defaultValue: Image.Scale = .medium
}

extension EnvironmentValues {
    /// The scale of the symbols inside (`.imageScale(_:)`).
    public var imageScale: Image.Scale {
        get { self[_ImageScaleKey.self] }
        set { self[_ImageScaleKey.self] = newValue }
    }
}

extension View {
    /// The scale of the symbols inside.
    nonisolated public func imageScale(_ scale: Image.Scale) -> some View {
        _EnvironmentModifier(child: self, descend: "imagescale") { env in env.imageScale = scale }
    }
}
