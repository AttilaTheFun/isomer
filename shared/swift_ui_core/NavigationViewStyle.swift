// `NavigationViewStyle`: how a (deprecated) `NavigationView` lays out its
// columns. Isomer's `NavigationView` is always a stack (Navigation.swift),
// so `.stack` and `.automatic` are what it does already, and the column
// styles show it as a stack too (an app wanting columns uses
// `NavigationSplitView`, as Apple's deprecation message says). The protocol
// requires nothing of Isomer's styles: Apple's requirements are underscored
// (`_body(configuration:)`), and no app writes a style of its own.

public protocol NavigationViewStyle {}

/// The platform's choice: a stack on iPhone (and in Isomer).
public struct DefaultNavigationViewStyle: NavigationViewStyle {
    public init() {}
}

/// One view at a time, pushed and popped.
public struct StackNavigationViewStyle: NavigationViewStyle {
    public init() {}
}

/// Two columns where there is room (shown as a stack in Isomer).
public struct DoubleColumnNavigationViewStyle: NavigationViewStyle {
    public init() {}
}

/// Columns side by side (shown as a stack in Isomer).
public struct ColumnNavigationViewStyle: NavigationViewStyle {
    init() {}
}

extension NavigationViewStyle where Self == DefaultNavigationViewStyle {
    public static var automatic: DefaultNavigationViewStyle { DefaultNavigationViewStyle() }
}

extension NavigationViewStyle where Self == StackNavigationViewStyle {
    public static var stack: StackNavigationViewStyle { StackNavigationViewStyle() }
}

extension NavigationViewStyle where Self == ColumnNavigationViewStyle {
    public static var columns: ColumnNavigationViewStyle { ColumnNavigationViewStyle() }
}

extension View {
    /// `.navigationViewStyle(_:)`: accepted; every style is a stack here.
    nonisolated public func navigationViewStyle<S: NavigationViewStyle>(_ style: S) -> some View { self }
}
