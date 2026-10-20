// `ShareLink` — hands text or a link to the platform's share sheet. Its
// label is a button's; what it shares rides the node (param "share") for
// hosts that make the system's own ShareLink (Apple), and its tap asks the
// others to share through the platform channel (`platformCommand("share",
// item)`: the web's navigator.share, Android's share intent).

#if canImport(Foundation)
import Foundation
#endif

/// What the share sheet shows for the item (`SharePreview("Visor log")`):
/// its title. Apple's shape: generic over a preview image and icon (none
/// here: `Never`).
#if !ISOMER_COMPILED_FEATURE
@available(iOS 16.0, macOS 13.0, *)
#endif
public struct SharePreview<Image: Transferable, Icon: Transferable> {
    let title: String
}

#if !ISOMER_COMPILED_FEATURE
@available(iOS 16.0, macOS 13.0, *)
#endif
extension SharePreview where Image == Never, Icon == Never {
    @_disfavoredOverload
    public init<S: StringProtocol>(_ title: S) { self.title = String(title) }

    public init(_ title: Text) { self.title = title.content }
}

public struct ShareLink<Label: View> {
    let item: String
    let subject: String?
    let message: String?
    var previewTitle: String? = nil
    let label: Label

    public typealias Body = Never
    public var body: Never { fatalError("primitive view") }

    public init(item: String, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.item = item
        self.subject = subject?.content
        self.message = message?.content
        self.label = label()
    }

    /// With the share sheet's preview of the item (Apple's: any
    /// Transferable item; Isomer shares a string's or a URL's text).
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 16.0, macOS 13.0, *)
    #endif
    public init<I: Transferable, PreviewImage: Transferable, PreviewIcon: Transferable>(
        item: I, subject: Text? = nil, message: Text? = nil,
        preview: SharePreview<PreviewImage, PreviewIcon>, @ViewBuilder label: () -> Label
    ) {
        let text: String
        if let string = item as? String { text = string }
        else if let url = item as? URL { text = url.absoluteString }
        else { text = String(describing: item) }
        self.init(item: text, subject: subject, message: message, label: label)
        self.previewTitle = preview.title
    }

    #if canImport(Foundation)
    public init(item: URL, subject: Text? = nil, message: Text? = nil, @ViewBuilder label: () -> Label) {
        self.init(item: item.absoluteString, subject: subject, message: message, label: label)
    }
    #endif
}

// The system's share label. `SwiftUI.Label`: inside `ShareLink` the name is
// its generic parameter.
extension ShareLink where Label == SwiftUI.Label<Text, Image> {
    /// The system's label: "Share" and its glyph.
    public init(item: String, subject: Text? = nil, message: Text? = nil) {
        self.init(item: item, subject: subject, message: message) {
            SwiftUI.Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    public init<S: StringProtocol>(_ title: S, item: String, subject: Text? = nil, message: Text? = nil) {
        let title = String(title)
        self.init(item: item, subject: subject, message: message) {
            SwiftUI.Label(title, systemImage: "square.and.arrow.up")
        }
    }
}

extension ShareLink: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let style = Runtime.shared.buttonStyleStack.last ?? .automatic
        var sub = ctx.descend("share")
        // A link's label is tinted as a button's is (plain keeps its own).
        if style.name != "plain" { sub.env.foregroundColor = ctx.env.tint ?? .accentColor }
        let node = RenderNode.box(child: buildNode(view: label, ctx: &sub))
        let item = item
        node.tapAction = { Runtime.shared.host?.platformCommand("share", item) }
        node.pressFeedback = .ripple
        node.shareItem = item
        node.shareSubject = subject
        node.shareMessage = message
        node.shareStyle = style.name
        node.sharePreview = previewTitle
        return node
    }
}

extension ShareLink: View {}
