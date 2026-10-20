// A feature compiled into this app against Isomer's frameworks
// (apple/compiled), run behind the wasm engine seam: `WasmFeatureRuntime`,
// and so `WasmView`, drive it exactly as they drive a reactor (frames,
// events, resizing, the colour scheme, the renderers). The feature's
// HotBridge defines the reactor's exports as C functions (iso_hot_exports.h)
// and takes the reactor's imports as the callbacks this engine hands over
// (iso_hot_native.h). What a reactor keeps in its linear memory (an event's
// id and value, staged by `iso_hot_alloc`), this engine keeps in buffers of
// its own, named by the handles it returns.

import Foundation
import IsoHotExports
import IsomerWasmRuntime
import SwiftFFIWasmHost

/// What `WasmView` loads for a compiled feature: a bundle with no reactor in
/// it (the feature is linked into the app), for `NativeFeatureRuntime`.
public struct CompiledFeatureProvider: WasmBundleProvider {
    public init() {}

    public func initialBundle() -> WasmBundle? {
        WasmBundle(label: "compiled", wasm: Array("isomer-compiled-feature".utf8))
    }
}

public enum NativeFeatureError: Error, CustomStringConvertible {
    case noExport(String)

    public var description: String {
        switch self {
        case .noExport(let name): return "the compiled feature has no export \(name)"
        }
    }
}

@MainActor
public final class NativeFeatureRuntime: WasmRuntime {
    private var imports: WasmHostImports?
    private var host = IsoHotHost()
    private var buffers: [UInt32: [UInt8]] = [:]
    private var nextHandle: UInt32 = 1

    public init() {}

    /// Registers this engine for every feature the app loads (a compiled
    /// feature is the only one an app links).
    public static func register() {
        WasmRuntimeRegistry.register { NativeFeatureRuntime() }
    }

    public func launch(wasm: [UInt8], hostImports: WasmHostImports) throws {
        imports = hostImports
        host.ctx = Unmanaged.passUnretained(self).toOpaque()
        host.render_tree = { ctx, bytes, length in
            let tree = Array(UnsafeBufferPointer(start: bytes, count: Int(length)))
            NativeFeatureRuntime.engine(ctx) { $0.imports?.onRenderTree(tree) }
        }
        host.log = { ctx, bytes, length in
            let message = String(decoding: UnsafeBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
            NativeFeatureRuntime.engine(ctx) { $0.imports?.onLog(message) }
        }
        host.epoch_millis = { _ in Date().timeIntervalSince1970 * 1000 }
        host.schedule_render = { ctx in
            NativeFeatureRuntime.engine(ctx) { $0.imports?.onScheduleRender() }
        }
        host.platform_command = { ctx, key, keyLength, value, valueLength in
            let key = String(decoding: UnsafeBufferPointer(start: key, count: Int(keyLength)), as: UTF8.self)
            let value = String(decoding: UnsafeBufferPointer(start: value, count: Int(valueLength)), as: UTF8.self)
            NativeFeatureRuntime.engine(ctx) { $0.imports?.onPlatformCommand(key, value) }
        }
        host.host_value = { ctx, key, keyLength, out, capacity in
            let key = String(decoding: UnsafeBufferPointer(start: key, count: Int(keyLength)), as: UTF8.self)
            var answer: String?
            NativeFeatureRuntime.engine(ctx) { answer = $0.imports?.hostValue(key) }
            guard let answer else { return -1 }
            let bytes = Array(answer.utf8)
            if let out, bytes.count <= Int(capacity) {
                bytes.withUnsafeBufferPointer { out.update(from: $0.baseAddress!, count: bytes.count) }
            }
            return Int32(bytes.count)
        }
        withUnsafePointer(to: &host) { iso_hot_set_host($0) }
    }

    /// The engine a callback's context names, as the main actor: the feature
    /// calls back on the thread its main actor runs on, the host's main
    /// thread.
    private nonisolated static func engine(_ ctx: UnsafeMutableRawPointer?, _ body: @MainActor (NativeFeatureRuntime) -> Void) {
        guard let ctx else { return }
        MainActor.assumeIsolated {
            body(Unmanaged<NativeFeatureRuntime>.fromOpaque(ctx).takeUnretainedValue())
        }
    }

    /// No swift_ffi transport natively: a compiled feature reaches its
    /// services directly.
    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {}

    @discardableResult
    public func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar? {
        func f64(_ index: Int) -> Double { index < args.count ? args[index].f64Value : 0 }
        func i32(_ index: Int) -> Int32 { index < args.count ? args[index].i32Value : 0 }
        switch name {
        case "iso_hot_start": iso_hot_start(f64(0), f64(1))
        case "iso_hot_render": iso_hot_render()
        case "iso_hot_render_pending": iso_hot_render_pending()
        case "iso_hot_shutdown": iso_hot_shutdown()
        case "iso_hot_pending_tasks": return .i32(iso_hot_pending_tasks())
        case "iso_hot_resize": iso_hot_resize(f64(0), f64(1))
        case "iso_hot_set_color_scheme": iso_hot_set_color_scheme(i32(0))
        case "iso_hot_set_scene_phase": iso_hot_set_scene_phase(i32(0))
        case "iso_hot_set_size_classes": iso_hot_set_size_classes(i32(0), i32(1))
        case "iso_hot_alloc":
            let handle = nextHandle
            nextHandle &+= 1
            buffers[handle] = [UInt8](repeating: 0, count: Int(max(i32(0), 0)))
            return .i32(Int32(bitPattern: handle))
        case "iso_hot_free":
            buffers[UInt32(bitPattern: i32(0))] = nil
        case "iso_hot_configure", "iso_hot_event":
            let first = buffers[UInt32(bitPattern: i32(0))] ?? []
            let second = buffers[UInt32(bitPattern: i32(2))] ?? []
            first.withUnsafeBufferPointer { a in
                second.withUnsafeBufferPointer { b in
                    if name == "iso_hot_event" {
                        iso_hot_event(a.baseAddress, Int32(a.count), b.baseAddress, Int32(b.count))
                    } else {
                        iso_hot_configure(a.baseAddress, Int32(a.count), b.baseAddress, Int32(b.count))
                    }
                }
            }
        default:
            throw NativeFeatureError.noExport(name)
        }
        return nil
    }

    public func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8] {
        Array((buffers[ptr] ?? []).prefix(Int(len)))
    }

    public func writeBytes(_ ptr: UInt32, _ bytes: [UInt8]) {
        guard var buffer = buffers[ptr] else { return }
        let count = min(buffer.count, bytes.count)
        buffer.replaceSubrange(0..<count, with: bytes[0..<count])
        buffers[ptr] = buffer
    }

    public func renderPending() { iso_hot_render_pending() }
}
