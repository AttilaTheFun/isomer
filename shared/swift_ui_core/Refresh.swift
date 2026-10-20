// `.refreshable` and `ContentUnavailableView`.

extension View {
    /// SwiftUI's `.refreshable`: the action is in the environment of the
    /// views inside (`@Environment(\.refresh)`), for a control of the app's
    /// own to run. The hosts have no pull-to-refresh gesture of their own
    /// yet, so a list offers none; on a pointer platform there would be none
    /// anyway.
    nonisolated public func refreshable(@_inheritActorContext action: @escaping @Sendable () async -> Void) -> some View {
        environment(\.refresh, RefreshAction(action: action))
    }
}

/// SwiftUI's `ContentUnavailableView`: what a screen shows in place of
/// content it does not have — a symbol, a title, a line of explanation,
/// and what can be done about it.
public struct ContentUnavailableView<Label: View, Description: View, Actions: View> {
    let label: Label
    let description: Description
    let actions: Actions

    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    public init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder description: () -> Description = { EmptyView() },
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.label = label()
        self.description = description()
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: 10) {
            label
                .labelStyle(ContentUnavailableLabelStyle())
            description
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            actions
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
    }
}

extension ContentUnavailableView where Label == SwiftUI.Label<Text, Image>, Description == Text?, Actions == EmptyView {
    public init<S: StringProtocol>(_ title: S, systemImage: String, description: Text? = nil) {
        let title = String(title)
        self.label = SwiftUI.Label(title, systemImage: systemImage)
        self.description = description
        self.actions = EmptyView()
    }
}

/// How an unavailable view lays its label out, as the system does: the
/// symbol large above the title.
struct ContentUnavailableLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 8) {
            configuration.icon
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            configuration.title
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
        }
    }
}

// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension ContentUnavailableView: View {}
