// The desktop's WasmKit loader: runs the reactor at the path it is given in a
// window of its own (LinuxWasmApp / WindowsWasmApp: WasmKit, the platform's
// SwiftGPU renderer over the decoded tree). The Playground starts it for a
// project's build; the guest sees this process's ISO_ variables.

import Foundation
import IsomerDesktopWasmHost  // LinuxWasmApp / WindowsWasmApp: the reactor on WasmKit in a window

@main
@MainActor
struct PlaygroundWasmLoader {
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2, let data = FileManager.default.contents(atPath: arguments[1]) else {
            print("usage: \(arguments.first ?? "playground_wasm_loader") <reactor.wasm>")
            exit(2)
        }
        #if os(Windows)
        WindowsWasmApp.run(wasmBytes: [UInt8](data), namespace: "playground_run")
        #else
        LinuxWasmApp.run(wasmBytes: [UInt8](data), namespace: "playground_run")
        #endif
    }
}
