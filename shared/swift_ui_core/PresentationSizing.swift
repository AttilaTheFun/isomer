// `PresentationSizing`: how big a sheet is where the platform sizes sheets
// (the Mac's, an iPad's, the desktop hosts'), as Apple's. The built-in
// sizings travel to the host by name (sheet param "sizing"); on a phone a
// sheet is the screen's, whatever its sizing.

/// How big a presentation is: Apple's protocol. Isomer's are the built-in
/// ones; a sizing of an app's own is taken as `.automatic`.
public protocol PresentationSizing {}

/// The built-in sizings, by the name the host knows them by.
protocol _NamedPresentationSizing: PresentationSizing {
    var _sizingName: String { get }
}

/// The platform's choice: a form's size on the Mac and an iPad, the
/// screen's on a phone.
public struct AutomaticPresentationSizing: PresentationSizing, _NamedPresentationSizing {
    var _sizingName: String { "automatic" }
}

/// A form's size: a sheet of the platform's width for forms, as tall as
/// its content.
public struct FormPresentationSizing: PresentationSizing, _NamedPresentationSizing {
    var _sizingName: String { "form" }
}

/// A page's size: wide and tall, for reading.
public struct PagePresentationSizing: PresentationSizing, _NamedPresentationSizing {
    var _sizingName: String { "page" }
}

/// Its content's size.
public struct FittedPresentationSizing: PresentationSizing, _NamedPresentationSizing {
    var _sizingName: String { "fitted" }
}

extension PresentationSizing where Self == AutomaticPresentationSizing {
    public static var automatic: AutomaticPresentationSizing { AutomaticPresentationSizing() }
}

extension PresentationSizing where Self == FormPresentationSizing {
    public static var form: FormPresentationSizing { FormPresentationSizing() }
}

extension PresentationSizing where Self == PagePresentationSizing {
    public static var page: PagePresentationSizing { PagePresentationSizing() }
}

extension PresentationSizing where Self == FittedPresentationSizing {
    public static var fitted: FittedPresentationSizing { FittedPresentationSizing() }
}

extension View {
    /// How big the sheet this view is the content of is, where the
    /// platform sizes sheets.
    nonisolated public func presentationSizing(_ sizing: some PresentationSizing) -> some View {
        let name = (sizing as? _NamedPresentationSizing)?._sizingName ?? "automatic"
        return _ModifiedView(child: self, descend: "sizing", pure: true) { inner, _ in
            inner.presentationSizing = name
            return inner
        }
    }
}
