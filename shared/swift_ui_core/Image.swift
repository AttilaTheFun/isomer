// Images: bundled assets (`Image("name")`) and remote URLs
// (`AsyncImage(url:)`). Decoding and loading happen on the host; the runtime
// only sees an opaque source string plus a readiness status, and hosts call
// `scheduleRender()` when an asynchronous load finishes.

/// Minimal URL type for non-Apple platforms (Foundation is not linked there).
/// On Apple platforms application code gets Foundation's URL via SwiftUI.

/// Host-reported status of an image source.
import Foundation


public enum ContentMode: Sendable {
    case fit
    case fill
}

public struct Image {
    let source: String
    let isRemote: Bool
    var isResizable = false
    var contentMode: ContentMode?
    /// `.interpolation(.none)`: no smoothing (pixel art, QR codes).
    var interpolation: Interpolation?

    public enum Interpolation: Sendable { case none, low, medium, high }

    public func interpolation(_ interpolation: Interpolation) -> Image {
        var copy = self
        copy.interpolation = interpolation
        return copy
    }
    /// A decoded picture this image draws (`Image(_ cgImage:…)`): kept with
    /// the view so the host keeps its bitmap while the view is drawn.
    var handle: AnyObject?

    /// The way a picture is turned (`Image(_:scale:orientation:label:)`).
    public enum Orientation: UInt8, Sendable {
        case up, upMirrored, down, downMirrored, left, leftMirrored, right, rightMirrored
    }

    /// Set for `Image(systemName:)`: the SF-symbol name's mapped glyph,
    /// rendered as a text run in the environment font/color (the
    /// reimplementation ships no symbol atlas).
    var systemGlyph: String?

    /// A bundled asset by name (extension optional; hosts try `<name>` then
    /// `<name>.png`).
    public init(_ name: String) {
        source = name
        isRemote = false
    }

    /// An SF Symbol by name, approximated with a Unicode glyph so shared
    /// SwiftUI source using common symbols (`gearshape`, `plus`, chevrons…)
    /// renders sensibly cross-platform; on Apple the real symbol draws.
    /// Unmapped names fall back to a generic placeholder glyph.
    public init(systemName: String) {
        source = systemName
        isRemote = false
        systemGlyph = Image.glyph(forSystemName: systemName)
    }

    init(remote url: String) {
        source = url
        isRemote = true
    }

    /// Unicode approximations for common SF Symbol names (base names double
    /// as fallbacks for their variants, e.g. `plus.circle.fill` → `plus`).
    static let systemGlyphs: [String: String] = [
        "plus": "+", "minus": "\u{2212}", "xmark": "\u{2715}",
        "checkmark": "\u{2713}", "gearshape": "\u{2699}\u{FE0E}",
        "gear": "\u{2699}\u{FE0E}", "magnifyingglass": "\u{1F50D}",
        "trash": "\u{1F5D1}\u{FE0E}", "pencil": "\u{270E}",
        "square": "\u{25A1}", "circle": "\u{25CB}",
        "chevron": "\u{203A}", "arrow": "\u{2192}",
        "ellipsis": "\u{2026}", "paperplane": "\u{2708}\u{FE0E}",
        "person": "\u{1F464}", "bell": "\u{1F514}", "star": "\u{2606}",
        "heart": "\u{2661}", "envelope": "\u{2709}\u{FE0E}",
        "calendar": "\u{1F4C5}", "camera": "\u{1F4F7}",
        "photo": "\u{1F5BC}\u{FE0E}", "mic": "\u{1F3A4}",
        "phone": "\u{260E}\u{FE0E}", "house": "\u{2302}",
        "info": "\u{24D8}", "questionmark": "?", "exclamationmark": "!",
        "chevron.left": "\u{2039}", "chevron.right": "\u{203A}",
        "chevron.up": "\u{2303}", "chevron.down": "\u{2304}",
        "arrow.left": "\u{2190}", "arrow.right": "\u{2192}",
        "arrow.up": "\u{2191}", "arrow.down": "\u{2193}",
        "line.3.horizontal": "\u{2630}",
        "square.and.arrow.up": "\u{2BAD}\u{FE0E}",
        "square.and.pencil": "\u{270E}",
        "cloud": "\u{2601}\u{FE0E}", "chart.bar.xaxis": "\u{1F4CA}",
        "chart": "\u{1F4CA}", "chart.pie": "\u{25D4}",
        "shippingbox": "\u{1F4E6}", "arrow.clockwise": "\u{21BB}",
        "arrow.counterclockwise": "\u{21BA}",
        "arrow.triangle.2.circlepath": "\u{21BB}",
        "creditcard": "\u{1F4B3}", "doc": "\u{1F5CE}\u{FE0E}",
        "folder": "\u{1F5C0}\u{FE0E}", "lock": "\u{1F512}\u{FE0E}",
        "key": "\u{1F511}\u{FE0E}", "globe": "\u{1F310}\u{FE0E}",
        "bolt": "\u{26A1}\u{FE0E}", "flame": "\u{1F525}\u{FE0E}",
        "drop": "\u{1F4A7}\u{FE0E}", "wifi": "\u{1F6DC}\u{FE0E}",
        "network": "\u{1F310}\u{FE0E}", "cpu": "\u{25A6}",
        "memorychip": "\u{25A6}", "externaldrive": "\u{1F5B4}\u{FE0E}",
        "server.rack": "\u{1F5C4}\u{FE0E}", "terminal": "\u{2318}",
        "tray": "\u{1F5C6}\u{FE0E}", "clock": "\u{1F552}\u{FE0E}",
        "eye": "\u{1F441}\u{FE0E}", "link": "\u{1F517}\u{FE0E}",
        "tag": "\u{1F3F7}\u{FE0E}", "map": "\u{1F5FA}\u{FE0E}",
        "gauge": "\u{23F1}\u{FE0E}", "speedometer": "\u{23F1}\u{FE0E}",
        // More of the names agents reach for.
        "play": "\u{25B6}\u{FE0E}", "pause": "\u{23F8}\u{FE0E}", "stop": "\u{25A0}",
        "backward": "\u{23EA}\u{FE0E}", "forward": "\u{23E9}\u{FE0E}",
        "speaker": "\u{1F508}\u{FE0E}", "speaker.wave.2": "\u{1F50A}\u{FE0E}",
        "speaker.slash": "\u{1F507}\u{FE0E}", "music.note": "\u{266B}",
        "sun.max": "\u{2600}\u{FE0E}", "moon": "\u{263D}", "moon.stars": "\u{263D}",
        "cloud.rain": "\u{1F327}\u{FE0E}", "cloud.sun": "\u{26C5}\u{FE0E}",
        "snowflake": "\u{2744}\u{FE0E}", "wind": "\u{1F32C}\u{FE0E}",
        "thermometer": "\u{1F321}\u{FE0E}", "umbrella": "\u{2602}\u{FE0E}",
        "leaf": "\u{1F343}", "sparkles": "\u{2728}", "sparkle": "\u{2728}",
        "wand.and.stars": "\u{2728}", "lightbulb": "\u{1F4A1}",
        "cart": "\u{1F6D2}", "bag": "\u{1F6CD}\u{FE0E}", "gift": "\u{1F381}",
        "bookmark": "\u{1F516}", "book": "\u{1F4D6}", "newspaper": "\u{1F4F0}",
        "paperclip": "\u{1F4CE}", "scissors": "\u{2702}\u{FE0E}",
        "hammer": "\u{1F528}", "wrench": "\u{1F527}", "screwdriver": "\u{1F6E0}\u{FE0E}",
        "gamecontroller": "\u{1F3AE}", "dice": "\u{1F3B2}", "trophy": "\u{1F3C6}",
        "medal": "\u{1F3C5}", "flag": "\u{2691}", "crown": "\u{1F451}",
        "location": "\u{27A4}", "mappin": "\u{1F4CD}", "compass": "\u{1F9ED}",
        "car": "\u{1F697}", "airplane": "\u{2708}\u{FE0E}", "bicycle": "\u{1F6B2}",
        "bus": "\u{1F68C}", "tram": "\u{1F68B}", "figure.walk": "\u{1F6B6}",
        "figure.run": "\u{1F3C3}", "fork.knife": "\u{1F374}", "cup.and.saucer": "\u{2615}",
        "pills": "\u{1F48A}", "cross": "\u{271A}", "bandage": "\u{1FA79}",
        "stethoscope": "\u{1FA7A}", "brain": "\u{1F9E0}", "pawprint": "\u{1F43E}",
        "hand.thumbsup": "\u{1F44D}", "hand.thumbsdown": "\u{1F44E}",
        "hand.wave": "\u{1F44B}", "hand.raised": "\u{270B}", "face.smiling": "\u{263A}\u{FE0E}",
        "message": "\u{1F4AC}", "bubble": "\u{1F4AC}", "bubble.left": "\u{1F4AC}",
        "text.bubble": "\u{1F4AC}", "quote.bubble": "\u{201C}",
        "at": "@", "number": "#", "dollarsign": "$", "percent": "%",
        "plus.circle": "\u{2295}", "minus.circle": "\u{2296}", "xmark.circle": "\u{2297}",
        "checkmark.circle": "\u{2705}", "checkmark.seal": "\u{2705}",
        "exclamationmark.triangle": "\u{26A0}\u{FE0E}", "exclamationmark.circle": "\u{2757}",
        "questionmark.circle": "\u{2753}", "info.circle": "\u{2139}\u{FE0E}",
        "lightning": "\u{26A1}\u{FE0E}", "battery.100": "\u{1F50B}",
        "battery.25": "\u{1FAAB}", "antenna.radiowaves.left.and.right": "\u{1F4E1}",
        "iphone": "\u{1F4F1}", "ipad": "\u{1F4F1}", "laptopcomputer": "\u{1F4BB}",
        "desktopcomputer": "\u{1F5A5}\u{FE0E}", "display": "\u{1F5A5}\u{FE0E}",
        "keyboard": "\u{2328}\u{FE0E}", "printer": "\u{1F5A8}\u{FE0E}",
        "headphones": "\u{1F3A7}", "tv": "\u{1F4FA}", "video": "\u{1F4F9}",
        "film": "\u{1F39E}\u{FE0E}", "photo.on.rectangle": "\u{1F5BC}\u{FE0E}",
        "square.grid.2x2": "\u{25A6}", "list.bullet": "\u{2630}", "list.dash": "\u{2630}",
        "text.alignleft": "\u{2630}", "slider.horizontal.3": "\u{2630}",
        "line.3.horizontal.decrease": "\u{2630}", "arrow.up.arrow.down": "\u{21C5}",
        "arrow.left.arrow.right": "\u{21C4}", "arrow.uturn.left": "\u{21A9}\u{FE0E}",
        "arrow.uturn.right": "\u{21AA}\u{FE0E}", "arrow.up.right": "\u{2197}\u{FE0E}",
        "arrow.down.left": "\u{2199}\u{FE0E}", "arrow.down.to.line": "\u{2913}",
        "arrow.up.to.line": "\u{2912}", "square.and.arrow.down": "\u{2B73}",
        "icloud": "\u{2601}\u{FE0E}", "arrow.down.circle": "\u{2B07}\u{FE0E}",
        "arrow.up.circle": "\u{2B06}\u{FE0E}", "shuffle": "\u{1F500}", "repeat": "\u{1F501}",
        "timer": "\u{23F2}\u{FE0E}", "stopwatch": "\u{23F1}\u{FE0E}", "alarm": "\u{23F0}",
        "hourglass": "\u{231B}", "calendar.badge.plus": "\u{1F4C5}",
        "person.2": "\u{1F465}", "person.3": "\u{1F465}", "person.crop.circle": "\u{1F464}",
        "person.circle": "\u{1F464}", "building": "\u{1F3E2}", "building.2": "\u{1F3D9}\u{FE0E}",
        "storefront": "\u{1F3EA}", "graduationcap": "\u{1F393}", "briefcase": "\u{1F4BC}",
        "banknote": "\u{1F4B5}", "chart.line.uptrend.xyaxis": "\u{1F4C8}",
        "chart.bar": "\u{1F4CA}", "list.clipboard": "\u{1F4CB}", "doc.text": "\u{1F4C4}",
        "doc.on.doc": "\u{1F4D1}", "note.text": "\u{1F4DD}", "text.justify": "\u{2630}",
        "textformat": "A", "bold": "B", "italic": "I", "underline": "U",
        "paintbrush": "\u{1F58C}\u{FE0E}", "paintpalette": "\u{1F3A8}", "eyedropper": "\u{1F489}",
        "hare": "\u{1F407}", "tortoise": "\u{1F422}", "ant": "\u{1F41C}", "bird": "\u{1F426}",
        "fish": "\u{1F41F}", "cat": "\u{1F408}", "dog": "\u{1F415}",
        "flame.fill": "\u{1F525}", "drop.fill": "\u{1F4A7}",
        "square.fill": "\u{25A0}", "circle.fill": "\u{25CF}", "star.fill": "\u{2605}",
        "heart.fill": "\u{2665}\u{FE0E}", "bell.fill": "\u{1F514}",
        "power": "\u{23FB}", "lock.open": "\u{1F513}\u{FE0E}", "shield": "\u{1F6E1}\u{FE0E}",
        "eye.slash": "\u{1F441}\u{FE0E}", "bolt.fill": "\u{26A1}",
        "waveform": "\u{223F}", "recordingtape": "\u{1F4FC}", "radio": "\u{1F4FB}",
        "globe.americas": "\u{1F30E}", "globe.europe.africa": "\u{1F30D}", "globe.asia.australia": "\u{1F30F}",
        "target": "\u{25CE}", "scope": "\u{25CE}", "trash.fill": "\u{1F5D1}\u{FE0E}",
        "arrow.triangle.branch": "\u{2387}", "square.on.square": "\u{29C9}",
        "rectangle": "\u{25AD}", "capsule": "\u{2B2D}", "triangle": "\u{25B3}", "diamond": "\u{25C7}",
        "hexagon": "\u{2B21}", "octagon": "\u{2B22}", "seal": "\u{2B2A}",
        "sunrise": "\u{1F305}", "sunset": "\u{1F307}", "sparkles.rectangle.stack": "\u{2728}",
    ]

    /// The glyph an SF name resolves to on hosts without SF Symbols: the
    /// exact name, then the name with its `.fill` / `.circle` / … suffixes
    /// peeled off one at a time, then the base name; unmapped names show
    /// U+FFFD, the standard missing-glyph mark. (The Apple host draws the
    /// real symbol from the name and only shows this when the symbol itself
    /// doesn't exist.) Shared with the tab-bar label params so tabs and
    /// inline images agree.
    static func glyph(forSystemName name: String) -> String {
        if let exact = systemGlyphs[name] { return exact }
        var parts = name.split(separator: ".").map(String.init)
        while parts.count > 1 {
            parts.removeLast()
            if let found = systemGlyphs[parts.joined(separator: ".")] { return found }
        }
        return "\u{FFFD}"
    }

    public typealias Body = Never

    /// How a resizable image fills its frame: stretched (tiling is drawn
    /// as stretching).
    public enum ResizingMode: Hashable, Sendable {
        case tile
        case stretch
    }

    public func resizable(capInsets: EdgeInsets = EdgeInsets(), resizingMode: Image.ResizingMode = .stretch) -> Image {
        var copy = self
        copy.isResizable = true
        return copy
    }
}

extension Image: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        // Inside a TabView's tab bar, an unsized `Image` becomes a fixed-size
        // icon (matching how the native tab bar treats `.tabItem` images).
        // `Image(systemName:)` renders as a text glyph in the environment's
        // font and foreground color (like a template symbol tints).
        if let glyph = systemGlyph {
            // A text glyph stands in for the symbol (component hosts without
            // SF Symbols show it); the Apple host draws the real symbol.
            let node = RenderNode(kind: .text(glyph))
            node.symbolName = source
            node.symbolIsImage = true
            node.symbolSecondary = ctx.env.foregroundSecondary
            node.font = ctx.env.font
            node.color = ctx.env.foregroundColor
            node.colorAuto = !ctx.env.foregroundColorSet
            node.opacity = ctx.env.opacity
            return node
        }
        if let iconSize = ctx.env.tabIconSize {
            let node = RenderNode(kind: .image(
                source: source, isRemote: isRemote, resizable: true, fit: true
            ))
            node.fixedWidth = iconSize
            node.fixedHeight = iconSize
            node.opacity = ctx.env.opacity
            return node
        }
        // A decoded picture whose host decodes at the first draw: its bytes
        // go over once.
        if let pending = handle as? _PendingImageBytes, !Runtime.shared.handedImages.contains(source),
           let bytes = pending._pendingBytes {
            Runtime.shared.handedImages.insert(source)
            Runtime.shared.host?.registerImage(source, bytes: bytes)
        }
        let node = RenderNode(kind: .image(
            source: source,
            isRemote: isRemote,
            resizable: isResizable,
            fit: contentMode != .fill
        ))
        node.opacity = ctx.env.opacity
        if interpolation == Interpolation.none { node.imageInterpolation = "none" }
        return node
    }
}

/// SVG (incl. animated SVG) and GIF are best rendered by the platform's native
/// image view (`<img>` on web), which animates and vector-scales them for free.
func isNativeImageFormat(_ source: String) -> Bool {
    // Only the ends that name the format are looked at: a data: URL's media
    // type, else the path's extension. A data: URL can carry megabytes of
    // image, and this runs on every build.
    let bytes = source.utf8
    func lowercased<S: Sequence>(_ part: S) -> String where S.Element == UInt8 {
        String(decoding: part.map { $0 >= 65 && $0 <= 90 ? $0 + 32 : $0 }, as: UTF8.self)
    }
    if bytes.starts(with: "data:".utf8) || bytes.starts(with: "DATA:".utf8) {
        let head = lowercased(bytes.prefix(40))
        return head.hasPrefix("data:image/svg") || head.hasPrefix("data:image/gif")
    }
    // The path's end: before any query or fragment.
    let end = bytes.firstIndex(where: { $0 == UInt8(ascii: "?") || $0 == UInt8(ascii: "#") }) ?? bytes.endIndex
    let tail = lowercased(bytes[bytes.startIndex..<end].suffix(5))
    return tail.hasSuffix(".svg") || tail.hasSuffix(".gif")
}

/// A native image host view (web `<img>`, Android `ImageView`). The URL travels
/// in `value`; the host resolves bundled vs remote sources.
func nativeImageNode(source: String, ctx: BuildContext) -> RenderNode {
    // Canonical semantic node (component systems animate/vector-scale these
    // natively); the self-drawing path swaps in a plain `.image` node via
    // chrome expansion and decodes still frames at the GPU layer.
    let spec = HostViewSpec(
        id: ctx.path, kind: "image", params: [:], value: source, options: [], onChange: nil)
    let node = RenderNode(kind: .hostView(spec))
    node.identityPath = ctx.path
    node.opacity = ctx.env.opacity
    return node
}

/// `AsyncImage(url:)` shows the loaded image (or a placeholder). The
/// content-closure form `AsyncImage(url:) { $0.resizable().scaledToFill() }
/// placeholder: { ... }` lets the app transform the loaded `Image` (e.g. to
/// fill-and-clip a thumbnail), matching real SwiftUI.
public struct AsyncImage {
    let url: URL?
    let makeContent: ((Image) -> AnyView)?
    let makePlaceholder: (() -> AnyView)?

    public init(url: URL?, scale: CGFloat = 1) {
        self.url = url
        self.makeContent = nil
        self.makePlaceholder = nil
    }

    public init<I: View, P: View>(
        url: URL?,
        scale: CGFloat = 1,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) {
        self.url = url
        self.makeContent = { AnyView(content($0)) }
        self.makePlaceholder = { AnyView(placeholder()) }
    }

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }
}

extension AsyncImage: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        guard let url else {
            if let makePlaceholder {
                var sub = ctx.descend("asyncplaceholder")
                return buildNode(view: makePlaceholder(), ctx: &sub)
            }
            return RenderNode(kind: .shape(.rectangle, fill: Color(white: 0, opacity: 0.08), stroke: nil))
        }
        // Vector / animated formats (SVG, animated SVG, GIF) render through the
        // platform's native image view, which handles them for free.
        if isNativeImageFormat(url.absoluteString) {
            return nativeImageNode(source: url.absoluteString, ctx: ctx)
        }
        // Content-closure form: query the load status (kicks off the load) and
        // build the transformed image once ready, else the placeholder.
        if let makeContent, let makePlaceholder {
            let status = Runtime.shared.host?.imageInfo(url.absoluteString, isRemote: true) ?? .loading
            if case .ready = status {
                var sub = ctx.descend("asynccontent")
                return buildNode(view: makeContent(Image(remote: url.absoluteString)), ctx: &sub)
            }
            var sub = ctx.descend("asyncplaceholder")
            return buildNode(view: makePlaceholder(), ctx: &sub)
        }
        let node = RenderNode(kind: .image(
            source: url.absoluteString,
            isRemote: true,
            resizable: false,
            fit: true
        ))
        node.opacity = ctx.env.opacity
        return node
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension Image: View {}
extension AsyncImage: View {}


/// Pictures an app already holds the bytes of (fetched over its own
/// connection, read from its own store): handed to the host once, decoded and
/// scaled there off the main thread, and drawn by a short URL. A view names
/// the URL (`AsyncImage(url:)`, `Image(remote:)`) instead of carrying the
/// picture in a `data:` URL, which crossed to the host, whole, with every
/// frame that built it.
@MainActor
package enum IsomerImages {
    /// The keys handed over so far.
    private static var registered: Set<String> = []

    /// The URL that draws `bytes` (an encoded PNG, JPEG, WebP, GIF), handing
    /// them to the host the first time `key` is seen. The same key always
    /// names the same picture; register it again only after `release`.
    @discardableResult
    public static func register(_ bytes: [UInt8], key: String) -> URL {
        let source = url(for: key)
        if !registered.contains(key) {
            registered.insert(key)
            Runtime.shared.host?.registerImage(source, bytes: bytes)
        }
        return URL(string: source)!
    }

    /// Whether `key`'s bytes have been handed over (its URL draws them).
    public static func isRegistered(_ key: String) -> Bool { registered.contains(key) }

    /// The URL a registered key draws by.
    public static func url(for key: String) -> String {
        "isomer-image://" + key
    }

    /// Forget `key` here; the host keeps what it decoded until it is asked
    /// to draw something else in its place.
    public static func release(_ key: String) {
        registered.remove(key)
        Runtime.shared.host?.registerImage(url(for: key), bytes: [])
    }
}


/// A decoded picture's handle as SwiftUI sees it (ImageIO's `CGImage`).
protocol _PendingImageBytes: AnyObject {
    var _source: String { get }
    var _pendingBytes: [UInt8]? { get }
}
