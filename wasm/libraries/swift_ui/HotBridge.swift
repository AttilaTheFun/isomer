// The framework-owned `iso_hot` reactor bridge: the complete render ABI a
// wasm reactor exports to its native host (WasmKit on Apple, WAMR on
// Android/desktop). Reactors link this as a library
// (`//wasm/libraries/swift_ui:hot_bridge` on the full SwiftUI module,
// `//wasm/libraries/hot_swift_ui:hot_bridge` on the slim one) instead of
// copying the glue into their own sources — a hand-copied bridge can drift
// and silently lose exports (a missing `iso_hot_set_color_scheme` looks
// exactly like "dark mode is broken").
//
// ABI (host <-> wasm), all under the import module "iso_hot":
//   exports (@_cdecl, host calls in):
//     iso_hot_start(w, h)                     run @main once, bind + start
//     iso_hot_render()                        pump one frame
//     iso_hot_resize(w, h)
//     iso_hot_set_color_scheme(dark)          0 = light / 1 = dark
//     iso_hot_set_scene_phase(phase)          0 = active / 1 = inactive / 2 = background
//     iso_hot_set_size_classes(h, v)          each 0 = the size's own / 1 = compact / 2 = regular
//     iso_hot_alloc(len) -> ptr               scratch for marshalling strings
//     iso_hot_free(ptr)
//     iso_hot_event(idPtr,idLen,valPtr,valLen) host-view / tap event by id
//   imports (@_extern(wasm), wasm calls out):
//     iso_hot.render_tree(ptr, len)           push the serialized tree
//     iso_hot.log(ptr, len)
//     iso_hot.epoch_millis() -> f64
//     iso_hot.schedule_render()
//
// The bridge binds `SwiftUIRenderer`: the runtime builds and serializes the
// view tree to the tree.fbs FlatBuffer and hands the bytes to the host,
// which renders them natively (real SwiftUI / Compose) — nothing in the
// wasm draws or measures.

import SwiftUI
import IsomerSwiftUI
#if canImport(IsomerNetworkHost)
import IsomerNetworkHost
#endif
#if !os(WASI)
// Natively: a feature compiled into a host app against Isomer's frameworks
// (apple/compiled), whose imports are the callbacks the host hands over.
import IsoHotNative
#endif

// malloc/free for the scratch allocator (the library also compiles for the
// host configuration when analyzed directly, not just under the wasm
// transition).
#if canImport(WASILibc)
import WASILibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(CRT)
import CRT
#endif

// MARK: - Imports (wasm -> host)

#if os(WASI)
@_extern(wasm, module: "iso_hot", name: "render_tree")
func iso_hot_render_tree(_ ptr: UnsafePointer<UInt8>?, _ len: Int32)

@_extern(wasm, module: "iso_hot", name: "log")
func iso_hot_log(_ ptr: UnsafePointer<UInt8>?, _ len: Int32)

@_extern(wasm, module: "iso_hot", name: "epoch_millis")
func iso_hot_epoch_millis() -> Double

@_extern(wasm, module: "iso_hot", name: "schedule_render")
func iso_hot_schedule_render()

/// A platform command for the host (`platformCommand`: "copy" to the
/// clipboard, "openURL", "share", …): key and value, UTF-8.
@_extern(wasm, module: "iso_hot", name: "platform_command")
func iso_hot_platform_command(_ key: UnsafePointer<UInt8>?, _ keyLen: Int32, _ value: UnsafePointer<UInt8>?, _ valueLen: Int32)

/// A value the host holds, read synchronously (`hostValue`: "pasteboard",
/// the system clipboard's text): written into `out` (up to `capacity`
/// bytes); returns its full length, or -1 when the host has none.
@_extern(wasm, module: "iso_hot", name: "host_value")
func iso_hot_host_value(_ key: UnsafePointer<UInt8>?, _ keyLen: Int32, _ out: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32
#else
// The same imports natively: the host's callbacks (iso_hot_native.h), handed
// over with `iso_hot_set_host` before `iso_hot_start`. Written once, from
// the main thread, before the feature runs.
nonisolated(unsafe) private var nativeHost = IsoHotHost()

@_cdecl("iso_hot_set_host")
public func iso_hot_set_host(_ host: UnsafePointer<IsoHotHost>?) {
    if let host { nativeHost = host.pointee }
}

func iso_hot_render_tree(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) {
    nativeHost.render_tree?(nativeHost.ctx, ptr, len)
}

func iso_hot_log(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) {
    nativeHost.log?(nativeHost.ctx, ptr, len)
}

func iso_hot_epoch_millis() -> Double {
    nativeHost.epoch_millis?(nativeHost.ctx) ?? 0
}

func iso_hot_schedule_render() {
    nativeHost.schedule_render?(nativeHost.ctx)
}

func iso_hot_platform_command(_ key: UnsafePointer<UInt8>?, _ keyLen: Int32, _ value: UnsafePointer<UInt8>?, _ valueLen: Int32) {
    nativeHost.platform_command?(nativeHost.ctx, key, keyLen, value, valueLen)
}

func iso_hot_host_value(_ key: UnsafePointer<UInt8>?, _ keyLen: Int32, _ out: UnsafeMutablePointer<UInt8>?, _ capacity: Int32) -> Int32 {
    nativeHost.host_value?(nativeHost.ctx, key, keyLen, out, capacity) ?? -1
}
#endif

// MARK: - Host bridge (services only; drawing never runs here)

/// The `HostBridge` the runtime is started with. Under a component-system
/// renderer the runtime only builds and serializes the tree — it never enters
/// the draw pass — so every draw/measure hook is a no-op or a rough stub. The
/// real layout happens natively in the host.
struct HotHostBridge: HostBridge {
    // Not consulted under SwiftUIRenderer (the host measures/lays out); a
    // coarse estimate keeps any incidental caller from dividing by zero.
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        CGSize(width: Double(text.count) * fontSize * 0.55, height: fontSize * 1.3)
    }

    // Component-system hosts load images NATIVELY (AsyncImage on Apple, the
    // bitmap cache on Android) from the serialized node — report ready so
    // `AsyncImage` content (and anything gating on load) emits the node
    // instead of holding its placeholder forever.
    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus {
        .ready(CGSize(width: 0, height: 0))
    }

    // Drawing half: dead here (the host renders the serialized tree; it
    // never asks this bridge to draw), so it inherits the core no-op
    // defaults.
    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}

    // A decoded picture's bytes (ImageIO's CGImage, `Image(data:)`): this
    // bridge has no image channel, so they ride the tree to the host once.
    func registerImage(_ source: String, bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        MainActor.assumeIsolated { Runtime.shared.inlineImages[source] = bytes }
    }

    func scheduleRender() { iso_hot_schedule_render() }

    // The platform channel (the clipboard, opening a URL, …) and the values
    // a host holds (the clipboard's text): the host's own.
    func platformCommand(_ key: String, _ value: String) {
        let keyBytes = Array(key.utf8), valueBytes = Array(value.utf8)
        keyBytes.withUnsafeBufferPointer { k in
            valueBytes.withUnsafeBufferPointer { v in
                iso_hot_platform_command(k.baseAddress, Int32(k.count), v.baseAddress, Int32(v.count))
            }
        }
    }

    func openURL(_ url: String) { platformCommand("openURL", url) }

    func hostValue(_ key: String) -> String? {
        let keyBytes = Array(key.utf8)
        var capacity = 4096
        while true {
            var out = [UInt8](repeating: 0, count: capacity)
            let length = keyBytes.withUnsafeBufferPointer { k in
                out.withUnsafeMutableBufferPointer { o in
                    iso_hot_host_value(k.baseAddress, Int32(k.count), o.baseAddress, Int32(o.count))
                }
            }
            if length < 0 { return nil }
            if Int(length) <= capacity { return String(decoding: out[0..<Int(length)], as: UTF8.self) }
            capacity = Int(length)
        }
    }

    func now() -> Double { iso_hot_epoch_millis() / 1000 }

    func log(_ message: String) {
        let bytes = Array(message.utf8)
        bytes.withUnsafeBufferPointer { iso_hot_log($0.baseAddress, Int32($0.count)) }
    }
}

// MARK: - Exports (host -> wasm)

// The app's synthesized @main, run once to install the App into the Runtime
// (the reactor is linked without a command `_start`). On wasm32 the two-arg C
// `main` is mangled to `__main_argc_argv`; natively the app is compiled with
// `-entry-point-function-name iso_feature_main` (apple/compiled), as the
// host app has a `main` of its own.
#if os(WASI)
@_extern(c, "__main_argc_argv")
#else
@_extern(c, "iso_feature_main")
#endif
func _hot_application_main(
    _ argc: Int32,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
) -> Int32

@_cdecl("iso_hot_start")
public func iso_hot_start(_ width: Double, _ height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        #if canImport(IsomerNetworkHost)
        // Foundation's networking over what the host injected (the hot
        // bridge links IsomerNetworkHost on the slim SwiftUI too).
        installInjectedNetworkHosts()
        #endif
        if Runtime.shared.host == nil {
            _ = _hot_application_main(0, nil)
        }
        // SwiftUIRenderer serializes the tree and ships the bytes to the host,
        // which renders them natively. `withUnsafeBufferPointer` is safe: the
        // import copies the bytes out synchronously before returning.
        Renderer.bind(SwiftUIRenderer { bytes in
            bytes.withUnsafeBufferPointer { iso_hot_render_tree($0.baseAddress, Int32($0.count)) }
        })
        Runtime.shared.start(host: HotHostBridge(), width: width, height: height)
    }
}

@_cdecl("iso_hot_render")
public func iso_hot_render() {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        Runtime.shared.renderFrame()
    }
}

/// A frame only if one has anything to do (`Runtime.wantsFrame`): what the
/// host calls after an event or a run of the guest's async work, which
/// mostly change nothing to draw (a scroll's reports, a timer's wake).
@_cdecl("iso_hot_render_pending")
public func iso_hot_render_pending() {
    MainActor.assumeIsolated {
        if Runtime.shared.wantsFrame { Runtime.shared.renderFrame() }
    }
}

/// Graceful shutdown, step 1: cancel the feature's view tasks and stop
/// rendering. The host then drains jobs while `iso_hot_pending_tasks` > 0
/// (up to its deadline) before tearing the instance down.
@_cdecl("iso_hot_shutdown")
public func iso_hot_shutdown() {
    Runtime.shared.shutdown()
}

/// View tasks still alive after `iso_hot_shutdown` (0 = quiescent).
@_cdecl("iso_hot_pending_tasks")
public func iso_hot_pending_tasks() -> Int32 {
    Int32(clamping: Runtime.shared.pendingTaskCount)
}

@_cdecl("iso_hot_resize")
public func iso_hot_resize(_ width: Double, _ height: Double) {
    // A host entry point: the host calls it on the thread the main
    // executor drains, which is where views live.
    MainActor.assumeIsolated {
        Runtime.shared.resize(width: width, height: height)
    }
}

/// Host configuration channel, callable before `iso_hot_start`. Keys:
/// `navigation` = `drawn` (the host renders with a self-drawing renderer —
/// SwiftGPU — and wants pre-expanded drawn chrome instead of `navstack` /
/// `navsplit` host views) or `semantic` (the default: component-system
/// hosts map navigation to their platform's own containers). Unknown keys
/// are ignored by design, so hosts can declare future capabilities.
@_cdecl("iso_hot_configure")
public func iso_hot_configure(
    _ keyPtr: UnsafePointer<UInt8>?, _ keyLen: Int32,
    _ valPtr: UnsafePointer<UInt8>?, _ valLen: Int32
) {
    let key = _hotString(keyPtr, keyLen)
    let value = _hotString(valPtr, valLen)
    if key == "navigation" {
        Renderer.setHostRendersNavigation(value != "drawn")
    }
}

/// The host's system appearance (0 = light, 1 = dark): maps to the core's
/// scheme so the adaptive semantic palette re-resolves; the host pumps a
/// frame after calling.
@_cdecl("iso_hot_set_color_scheme")
public func iso_hot_set_color_scheme(_ dark: Int32) {
    Runtime.shared.setSystemColorScheme(dark: dark != 0)
}

/// The app's scene phase as its host sees it (0 = active, 1 = inactive,
/// 2 = background): the guest's `@Environment(\.scenePhase)` follows it, so
/// an app's `.onChange(of: scenePhase)` runs as it does under SwiftUI (Visor
/// lets its connections go in the background and checks them on return).
/// The host pumps a frame after calling.
@_cdecl("iso_hot_set_scene_phase")
public func iso_hot_set_scene_phase(_ phase: Int32) {
    Runtime.shared.setScenePhase(phase == 2 ? .background : phase == 1 ? .inactive : .active)
}

/// The host's size classes (horizontal, vertical; 0 = none, worked out
/// from the size; 1 = compact; 2 = regular), as its system's traits say:
/// an iPhone held sideways is compact wide however wide it is. The host
/// pumps a frame after calling.
@_cdecl("iso_hot_set_size_classes")
public func iso_hot_set_size_classes(_ horizontal: Int32, _ vertical: Int32) {
    func sizeClass(_ value: Int32) -> UserInterfaceSizeClass? { value == 1 ? .compact : value == 2 ? .regular : nil }
    Runtime.shared.setHostSizeClasses(horizontal: sizeClass(horizontal), vertical: sizeClass(vertical))
}

@_cdecl("iso_hot_alloc")
public func iso_hot_alloc(_ len: Int32) -> UnsafeMutableRawPointer? {
    malloc(Int(len))
}

@_cdecl("iso_hot_free")
public func iso_hot_free(_ ptr: UnsafeMutableRawPointer?) {
    free(ptr)
}

@_cdecl("iso_hot_event")
public func iso_hot_event(
    _ idPtr: UnsafePointer<UInt8>?, _ idLen: Int32,
    _ valPtr: UnsafePointer<UInt8>?, _ valLen: Int32
) {
    let id = _hotString(idPtr, idLen)
    let value = _hotString(valPtr, valLen)
    // The runtime asks for the render the event needs (none for a list's
    // window or a scroll's geometry: rendering for each of those made a
    // scroll rebuild the app ten times a second).
    Runtime.shared.hostViewEvent(id: id, value: value)
}

private func _hotString(_ ptr: UnsafePointer<UInt8>?, _ len: Int32) -> String {
    guard let ptr, len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: Int(len)), as: UTF8.self)
}
