// `Link` — a control that opens a URL. It is a button, as SwiftUI's draws
// one (its label tinted as a button's is, a row in a Form), whose tap asks
// the host to open the URL the system's way: a new tab on the web, the
// browser on Android, the system's handler on Apple (the platform channel's
// "openURL", as the drawn media placeholders do).

#if canImport(Foundation)
import Foundation

public struct Link<Label: View> {
    let destination: String
    let label: Label

    public init(destination: URL, @ViewBuilder label: () -> Label) {
        self.destination = destination.absoluteString
        self.label = label()
    }
}

extension Link where Label == Text {
    /// A link whose label is the text of `titleKey`.
    public init(_ titleKey: LocalizedStringKey, destination: URL) {
        self.init(destination: destination) { Text(titleKey) }
    }

    /// A link whose label is `title`, verbatim.
    public init<S: StringProtocol>(_ title: S, destination: URL) {
        self.init(destination: destination) { Text(title) }
    }
}

extension Link: View {
    public var body: some View {
        let url = destination
        return Button(action: { Runtime.shared.host?.openURL(url) }) { label }
    }
}
#endif
