// Drives Isomer's WasmKitRuntime itself: launch the runtime module, load the
// side modules with loadSideModule, then start, tap every first-frame tap id
// and write the render stream (the same stream drive_all.mjs writes).
import Foundation
import IsomerWasmKitRuntime
import IsomerWasmRuntime

setvbuf(stdout, nil, _IONBF, 0)
let arguments = CommandLine.arguments
let out = arguments[1]
func bytes(_ path: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path))) }

MainActor.assumeIsolated {
    var stream: [UInt8] = []
    let imports = WasmHostImports(
        onRenderTree: { stream += $0 }, onLog: { _ in }, epochMillis: { 1.7e12 }, onScheduleRender: {})
    let runtime = WasmKitRuntime()
    do {
        try runtime.launch(wasm: try bytes(arguments[2]), hostImports: imports)
        let start = Date()
        for path in arguments.dropFirst(3) { try runtime.loadSideModule(wasm: try bytes(path)) }
        print("side modules loaded in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        try runtime.call("iso_hot_start", [.f64(1024), .f64(768)])
        try runtime.call("iso_hot_render", [])
        var ids: [String] = []
        let tap = Array(".tap".utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        for i in 0...max(0, stream.count - 4) where stream.count >= 4 && Array(stream[i..<i + 4]) == tap {
            var s = i
            while s > 0 && ok(stream[s - 1]) { s -= 1 }
            var id = String(decoding: stream[s..<i + 4], as: UTF8.self)
            while id.hasPrefix(".") { id.removeFirst() }
            if !ids.contains(id) { ids.append(id) }
        }
        for id in ids {
            let idBytes = Array(id.utf8)
            guard case .i32(let idPtr)? = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))]),
                  case .i32(let valuePtr)? = try runtime.call("iso_hot_alloc", [.i32(1)]) else { fatalError("alloc") }
            runtime.writeBytes(UInt32(bitPattern: idPtr), idBytes)
            try runtime.call("iso_hot_event", [.i32(idPtr), .i32(Int32(idBytes.count)), .i32(valuePtr), .i32(0)])
            try runtime.call("iso_hot_render", [])
        }
        try Data(stream).write(to: URL(fileURLWithPath: out))
        print("\(ids.count) taps, \(stream.count) bytes of frames")
    } catch {
        print("FAILED: \(error)")
        exit(1)
    }
}
