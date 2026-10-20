// The Linux wasm cell's entry, on Isomer's side: a host program's `@main`
// reads the reactor's bytes and calls this. The loop itself is in the
// cell's `SwiftUI` module (LinuxWasmLoop, package), which as an Apple-named
// module has nothing of Isomer's own in its interface.

internal import SwiftUI

public enum LinuxWasmApp {
    /// Runs `wasmBytes` (an `iso_hot` reactor) in a native window until it
    /// closes. `nextReload`, when given, is polled for newer reactor bytes
    /// (hot reload), which replace the running one live.
    public static func run(wasmBytes: [UInt8], nextReload: (() -> [UInt8]?)? = nil) {
        LinuxWasmLoop.run(wasmBytes: wasmBytes, nextReload: nextReload)
    }
}
