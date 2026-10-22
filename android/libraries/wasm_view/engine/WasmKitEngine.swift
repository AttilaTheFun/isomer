// Android's wasm engine: WasmKit, the Swift interpreter, under the
// platform-free core every native host drives (`WasmFeatureRuntime` over
// `WasmKitRuntime`, //shared/wasm_host). It is compiled into the app's own
// Swift library (one Swift runtime and one libdispatch a process), and its
// Kotlin face is the app's generated bridge: Kotlin's `WasmKitRuntime`
// (kotlin/.../WasmKitRuntime.kt) calls these functions, and implements
// `WasmKitHost` for the reactor's calls back (its frames, logs, and the app's
// dependency dispatch). Everything runs on the main thread: Kotlin calls in
// there, and the guest's jobs are posted to libdispatch's main queue, which
// the main looper drains (NativeBridge.watchMainQueue).

import Foundation
import IsomerFFI
import IsomerWasmHost
import IsomerWasmKitRuntime
import SwiftFFIWasmHost

/// What the running reactor calls back into: the Kotlin host.
@ExportedInterface(namespace: "wasm_engine")
public protocol WasmKitHost {
    /// A fresh serialized render tree (a tree.fbs patch).
    func renderTree(tree: [UInt8])
    /// "Render again soon": the host calls `wasmKitRender` at its next frame.
    func scheduleRender()
    /// Guest log output.
    func log(message: String)
    /// One method call on the app's dependency at `index` (the order they
    /// were added): the argument blob in, the result blob out (empty for Void).
    func dispatchDependency(index: Int32, args: [UInt8]) -> [UInt8]
}

/// One reactor's host, by handle: the app's dependencies, then the running
/// core once launched.
@MainActor
private final class WasmKitEngine {
    let host: any WasmKitHost
    var dependencies: [String: SwiftFFIDependency] = [:]
    var running: WasmFeatureRuntime?

    init(host: any WasmKitHost) { self.host = host }

    static var engines: [Int: WasmKitEngine] = [:]
    static var nextHandle = 1
}

/// A reactor host for `host`; launch it with `wasmKitLaunch`. Returns its handle.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitCreate(host: any WasmKitHost) -> Int {
    MainActor.assumeIsolated {
        let handle = WasmKitEngine.nextHandle
        WasmKitEngine.nextHandle += 1
        WasmKitEngine.engines[handle] = WasmKitEngine(host: host)
        return handle
    }
}

/// One of the app's swift_ffi dependencies, before launch: installed under
/// `key` in the guest's dictionary, as the interface `registryKey` names
/// (what the guest's proxy factory is filed under: `swift_ffi_isomer_HTTPHost`);
/// its calls go to the host's `dispatchDependency(index:args:)`.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitAddDependency(
    handle: Int, index: Int32, key: String, registryKey: String, registerSymbol: String, lazy: Bool
) {
    MainActor.assumeIsolated {
        guard let engine = WasmKitEngine.engines[handle] else { return }
        let host = engine.host
        engine.dependencies[key] = SwiftFFIDependency(key: registryKey, registerSymbol: registerSymbol, lazy: lazy) { args in
            host.dispatchDependency(index: index, args: args)
        }
    }
}

/// Instantiates `wasm` and starts it at `width` × `height` points: "" when it
/// runs, else why it does not. `homeDirectory` (may be empty) is the guest's
/// /home/app; `bundleIdentifier` its `Bundle.main.bundleIdentifier`.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitLaunch(
    handle: Int, wasm: [UInt8], ffiPrefix: String, homeDirectory: String, bundleIdentifier: String,
    width: Double, height: Double, dark: Bool
) -> String {
    MainActor.assumeIsolated {
        guard let engine = WasmKitEngine.engines[handle] else { return "no engine \(handle)" }
        let core = WasmFeatureRuntime(runtime: { _ in
            let runtime = WasmKitRuntime()
            if !homeDirectory.isEmpty {
                try? FileManager.default.createDirectory(atPath: homeDirectory, withIntermediateDirectories: true)
                runtime.homeDirectory = homeDirectory
            }
            if !bundleIdentifier.isEmpty { runtime.bundleIdentifier = bundleIdentifier }
            return runtime
        }, log: { [host = engine.host] line in host.log(message: line) })
        core.onTree = { [host = engine.host] bytes in host.renderTree(tree: bytes) }
        core.onScheduleRender = { [host = engine.host] in host.scheduleRender() }
        core.ffiModulePrefix = ffiPrefix.isEmpty ? nil : ffiPrefix
        core.dependencies = engine.dependencies
        core.setColorScheme(dark: dark)
        core.resize(width: width, height: height)
        core.load(bundle: WasmServiceBundle(label: "reactor", wasm: wasm))
        guard core.engineRuntime != nil else { return core.status }
        engine.running = core
        return ""
    }
}

/// A frame now, if the guest has one to build (the host's scheduled render).
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitRender(handle: Int) {
    MainActor.assumeIsolated { WasmKitEngine.engines[handle]?.running?.pumpRender() }
}

@ExportedFunction(namespace: "wasm_engine")
public func wasmKitResize(handle: Int, width: Double, height: Double) {
    MainActor.assumeIsolated { WasmKitEngine.engines[handle]?.running?.resize(width: width, height: height) }
}

@ExportedFunction(namespace: "wasm_engine")
public func wasmKitSetColorScheme(handle: Int, dark: Bool) {
    MainActor.assumeIsolated { WasmKitEngine.engines[handle]?.running?.setColorScheme(dark: dark) }
}

/// A node's event (a tap, an edit) by id.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitEvent(handle: Int, id: String, value: String) {
    MainActor.assumeIsolated { WasmKitEngine.engines[handle]?.running?.send(id: id, value: value) }
}

/// The app's export `name` called with `scalars` (little-endian Int32s) and,
/// when `payload` is not empty, the payload staged in the guest's memory as a
/// trailing (pointer, length): how an async dependency answers
/// (`swift_ffi_async_resume`). Then a frame.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitCall(handle: Int, name: String, scalars: [UInt8], payload: [UInt8]) {
    MainActor.assumeIsolated {
        guard let core = WasmKitEngine.engines[handle]?.running, let runtime = core.engineRuntime else { return }
        var arguments: [WasmScalar] = []
        var offset = 0
        while offset + 4 <= scalars.count {
            var word: UInt32 = 0
            for byte in 0..<4 { word |= UInt32(scalars[offset + byte]) << UInt32(8 * byte) }
            arguments.append(.i32(Int32(bitPattern: word)))
            offset += 4
        }
        do {
            if !payload.isEmpty {
                let pointer = try runtime.call("swift_ffi_alloc", [.i32(Int32(payload.count))])?.u32Value ?? 0
                runtime.writeBytes(pointer, payload)
                arguments += [.i32(Int32(bitPattern: pointer)), .i32(Int32(payload.count))]
            } else {
                arguments += [.i32(0), .i32(0)]
            }
            try runtime.call(name, arguments)
        } catch {
            WasmKitEngine.engines[handle]?.host.log(message: "[wasmkit] \(name): \(error)")
        }
        runtime.pumpGuestJobs()
        core.render()
    }
}

/// Tears the reactor down; the handle is gone.
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitDestroy(handle: Int) {
    MainActor.assumeIsolated {
        WasmKitEngine.engines[handle]?.running?.forceShutdown()
        WasmKitEngine.engines[handle] = nil
    }
}

// MARK: - Dispatch's main queue

// WasmKit posts the guest's jobs to `DispatchQueue.main` (the Swift SDK's
// own libdispatch, linked into this library). Nothing in an Android process
// drains it, so the Kotlin side watches its wake handle (an eventfd) on the
// main looper and drains it when it fires, as CoreFoundation's run loop does
// on Linux.
#if hasFeature(Extern)
@_extern(c, "_dispatch_get_main_queue_handle_4CF")
private func _dispatchMainQueueHandle() -> Int32
@_extern(c, "_dispatch_main_queue_callback_4CF")
private func _dispatchMainQueueCallback(_ message: UnsafeMutableRawPointer?)
#endif

/// The main queue's wake handle, readable while work is queued (-1: none).
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitMainQueueHandle() -> Int32 {
    #if hasFeature(Extern)
    return _dispatchMainQueueHandle()
    #else
    return -1
    #endif
}

/// Runs the work queued on the main queue (on the main thread).
@ExportedFunction(namespace: "wasm_engine")
public func wasmKitDrainMainQueue() {
    #if hasFeature(Extern)
    _dispatchMainQueueCallback(nil)
    #endif
}
