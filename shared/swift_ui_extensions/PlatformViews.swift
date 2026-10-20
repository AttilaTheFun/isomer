import SwiftUI

// Bridging platform-native components into the view hierarchy.
//
// `PlatformViewRepresentable` is the cross-platform analogue of
// UIViewRepresentable: the app declares *which* native widget it wants (by a
// `kind` the host understands) plus parameters and a value, and receives a
// callback when the user changes it. The host materializes a real DOM element
// (web) / Android View over the canvas, keyed by structural identity. It is
// Isomer's, not Apple's, so it is here and not in SwiftUI; its body is the
// host view node the runtime builds (SwiftUI's `hostViewNode`, Isomer's
// package plumbing). On Apple platforms an app uses UIViewRepresentable/
// NSViewRepresentable.

/// A native widget the host materializes by `kind`.
public protocol PlatformViewRepresentable: View {
    /// A kind the host knows how to materialize (e.g. "html:color").
    var kind: String { get }
    /// JSON-safe configuration passed to the host.
    var parameters: [String: String] { get }
    /// The current value (also JSON-safe).
    var value: String { get }
    /// Invoked when the host reports the user changed the widget.
    func onValueChanged(_ value: String)
}

extension PlatformViewRepresentable {
    public var parameters: [String: String] { [:] }

    /// The host's widget, built where the view stands.
    public var body: some View {
        HostViewPrimitive(kind: kind, parameters: parameters, value: value, onChange: { onValueChanged($0) })
    }
}

// MARK: - Conditionally-compiled platform-specific representables

// These refine `PlatformViewRepresentable` with a platform-flavored vocabulary
// and satisfy its requirements through protocol extensions, so a conforming
// type only declares what is specific to that platform. Each exists only when
// compiling for its platform, so it is paired with `#if os(...)` in app code.

#if os(WASI)
/// Bridges a native HTML form element into the view tree on the web. Conformers
/// provide an `inputType` (the `<input type=…>`) and a value; the rest of
/// `PlatformViewRepresentable` is fulfilled here.
public protocol WasmViewRepresentable: PlatformViewRepresentable {
    /// The HTML input type to materialize, e.g. "color", "range", "file".
    var inputType: String { get }
    /// The element's current value.
    var htmlValue: String { get }
    /// Called when the user edits the element.
    func valueChanged(_ value: String)
}

extension WasmViewRepresentable {
    public var kind: String { "html:\(inputType)" }
    public var value: String { htmlValue }
    public func onValueChanged(_ value: String) { valueChanged(value) }
}
#endif

#if os(Android)
/// Bridges a native Android widget into the view tree. Conformers name the
/// `widget` the host should inflate and a value; the rest of
/// `PlatformViewRepresentable` is fulfilled here.
public protocol AndroidViewRepresentable: PlatformViewRepresentable {
    /// Identifies the native widget for the host (e.g. "ratingbar").
    var widget: String { get }
    /// The widget's current value.
    var widgetValue: String { get }
    /// Called when the user changes the widget.
    func valueChanged(_ value: String)
}

extension AndroidViewRepresentable {
    public var kind: String { "android:\(widget)" }
    public var value: String { widgetValue }
    public func onValueChanged(_ value: String) { valueChanged(value) }
}
#endif

#if os(Windows)
/// Bridges a native Win32 control into the view tree on Windows. Conformers name
/// the `control` the host should create and a value; the rest of
/// `PlatformViewRepresentable` is fulfilled here. The Windows host materializes a
/// real child-window control (e.g. `trackbar` -> `msctls_trackbar32`) over the
/// canvas and reports edits back through the host-view event channel.
public protocol WindowsViewRepresentable: PlatformViewRepresentable {
    /// Identifies the native control for the host (e.g. "trackbar").
    var control: String { get }
    /// The control's current value.
    var controlValue: String { get }
    /// Called when the user changes the control.
    func valueChanged(_ value: String)
}

extension WindowsViewRepresentable {
    public var kind: String { "win:\(control)" }
    public var value: String { controlValue }
    public func onValueChanged(_ value: String) { valueChanged(value) }
}

/// A native Win32 trackbar (`msctls_trackbar32`) bound to an integer 0...100.
/// A concrete `WindowsViewRepresentable` the example uses to demonstrate the
/// bridge; app code can define its own conformers for other native controls.
public struct NativeSlider {
    let binding: Binding<Int>

    public init(value: Binding<Int>) {
        self.binding = value
    }

    public var control: String { "trackbar" }
    public var controlValue: String { String(binding.wrappedValue) }
    public func valueChanged(_ newValue: String) {
        if let v = Int(newValue) { binding.wrappedValue = v }
    }
}
#endif

#if os(Linux)
/// Bridges a host-drawn Linux control into the view tree. Conformers name the
/// `control` the host should draw and a value; the rest of
/// `PlatformViewRepresentable` is fulfilled here. The Linux host (renderer.c)
/// draws the named control over the GL surface and reports edits back through
/// the host-view event channel — the analogue of the Windows native child
/// window, drawn rather than a real widget (the SDL/OpenGL surface can't host
/// GTK widgets).
public protocol LinuxViewRepresentable: PlatformViewRepresentable {
    /// Identifies the control the host should draw (e.g. "trackbar").
    var control: String { get }
    /// The control's current value.
    var controlValue: String { get }
    /// Called when the user changes the control.
    func valueChanged(_ value: String)
}

extension LinuxViewRepresentable {
    public var kind: String { "linux:\(control)" }
    public var value: String { controlValue }
    public func onValueChanged(_ value: String) { valueChanged(value) }
}

/// A host-drawn horizontal slider bound to an integer 0...100. A concrete
/// `LinuxViewRepresentable` the example uses to demonstrate the bridge; app code
/// can define its own conformers for other host-drawn controls.
public struct NativeSlider {
    let binding: Binding<Int>

    public init(value: Binding<Int>) {
        self.binding = value
    }

    public var control: String { "trackbar" }
    public var controlValue: String { String(binding.wrappedValue) }
    public func valueChanged(_ newValue: String) {
        if let v = Int(newValue) { binding.wrappedValue = v }
    }
}
#endif

// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
#if os(Windows)
extension NativeSlider: WindowsViewRepresentable {}
#elseif os(Linux)
extension NativeSlider: LinuxViewRepresentable {}
#endif
