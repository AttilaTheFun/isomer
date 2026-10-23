// The desktop's WasmKit loader: runs the reactor at the path it is given in a
// window of its own (LinuxWasmApp / WindowsWasmApp: WasmKit, the platform's
// SwiftGPU renderer over the decoded tree). The Isomer app starts it for a
// hot reloader's version and for the Gallery as wasm; the guest sees this
// process's ISO_ variables (the host forwards them).

import Foundation
import IsomerDesktopWasmHost  // LinuxWasmApp / WindowsWasmApp: the reactor on WasmKit in a window

@main
@MainActor
struct IsomerWasmLoader {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
            print("usage: \(arguments.first ?? "isomer_wasm_loader") <reactor.wasm>")
            exit(2)
        }
        #if os(Windows)
        WindowsWasmApp.run(wasmBytes: [UInt8](data), namespace: "isomer_run")
        #else
        LinuxWasmApp.run(wasmBytes: [UInt8](data), namespace: "isomer_run")
        #endif
    }
}
