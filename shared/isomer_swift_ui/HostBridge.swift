// What a host gives Isomer's SwiftUI: its services (text measurement,
// images, rasterizing, native host views, text input, time, the platform
// channel) and, for a host that draws the frame itself, the drawing calls.
// Isomer's SwiftUI modules read it (`Runtime.host`); each platform's runtime
// implements it over its host (the browser, Android, the desktop hosts), and
// an application's own host can too. All coordinates are in logical points;
// the host applies display scaling.

import Foundation

/// A colour as a host draws it: resolved for the color scheme in effect, in
/// sRGB, with the system colour's name where it is one ("blue",
/// "secondaryBackground") for a host that has its own.
public struct HostColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var opacity: Double
    public var name: String?

    public init(red: Double, green: Double, blue: Double, opacity: Double, name: String? = nil) {
        self.red = red
        self.green = green
        self.blue = blue
        self.opacity = opacity
        self.name = name
    }
}

/// An image's state, as a host reports it: loading, failed, or ready at a
/// size in points.
public enum ImageStatus: Sendable {
    case loading
    case failed
    case ready(CGSize)
}

public protocol HostBridge {
    /// Measure a single- or multi-line text run, wrapping at `wrapWidth`.
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize

    /// Query (and implicitly start loading) an image. Hosts cache by source
    /// and call `scheduleRender()` when an asynchronous load completes.
    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus

    func beginFrame(width: Double, height: Double)
    func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor)
    func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor)
    /// Fill a (rounded) rect with a gradient described by `gradientJSON`.
    func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String)
    /// Draw a soft drop shadow of the rounded rect behind it.
    func drawShadow(
        _ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double
    )
    func drawText(
        _ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor
    )
    /// Draw an image into `dest` (its aspect-fit/fill rect, which may overflow
    /// `clip`), clipped to the rounded rect `clip` / `cornerRadius`.
    func drawImage(
        _ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect,
        cornerRadius: Double, opacity: Double
    )
    func pushClip(_ rect: CGRect, cornerRadius: Double)
    func popClip()

    /// Push/pop a 2D affine transform `(a,b,c,d,e,f)` applied to subsequent draw
    /// primitives (`.rotationEffect` / `.scaleEffect`).
    func pushTransform(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double)
    func popTransform()

    /// Reconcile the set of platform-native widgets overlaid on the canvas
    /// this frame (Picker/DatePicker/representables). `viewsJSON` is an array
    /// of {id, kind, frame, params, value, options}; the host creates,
    /// positions, updates, and removes its native widgets to match, and
    /// reports edits back as host-view events.
    func syncHostViews(_ viewsJSON: String)

    /// Structured reconcile of native WebViews, used by hosts (Windows) that
    /// back `WebView` with a real native browser child window rather than the
    /// generic `syncHostViews` JSON. Called each frame: `begin`, then one
    /// `syncWebView` per webview host view, then `end` (which removes any not
    /// synced this frame). Frames are in logical points. Default: no-op.
    func beginHostViewSync()
    func syncWebView(id: String, url: String, frame: CGRect)
    /// Structured reconcile of a native form control (Picker/Menu/DatePicker) on
    /// hosts that back them with real native widgets (Windows). `value` is the
    /// selection index (picker/menu) or ISO date (datepicker); `options` are the
    /// option labels. User edits come back as host-view events. Default: no-op.
    func syncNativeControl(id: String, kind: String, value: String, options: [String], frame: CGRect)
    /// A picture's encoded bytes (PNG, JPEG, …), handed over once under
    /// `source` (an `isomer-image://` URL): the host decodes them off the main
    /// thread and draws them wherever an image names that source. Default:
    /// no-op (the host cannot show them).
    func registerImage(_ source: String, bytes: [UInt8])
    func endHostViewSync()

    func endFrame()

    /// Begin/end a native text-input session over `rect` (DOM input on web,
    /// EditText + IME on Android). The host reports edits back as text
    /// events.
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double)
    func endTextInput()

    /// Rasterize content for the SwiftGPU renderer: `spec` is a JSON object
    /// ({kind: "text"|"gradient"|"shadow"|"image", …}); the host returns
    /// [width u32 LE][height u32 LE][PREMULTIPLIED RGBA8…] (SwiftGPU's
    /// textured pipeline blends premultiplied), or empty when unavailable
    /// (e.g. an image still loading). Default: empty.
    func rasterize(_ spec: String) -> [UInt8]

    /// Draw a host view's content inline, right at its z-position in the
    /// display list (the SwiftGPU renderer draws SwiftMap tile scenes for
    /// kind "map" this way). Return false — the default — to draw the
    /// placeholder and reconcile the view through the native host-view sync
    /// instead.
    func drawHostView(
        id: String, kind: String, value: String, params: [String: String], in rect: CGRect
    ) -> Bool

    /// Ask the host to schedule a render pass (e.g. requestAnimationFrame).
    func scheduleRender()
    /// Monotonic time in seconds, for animations.
    func now() -> Double
    /// Seconds since 1970; hosts whose `now()` is monotonic override this
    /// with their wall clock.
    func wallClock() -> Double
    /// Notify the host of the effective color scheme (for native chrome and the
    /// document's `color-scheme`).
    func setColorScheme(dark: Bool)
    func log(_ message: String)
    /// Open a URL outside the app (browser tab, external player). Used by the
    /// drawn placeholders for embedded surfaces under self-drawing renderers.
    func openURL(_ url: String)
    /// Generic platform-configuration channel: the runtime sends `key`/`value`
    /// pairs (window title, status-bar style, keep-screen-on, …) and the host
    /// applies the ones it understands. Keeps platform-specific SwiftUI
    /// modifiers from each needing their own FFI surface. Default: no-op.
    func platformCommand(_ key: String, _ value: String)
    /// A value the host holds, read synchronously ("pasteboard": the system
    /// clipboard's text); nil where it has none or can't say. Default: nil.
    func hostValue(_ key: String) -> String?
}

extension HostBridge {
    public func registerImage(_ source: String, bytes: [UInt8]) {}
    public func hostValue(_ key: String) -> String? { nil }
    // The drawing half. Only a self-drawing renderer (Isomer's
    // `SwiftGPURenderer`) implements these, over swift_gpu. The service
    // bridges (Windows, Linux, wasm, Android) are wrapped by it for their
    // services alone and never receive a draw call, so they inherit these
    // no-ops instead of carrying dead stubs.
    public func beginFrame(width: Double, height: Double) {}
    public func endFrame() {}
    public func fillRect(_ rect: CGRect, cornerRadius: Double, color: HostColor) {}
    public func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: HostColor) {}
    public func fillGradient(_ rect: CGRect, cornerRadius: Double, gradientJSON: String) {}
    public func drawShadow(
        _ rect: CGRect, cornerRadius: Double, color: HostColor, radius: Double, x: Double, y: Double
    ) {}
    public func drawText(
        _ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: HostColor
    ) {}
    public func drawImage(
        _ source: String, isRemote: Bool, in dest: CGRect, clip: CGRect,
        cornerRadius: Double, opacity: Double
    ) {}
    public func pushClip(_ rect: CGRect, cornerRadius: Double) {}
    public func popClip() {}

    public func rasterize(_ spec: String) -> [UInt8] { [] }
    public func drawHostView(
        id: String, kind: String, value: String, params: [String: String], in rect: CGRect
    ) -> Bool { false }
    public func now() -> Double { 0 }
    /// By default the frame clock is already wall time (epoch seconds).
    public func wallClock() -> Double { now() }
    public func setColorScheme(dark: Bool) {}
    public func beginHostViewSync() {}
    public func syncWebView(id: String, url: String, frame: CGRect) {}
    public func syncNativeControl(id: String, kind: String, value: String, options: [String], frame: CGRect) {}
    public func endHostViewSync() {}
    public func pushTransform(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ e: Double, _ f: Double) {}
    public func popTransform() {}
    public func openURL(_ url: String) {}
    public func platformCommand(_ key: String, _ value: String) {}
}
