// The Windows **wasm delivery cell**: the same shell as `WindowsApp` (Win32
// window + D3D11 SwiftGPU renderer + message loop), but the UI runs as an
// `example_full.wasm` reactor under the WAMR interpreter (the C
// `//shared/wamr_host:iso_wamr` host) rather than compiled in. The reactor
// ships a `tree.fbs` Patch per frame — the only wire format — applied to the
// retained decoded tree (`FlatTreeDecoder.applyPatch`; the first patch
// carries the full tree), and
// the result draws through the same `SwiftGPURenderer` the compiled cell uses.
// Input hit-tests the decoded tree; a tap echoes the node id back into the
// reactor via `iso_wamr_event`. The D3D11 peer of `LinuxWasmHost.swift`;
// compiled only into the `swift_ui_wasm` module so the compiled Windows app
// never links the WAMR interpreter.

import CIsoWamr

#if canImport(SwiftGPU)
import SwiftGPU
#endif

/// Process-global state for the one running wasm cell, reachable from the C
/// callbacks (which only receive an opaque `ctx`).
final class WindowsWasmCell {
    nonisolated(unsafe) static var shared: WindowsWasmCell?

    var wamr: OpaquePointer?
    let decoder: FlatTreeDecoder
    var latestTree: RenderNode?
    /// Frames not yet applied, in arrival order. A QUEUE, not a latest-wins
    /// slot: with diff-aware updates each buffer is a delta against the
    /// reactor's previous frame, so dropping an intermediate one (e.g. the
    /// press-highlight patch when down+up land in one pump) desyncs the
    /// retained tree and every later splice corrupts it.
    var pendingBytes: [[UInt8]] = []

    init() {
        decoder = FlatTreeDecoder(send: { id, value in
            WindowsWasmCell.shared?.sendEvent(id: id, value: value)
        })
    }

    func sendEvent(id: String, value: String) {
        guard let wamr else { return }
        withUTF8Pointer(id) { idPtr, idLen in
            withUTF8Pointer(value) { valPtr, valLen in
                iso_wamr_event(wamr, idPtr, Int(idLen), valPtr, Int(valLen))
            }
        }
    }
}

// MARK: - C callbacks (top-level → `@convention(c)` pointers)

private func windowsWasmOnTree(_ ctx: UnsafeMutableRawPointer?, _ bytes: UnsafePointer<UInt8>?, _ len: Int) {
    guard let bytes, len > 0 else { return }
    WindowsWasmCell.shared?.pendingBytes.append(Array(UnsafeBufferPointer(start: bytes, count: len)))
}

private func windowsWasmOnLog(_ ctx: UnsafeMutableRawPointer?, _ msg: UnsafePointer<CChar>?, _ len: Int) {
    if let msg, len > 0 { iso_bridge_log(msg, Int32(len)) }
}

private func windowsWasmScheduleRender(_ ctx: UnsafeMutableRawPointer?) {}

/// The reactor queued Swift concurrency jobs (a `Task {}`, or a resumed
/// continuation): drain on the loop thread (`wasmRunJobsIfNeeded`).
private nonisolated(unsafe) var wasmJobsPending = false
private func wasmScheduleJobs(_ ctx: UnsafeMutableRawPointer?) { wasmJobsPending = true }

/// Runs pending guest jobs on the loop thread (renders when any ran).
private func wasmRunJobsIfNeeded() {
    guard wasmJobsPending, let wamr = WindowsWasmCell.shared?.wamr else { return }
    wasmJobsPending = false
    _ = iso_wamr_run_jobs(wamr)
}

// ---- shared/platform_services on the generic C host ---------------------
//
// The keychain, analytics and configuration services as blob dispatchers
// (docs/abi.md: little-endian; every value is an 8-byte (tag, aux) header +
// payload — ints as i64, strings / bytes as i64 length + bytes). The
// keychain's async methods decode the leading call id and answer in the
// dispatch itself. Networking and files are Foundation's (URLSession,
// FileManager), not services; this host gives a guest's URLSession no
// transport yet (IsomerNetworkHost's HTTPHost and WebSocketHost would).

private struct BlobReader {
    let base: UnsafePointer<UInt8>
    let len: Int
    var offset = 0
    init(_ base: UnsafePointer<UInt8>, _ len: Int) { self.base = base; self.len = len }
    mutating func i64() -> Int64 {
        guard offset + 8 <= len else { return 0 }
        var value: Int64 = 0
        withUnsafeMutableBytes(of: &value) { $0.copyMemory(from: UnsafeRawBufferPointer(start: base + offset, count: 8)) }
        offset += 8
        return Int64(littleEndian: value)
    }
    mutating func header() { offset += 8 }
    mutating func int32() -> Int32 { header(); return Int32(truncatingIfNeeded: i64()) }
    mutating func bytes() -> [UInt8] {
        header()
        let n = Int(i64())
        guard n >= 0, offset + n <= len else { return [] }
        let out = Array(UnsafeBufferPointer(start: base + offset, count: n))
        offset += n
        return out
    }
    mutating func string() -> String { String(decoding: bytes(), as: UTF8.self) }
}

private func blobBool(_ w: UnsafeMutablePointer<SwiftFFIBlobWriter>?, _ v: Bool) { swift_ffi_blob_w_bool(w, v ? 1 : 0) }
private func blobBytes(_ w: UnsafeMutablePointer<SwiftFFIBlobWriter>?, _ v: [UInt8]) {
    swift_ffi_blob_w_header(w, 6, 0)
    swift_ffi_blob_w_i64(w, Int64(v.count))
    v.withUnsafeBufferPointer { if let base = $0.baseAddress { swift_ffi_blob_w_raw(w, base, v.count) } }
}
private func blobError(_ w: UnsafeMutablePointer<SwiftFFIBlobWriter>?, _ message: String) {
    message.withCString { swift_ffi_blob_w_error(w, $0) }
}

/// Where the keychain's fallback keeps its files.
private let wasmSandboxRoot: String = {
    let base = ProcessInfo.processInfo.environment["HOME"] ?? "."
    let root = base + "/.isomer/sandbox/example_wasm"
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    return root
}()

private func wasmKeychainDispatch(
    _ ctx: UnsafeMutableRawPointer?, _ args: UnsafePointer<UInt8>?, _ len: Int,
    _ out: UnsafeMutablePointer<SwiftFFIBlobWriter>?
) {
    guard let args else { return }
    var r = BlobReader(args, len)
    let fm = FileManager.default
    let store = wasmSandboxRoot + "/.keychain"
    try? fm.createDirectory(atPath: store, withIntermediateDirectories: true)
    switch r.int32() {
    case 0:
        let callId = r.int32(); let key = r.string()
        let file = store + "/" + key.replacingOccurrences(of: "/", with: "_")
        // Synchronous answer: the result blob in the dispatch itself.
        if let data = fm.contents(atPath: file) { blobBytes(out, [UInt8](data)) } else { blobError(out, "no keychain value for " + key) }
        _ = callId
    case 1:
        let callId = r.int32(); let value = r.bytes(); let key = r.string()
        let file = store + "/" + key.replacingOccurrences(of: "/", with: "_")
        if fm.createFile(atPath: file, contents: Data(value)) { swift_ffi_blob_w_int32v(out, 1) } else { blobError(out, "keychain write failed") }
        _ = callId
    case 2:
        let callId = r.int32(); let key = r.string()
        try? fm.removeItem(atPath: store + "/" + key.replacingOccurrences(of: "/", with: "_"))
        swift_ffi_blob_w_int32v(out, 1)
        _ = callId
    default:
        blobError(out, "unknown KeychainService method")
    }
}

private func wasmAnalyticsDispatch(
    _ ctx: UnsafeMutableRawPointer?, _ args: UnsafePointer<UInt8>?, _ len: Int,
    _ out: UnsafeMutablePointer<SwiftFFIBlobWriter>?
) {
    guard let args else { return }
    var r = BlobReader(args, len)
    if r.int32() == 0 { let event = r.string(); iso_bridge_log("[analytics] " + event, Int32(event.utf8.count + 12)) }
    swift_ffi_blob_w_void(out)
}

private func wasmConfigurationDispatch(
    _ ctx: UnsafeMutableRawPointer?, _ args: UnsafePointer<UInt8>?, _ len: Int,
    _ out: UnsafeMutablePointer<SwiftFFIBlobWriter>?
) {
    guard let args else { return }
    var r = BlobReader(args, len)
    if r.int32() == 0 { blobBool(out, r.string() == "promo_banner") } else { blobError(out, "unknown ConfigurationService method") }
}

// Stable C lifetimes for the dependency table (leak-once, process lifetime).
private let wasmFfiPrefix = strdup("swift_ffi_platform_services_")  // enables the transport (v3 import names are fixed)
private let wasmDependencyKeys: [(key: UnsafeMutablePointer<CChar>, registry: UnsafeMutablePointer<CChar>, register: UnsafeMutablePointer<CChar>, dispatch: SwiftFFIHostDispatch)] = [
    (strdup("keychain"), strdup("swift_ffi_platform_services_KeychainService"), strdup("swift_ffi_platform_services_register_KeychainService"), wasmKeychainDispatch),
    (strdup("analytics"), strdup("swift_ffi_platform_services_AnalyticsService"), strdup("swift_ffi_platform_services_register_AnalyticsService"), wasmAnalyticsDispatch),
    (strdup("configuration"), strdup("swift_ffi_platform_services_ConfigurationService"), strdup("swift_ffi_platform_services_register_ConfigurationService"), wasmConfigurationDispatch),
]

/// Registers the platform services on a freshly created reactor.
private func wasmRegisterDependencies(_ wamr: OpaquePointer) {
    guard let host = iso_wamr_ffi_host(wamr) else { return }
    var deps: [SwiftFFIHostDependency] = wasmDependencyKeys.map { entry in
        var dep = SwiftFFIHostDependency()
        dep.key = UnsafePointer(entry.key)
        dep.registry_key = UnsafePointer(entry.registry)
        dep.register_symbol = UnsafePointer(entry.register)
        dep.lazy = 1
        dep.ctx = nil
        dep.dispatch = entry.dispatch
        return dep
    }
    deps.withUnsafeMutableBufferPointer { swift_ffi_host_set_dependencies(host, $0.baseAddress, $0.count) }
}

/// Keeps the window painting during an interactive resize (the modal move/size
/// loop blocks the normal loop) — redraws the latest decoded tree.
func windowsWasmPaint() {
    guard let tree = WindowsWasmCell.shared?.latestTree else { return }
    MainActor.assumeIsolated {
        guard Runtime.shared.host != nil else { return }
        Renderer.current.render(tree: tree)
    }
}

/// Resize: refresh the D3D swapchain + host layout size, then tell the reactor
/// so its size-dependent build (split vs. tab shell) re-runs.
func windowsWasmResized(width: Double, height: Double) {
    #if canImport(SwiftGPU)
    windowsGPUSurface?.refreshSize()
    #endif
    // The host loop runs on the main thread, where views live: say so to
    // the runtime, which is main-actor isolated as SwiftUI is.
    MainActor.assumeIsolated { Runtime.shared.resize(width: width, height: height) }
    if let rt = WindowsWasmCell.shared?.wamr { iso_wamr_resize(rt, width, height) }
}

// MARK: - Entry

/// The loop WindowsWasmApp (IsomerWasmHost, the public entry: this module is
/// `SwiftUI`, which has nothing of Isomer's own) runs. Owns the native window
/// and the render loop for the Windows wasm cell.
///
/// `nextReload`, when supplied (hot-reload via `ISO_HOT_RELOAD_SERVER`), is
/// polled ~2×/sec and returns fresh reactor bytes on a server build bump; the
/// host then tears the reactor down and swaps in a new one live.
package enum WindowsWasmLoop {
    package static func run(wasmBytes: [UInt8], nextReload: (() -> [UInt8]?)? = nil) {
        iso_set_pointer_callback { kind, x, y in
            Runtime.shared.pointerEvent(kind: Int(kind), x: x, y: y)
        }
        iso_set_wheel_callback { x, y, dx, dy in
            Runtime.shared.wheelEvent(x: x, y: y, deltaX: dx, deltaY: dy)
        }
        iso_set_resize_callback { width, height in
            windowsWasmResized(width: width, height: height)
        }
        iso_set_paint_callback(windowsWasmPaint)
        "Isomer (wasm)".withCString { iso_window_create(1100, 720, $0) }

        var width: Double = 0
        var height: Double = 0
        iso_window_size(&width, &height)

        let cell = WindowsWasmCell()
        WindowsWasmCell.shared = cell

        // Bind the self-drawing SwiftGPU/D3D11 host; no native app is installed,
        // so `start`'s `renderFrame` is a clean no-op.
        MainActor.assumeIsolated { Runtime.shared.start(host: windowsMakeHost(), width: width, height: height) }
        let callbacks = IsoWamrCallbacks(
            ctx: nil,
            on_tree: windowsWasmOnTree,
            on_log: windowsWasmOnLog,
            on_schedule_render: windowsWasmScheduleRender,
            ffi_prefix: wasmFfiPrefix,
            on_schedule_jobs: wasmScheduleJobs,
            // GPU-reactor services (Android's self-drawing wasm cells); this
            // host renders trees natively, so they never fire.
            measure_text: nil,
            rasterize: nil,
            // No platform channel or app home yet: commands are dropped,
            // values are "none", and the guest's app directories are not
            // writable (shared/wamr_host/iso_wamr.h).
            on_platform_command: nil,
            host_value: nil,
            home_dir: nil,
            bundle_identifier: nil)

        func makeReactor(_ bytes: [UInt8]) -> OpaquePointer? {
            var err = [CChar](repeating: 0, count: 256)
            let reactor: OpaquePointer? = bytes.withUnsafeBufferPointer { buffer in
                err.withUnsafeMutableBufferPointer { errBuffer in
                    iso_wamr_create(
                        buffer.baseAddress, buffer.count, callbacks,
                        errBuffer.baseAddress, errBuffer.count)
                }
            }
            if reactor == nil {
                let message = err.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                withUTF8Pointer("iso_wamr_create failed: " + message) { ptr, len in
                    iso_bridge_log(ptr, len)
                }
            }
            if let reactor { wasmRegisterDependencies(reactor) }
            return reactor
        }

        guard let reactor = makeReactor(wasmBytes) else { return }
        cell.wamr = reactor
        iso_wamr_start(reactor, width, height)

        var presentPaces = false
        #if canImport(SwiftGPU)
        presentPaces = windowsGPUSurface != nil
        #endif
        var lastPollMs = iso_bridge_epoch_millis()

        while iso_pump_events() != 0 {
            iso_drain_fetches()
            iso_drain_images()
            wasmRunJobsIfNeeded()

            // Hot reload: destroy-before-create swap (see LinuxWasmLoop for why —
            // the swift_ffi natives are globally bound to the first
            // reactor's storage).
            if let nextReload {
                let now = iso_bridge_epoch_millis()
                if now - lastPollMs > 500 {
                    lastPollMs = now
                    if let fresh = nextReload() {
                        if let old = cell.wamr { iso_wamr_destroy(old); cell.wamr = nil }
                        cell.pendingBytes = []
                        // The fresh reactor's encoder starts empty: drop the
                        // retained tree so its first patch (a full tree at "n")
                        // rebuilds from scratch.
                        cell.latestTree = nil
                        if let replacement = makeReactor(fresh) {
                            cell.wamr = replacement
                            iso_wamr_start(replacement, Runtime.shared.width, Runtime.shared.height)
                        }
                    }
                }
            }

            if !cell.pendingBytes.isEmpty {
                let queued = cell.pendingBytes
                cell.pendingBytes = []
                for bytes in queued {
                    cell.latestTree = cell.decoder.applyPatch(bytes: bytes, to: cell.latestTree)
                }
            }
            DesktopBench.shared?.tick()
            if let tree = cell.latestTree {
                MainActor.assumeIsolated { Renderer.current.render(tree: tree) }
                DesktopBench.shared?.framePresented()
            }
            if !presentPaces { iso_frame_wait() }
        }

        if let reactor = cell.wamr { iso_wamr_destroy(reactor) }
    }
}
