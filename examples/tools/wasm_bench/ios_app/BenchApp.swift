// The on-device engine benchmark: the engine conformance suite's protocol
// (launch, first frame, 20 taps), timed, for each engine over the Swift
// engine seam — WasmKit (Isomer's engine) and JSC — then the RESULT lines on
// screen, mirrored to Documents/bench_output.txt + NSLog for retrieval. (A
// WAMR pass, its C console bench compiled in, went with WAMR in 0.38.)

import Foundation
import SwiftUI
import UIKit
import IsomerJSCRuntime
import IsomerWasmKitRuntime
import IsomerWasmRuntime

@main
struct BenchApp: App {
    var body: some Scene {
        WindowGroup {
            BenchView()
        }
    }
}

struct BenchView: View {
    @State private var lines: [String] = []
    @State private var started = false

    var body: some View {
        ScrollView {
            Text(lines.joined(separator: "\n"))
                .font(.system(size: 10, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .onAppear {
            guard !started else { return }
            started = true
            UIApplication.shared.isIdleTimerDisabled = true
            start()
        }
    }

    private func start() {
        let emit: (String) -> Void = { line in
            DispatchQueue.main.async { lines.append(line) }
        }
        // The interpreted reactor's call depth needs a big stack (the console
        // benches run theirs on a 64 MiB pthread; match it here).
        let thread = Thread { runAllBenches(emit: emit) }
        thread.stackSize = 64 << 20
        thread.start()
    }
}

private func runAllBenches(emit: @escaping (String) -> Void) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let outPath = docs.appendingPathComponent("bench_output.txt").path
    unlink(outPath)
    freopen(outPath, "a", stdout)
    freopen(outPath, "a", stderr)
    setvbuf(stdout, nil, _IONBF, 0)
    setvbuf(stderr, nil, _IONBF, 0)

    guard let wasmPath = Bundle.main.path(forResource: "tap_counter_release", ofType: "wasm") else {
        emit("FAIL: bundled artifacts missing")
        return
    }

    let iterations = 5

    for engine in ["wasmkit", "jsc"] {
        emit("\(engine): \(iterations) runs …")
        for i in 0..<iterations {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    runEngineBench(engine, wasmPath: wasmPath, run: i, emit: emit)
                }
            }
        }
    }

    let text = (try? String(contentsOfFile: outPath, encoding: .utf8)) ?? ""
    let results = text.split(separator: "\n").filter { $0.hasPrefix("RESULT") }
    emit("")
    results.forEach { emit(String($0)) }
    emit("DONE (\(results.count) results; full log in Documents/bench_output.txt)")
    NSLog("[engine-bench] %@", results.joined(separator: " | "))
}

// MARK: - One engine's pass (the conformance suite's protocol, timed)

@MainActor
private func runEngineBench(_ engine: String, wasmPath: String, run: Int, emit: (String) -> Void) {
    guard let data = FileManager.default.contents(atPath: wasmPath) else { return }
    let wasm = [UInt8](data)
    do {
        var stream: [UInt8] = []
        let imports = WasmHostImports(
            onRenderTree: { stream.append(contentsOf: $0) },
            onLog: { _ in },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: {}
        )
        let runtime: any WasmRuntime = engine == "jsc" ? JSCRuntime() : WasmKitRuntime()
        let launchStart = Date()
        try runtime.launch(wasm: wasm, hostImports: imports)
        _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
        _ = try runtime.call("iso_hot_render", [])
        let startupMs = Date().timeIntervalSince(launchStart) * 1000

        guard contains(stream, "Tap me"), let tapID = firstTapID(in: stream) else {
            emit("\(engine) run \(run): first frame lacks the counter")
            return
        }

        var samples: [Double] = []
        for _ in 0..<20 {
            stream.removeAll()
            let tapStart = Date()
            send(runtime, id: tapID, value: "")
            _ = try runtime.call("iso_hot_render", [])
            samples.append(Date().timeIntervalSince(tapStart) * 1000)
            guard contains(stream, "Tapped") else {
                emit("\(engine) run \(run): tap produced no update")
                return
            }
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sizeMB = Double(wasm.count) / 1e6
        print(String(
            format: "RESULT engine=%@ artifact=wasm size_mb=%.1f startup_ms=%.0f tap_med_ms=%.2f tap_mean_ms=%.2f taps=20",
            engine, sizeMB, startupMs, samples[samples.count / 2], mean))
    } catch {
        emit("\(engine) run \(run) failed: \(error)")
    }
}

@MainActor
private func send(_ runtime: any WasmRuntime, id: String, value: String) {
    let idBytes = Array(id.utf8)
    let valueBytes = Array(value.utf8)
    guard
        case .i32(let idPtr)? = try? runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))]),
        case .i32(let valuePtr)? = try? runtime.call("iso_hot_alloc", [.i32(Int32(valueBytes.count))])
    else { return }
    runtime.writeBytes(UInt32(idPtr), idBytes)
    runtime.writeBytes(UInt32(valuePtr), valueBytes)
    _ = try? runtime.call(
        "iso_hot_event",
        [.i32(idPtr), .i32(Int32(idBytes.count)), .i32(valuePtr), .i32(Int32(valueBytes.count))])
    _ = try? runtime.call("iso_hot_free", [.i32(idPtr)])
    _ = try? runtime.call("iso_hot_free", [.i32(valuePtr)])
}

private func firstTapID(in bytes: [UInt8]) -> String? {
    let suffix = Array(".tap".utf8)
    var i = 0
    while i + suffix.count <= bytes.count {
        if Array(bytes[i..<(i + suffix.count)]) == suffix {
            var start = i
            while start > 0 {
                let c = bytes[start - 1]
                if (c >= 0x30 && c <= 0x39) || c == 0x2E || (c >= 0x61 && c <= 0x7A) {
                    start -= 1
                } else { break }
            }
            if start < i {
                var id = String(decoding: bytes[start..<(i + suffix.count)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                return id
            }
        }
        i += 1
    }
    return nil
}

private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
    let n = Array(needle.utf8)
    guard !n.isEmpty, haystack.count >= n.count else { return false }
    return haystack.withUnsafeBytes { raw in
        Data(raw).range(of: Data(n)) != nil
    }
}
