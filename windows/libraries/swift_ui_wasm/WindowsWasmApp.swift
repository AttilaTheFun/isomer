// The Windows wasm cell's entry, on Isomer's side: a host program's `@main`
// reads the reactor's bytes and calls this. The loop itself is in the
// cell's `SwiftUI` module (WindowsWasmLoop, package), which as an Apple-named
// module has nothing of Isomer's own in its interface.

internal import SwiftUI
import IsomerNativePlatformServices
import SwiftFFIWasmHost

public enum WindowsWasmApp {
    /// Runs `wasmBytes` (an `iso_hot` reactor) on WasmKit in a native window
    /// until it closes, with the platform services `dependencies` (the
    /// Foundation implementations by default, the keychain under
    /// `namespace`). `nextReload`, when given, is polled for newer reactor
    /// bytes (hot reload), which replace the running one live.
    @MainActor
    public static func run(
        wasmBytes: [UInt8], namespace: String = "isomer_wasm",
        dependencies: [String: SwiftFFIDependency]? = nil,
        nextReload: (() -> [UInt8]?)? = nil
    ) {
        WindowsWasmLoop.run(
            wasmBytes: wasmBytes,
            dependencies: dependencies ?? nativePlatformDependencies(namespace: namespace),
            nextReload: nextReload)
    }
}
