// More of SwiftUI's environment values: what a view asks of where it is
// (`isPresented`, `isSearching`), how text is laid out (`layoutDirection`,
// `dynamicTypeSize`), and actions it calls
// (`openURL`, `dismissSearch`). Each is settable with `.environment(_:_:)`
// as SwiftUI's are.

#if canImport(Foundation)
import Foundation
#endif

/// The direction text runs in. Isomer's hosts lay out left to right.
public enum LayoutDirection: Hashable, Sendable, CaseIterable {
    case leftToRight
    case rightToLeft
}

/// The text size the reader chose. Isomer's hosts report the default.
public enum DynamicTypeSize: Hashable, Comparable, Sendable, CaseIterable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    /// One of the five accessibility sizes.
    public var isAccessibilitySize: Bool { self >= .accessibility1 }
}

/// Clears the search field and ends the search
/// (`@Environment(\.dismissSearch)`); nothing outside a searchable view.
public struct DismissSearchAction {
    let action: () -> Void
    public func callAsFunction() { action() }
}

private struct _IsPresentedKey: EnvironmentKey { static let defaultValue = false }
private struct _IsSearchingKey: EnvironmentKey { static let defaultValue = false }
private struct _DismissSearchKey: EnvironmentKey { static let defaultValue = DismissSearchAction(action: {}) }
private struct _LayoutDirectionKey: EnvironmentKey { static let defaultValue = LayoutDirection.leftToRight }
private struct _DynamicTypeSizeKey: EnvironmentKey { static let defaultValue = DynamicTypeSize.large }

extension EnvironmentValues {
    /// Whether the view is in a presentation (a sheet, a cover, a popover)
    /// that is showing.
    public var isPresented: Bool {
        get { self[_IsPresentedKey.self] }
        set { self[_IsPresentedKey.self] = newValue }
    }

    /// Whether the search of the searchable view this is in has a query.
    public var isSearching: Bool {
        get { self[_IsSearchingKey.self] }
        set { self[_IsSearchingKey.self] = newValue }
    }

    public var dismissSearch: DismissSearchAction {
        get { self[_DismissSearchKey.self] }
        set { self[_DismissSearchKey.self] = newValue }
    }

    public var layoutDirection: LayoutDirection {
        get { self[_LayoutDirectionKey.self] }
        set { self[_LayoutDirectionKey.self] = newValue }
    }

    public var dynamicTypeSize: DynamicTypeSize {
        get { self[_DynamicTypeSizeKey.self] }
        set { self[_DynamicTypeSizeKey.self] = newValue }
    }
}

#if canImport(Foundation)
/// Opens a URL the system's way (`@Environment(\.openURL)`): a new tab on
/// the web, the browser on Android, the system's handler on Apple; an app
/// can put its own handler in with `.environment(\.openURL, …)`.
public struct OpenURLAction {
    /// What a handler did with the URL.
    public struct Result: Sendable {
        let kind: Int
        /// Handled here: the system is not asked.
        public static let handled = Result(kind: 0)
        /// Not handled: dropped.
        public static let discarded = Result(kind: 1)
        /// Left to the system.
        public static let systemAction = Result(kind: 2)
        /// Another URL for the system to open instead.
        public static func systemAction(_ url: URL) -> Result { Result(kind: 3, url: url) }
        var url: URL? = nil
        init(kind: Int, url: URL? = nil) { self.kind = kind; self.url = url }
    }

    let handler: (URL) -> Result

    public init(handler: @escaping (URL) -> Result) {
        self.handler = handler
    }

    public func callAsFunction(_ url: URL) {
        let result = handler(url)
        switch result.kind {
        case 2: Runtime.shared.host?.openURL(url.absoluteString)
        case 3: if let other = result.url { Runtime.shared.host?.openURL(other.absoluteString) }
        default: break
        }
    }

    /// With a completion told whether the URL was opened.
    public func callAsFunction(_ url: URL, completion: @escaping (Bool) -> Void) {
        let result = handler(url)
        callAsFunction(url)
        completion(result.kind != 1)
    }
}

private struct _OpenURLKey: EnvironmentKey {
    static let defaultValue = OpenURLAction { _ in .systemAction }
}

extension EnvironmentValues {
    public var openURL: OpenURLAction {
        get { self[_OpenURLKey.self] }
        set { self[_OpenURLKey.self] = newValue }
    }

    /// The reader's locale, time zone and calendar (the host's).
    public var locale: Locale {
        get { self[_LocaleKey.self] }
        set { self[_LocaleKey.self] = newValue }
    }

    public var timeZone: TimeZone {
        get { self[_TimeZoneKey.self] }
        set { self[_TimeZoneKey.self] = newValue }
    }

    public var calendar: Calendar {
        get { self[_CalendarKey.self] }
        set { self[_CalendarKey.self] = newValue }
    }
}

private struct _LocaleKey: EnvironmentKey { static var defaultValue: Locale { Locale.current } }
private struct _TimeZoneKey: EnvironmentKey { static var defaultValue: TimeZone { TimeZone.current } }
private struct _CalendarKey: EnvironmentKey { static var defaultValue: Calendar { Calendar.current } }
#endif
