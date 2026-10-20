// `WasmRuntime` — the pluggable WebAssembly engine seam. It launches ONE wasm
// feature bundle, binds the host imports it needs, and lets the caller drive
// its exports and linear memory. `WasmFeatureRuntime` (the platform-free core)
// talks only to this protocol, so the concrete engine is user-replaceable:
//
//   • `WamrRuntime` (//shared/wasm_host:wamr_runtime) — the built-in engine on
//     every native-Swift host (macOS, iOS, Linux, Windows), backed by the WAMR C
//     interpreter shared with Android.
//   • `WasmKitRuntime` (//shared/wasm_host:wasmkit_runtime) — WasmKit, the
//     Swift interpreter, on Apple hosts; the one that runs threaded reactors.
//   • The web's `NativeWasmRuntime` — the browser's own `WebAssembly` APIs,
//     which the JS runtime already calls directly.
//
// The protocol is deliberately small: "launch a bundle with these host imports,
// then call exports / read+write memory / install the DI proxy." Everything
// engine-specific (the WAMR C host, the swift_ffi transport, WASI) lives inside
// the conforming type, never leaking here. This module carries NO interpreter
// dependency, so the engine and the driver share it without pulling one in.

import Foundation
import SwiftFFIWasmHost

/// A single WebAssembly scalar crossing the engine boundary. Reuses swift_ffi's
/// scalar (the transport all engines already share) under a neutral name.
public typealias WasmScalar = SwiftFFIScalar

/// The host callbacks a launched feature bundle imports through the `iso_hot`
/// render ABI. The engine binds each to its own linear memory; the values here
/// are already materialized (the engine reads `(ptr, len)` out of guest memory
/// before invoking `onRenderTree` / `onLog`), so this surface is engine-neutral.
public struct WasmHostImports {
    /// The reactor pushed a fresh serialized render tree (tree.fbs).
    public var onRenderTree: ([UInt8]) -> Void
    /// Guest `log(...)` output.
    public var onLog: (String) -> Void
    /// Wall-clock milliseconds since the epoch (guest `epoch_millis`).
    public var epochMillis: () -> Double
    /// "Schedule a frame soon" — the guest asked for a render.
    public var onScheduleRender: () -> Void
    /// A platform command (`iso_hot.platform_command`): "copy" (text to the
    /// clipboard), "openURL", "share", … — the host does what it can.
    public var onPlatformCommand: (String, String) -> Void
    /// A value the host holds, read synchronously (`iso_hot.host_value`):
    /// "pasteboard", the clipboard's text; nil for none.
    public var hostValue: (String) -> String?

    public init(
        onRenderTree: @escaping ([UInt8]) -> Void,
        onLog: @escaping (String) -> Void,
        epochMillis: @escaping () -> Double,
        onScheduleRender: @escaping () -> Void,
        onPlatformCommand: @escaping (String, String) -> Void = { _, _ in },
        hostValue: @escaping (String) -> String? = { _ in nil }
    ) {
        self.onRenderTree = onRenderTree
        self.onLog = onLog
        self.epochMillis = epochMillis
        self.onScheduleRender = onScheduleRender
        self.onPlatformCommand = onPlatformCommand
        self.hostValue = hostValue
    }
}

/// A pluggable engine that runs one wasm feature bundle. Drive it from the main
/// actor (a single instance per launched reactor; the call path is not
/// synchronized). Conform a type and hand it to `WasmFeatureRuntime` to swap the
/// engine.
@MainActor
public protocol WasmRuntime: AnyObject {
    /// Launch `wasm`: instantiate it, bind WASI + the swift_ffi dependency
    /// dispatchers + the `iso_hot` render callbacks in `hostImports`, and run the
    /// reactor's `_initialize`. After this, `call`/`readBytes`/`writeBytes`
    /// operate on the live instance.
    func launch(wasm: [UInt8], hostImports: WasmHostImports) throws

    /// Install the app's swift_ffi dependency dictionary: `prefix` is the app
    /// module's C-symbol prefix (e.g. `"swift_ffi_appservices_"`); the entries
    /// are runtime-generic `SwiftFFIDependency` values (built with the app's
    /// generated `Dependencies` builders). Call BEFORE `launch` — engines bind
    /// the DI imports at instantiation. Engines without the swift_ffi
    /// transport ignore it (features see an empty dictionary).
    func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency])

    /// Invoke an export; returns its single result slot (or nil for `Void`).
    @discardableResult
    func call(_ name: String, _ args: [WasmScalar]) throws -> WasmScalar?

    /// Copy `len` bytes out of guest linear memory at `ptr`.
    func readBytes(_ ptr: UInt32, _ len: UInt32) -> [UInt8]
    /// Copy `bytes` into guest linear memory at `ptr`.
    func writeBytes(_ ptr: UInt32, _ bytes: [UInt8])

    /// Run the guest's queued Swift concurrency jobs now (a `Task {}` the
    /// feature started, or a continuation an async service answer resumed).
    /// Engines normally drain on the main queue by themselves; tests and
    /// synchronous drivers call this explicitly.
    func pumpGuestJobs()

    /// A frame only if the guest has one to build (`iso_hot_render_pending`):
    /// the host's scheduled render, which a frame already built since may
    /// have made empty.
    func renderPending()
}

extension WasmRuntime {
    public func pumpGuestJobs() {}
    public func renderPending() { _ = try? call("iso_hot_render", []) }
}

/// The engine registration point: the host app picks the wasm engine once
/// (e.g. at startup), and everything that launches features
/// (`WasmFeatureRuntime`) makes fresh instances through it. Third-party
/// engines plug in by conforming to `WasmRuntime` and registering a factory:
///
///     WasmRuntimeRegistry.register { MyEngineRuntime() }
///
/// `registerDefault` is for host layers that ship a batteries-included
/// engine (isomer's Apple host registers WAMR this way): it only takes
/// effect if the app hasn't registered its own.
@MainActor
public enum WasmRuntimeRegistry {
    private static var factory: (@MainActor () -> any WasmRuntime)?

    /// Registers the engine factory, replacing any previous registration.
    public static func register(_ make: @escaping @MainActor () -> any WasmRuntime) {
        factory = make
    }

    /// Registers `make` only if no engine is registered yet — the hook for a
    /// host layer's built-in default, called after the app had its chance.
    public static func registerDefault(_ make: @escaping @MainActor () -> any WasmRuntime) {
        if factory == nil { factory = make }
    }

    public static var isRegistered: Bool { factory != nil }

    /// Makes a fresh engine instance for one feature launch of `bundle`:
    /// the per-bundle factory `WasmFeatureRuntime` and `WasmViewModel` take
    /// by default. Every bundle goes to the registered engine (WAMR tells
    /// `\0asm` wasm from `\0aot` wamrc output itself); a host that picks an
    /// engine per bundle passes its own factory instead.
    public static func make(for bundle: [UInt8]) -> any WasmRuntime {
        make()
    }

    /// Makes a fresh engine instance for one feature launch.
    public static func make() -> any WasmRuntime {
        guard let factory else {
            preconditionFailure(
                "No WasmRuntime engine registered. Register one before launching a "
                    + "feature, e.g. WasmRuntimeRegistry.register { WamrRuntime() }.")
        }
        return factory()
    }
}

extension WasmRuntime {
    /// Engines without the swift_ffi DI transport run features that simply see
    /// an empty dependency dictionary.
    public func installDependencies(prefix: String, _ dependencies: [String: SwiftFFIDependency]) {}
}
