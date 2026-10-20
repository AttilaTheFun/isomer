// The on-device engine benchmark: runs the same console bench as the
// Pixel/emulator passes (WAMR interp, compiled in with a renamed main) plus a
// JSC pass over the Swift engine seam, then shows the RESULT lines on screen
// and mirrors them to Documents/bench_output.txt + NSLog for retrieval. All
// engine output (printf from the C bench, print from the JSC bench) lands in
// the same redirected file.

import CBenchEntries
import Foundation
import SwiftUI
import UIKit
import IsomerJSCRuntime
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

    func runC(_ name: String, _ entry: (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32, _ artifact: String) {
        emit("\(name): \(iterations) runs …")
        for i in 0..<iterations {
            var argv: [UnsafeMutablePointer<CChar>?] = [strdup("bench"), strdup(artifact), strdup("20"), nil]
            let rc = argv.withUnsafeMutableBufferPointer { entry(3, $0.baseAddress) }
            argv.forEach { free($0) }
            if rc != 0 { emit("\(name) run \(i): exit \(rc)") }
        }
    }

    runC("wamr-interp", iso_wamr_bench_main, wasmPath)

    emit("jsc: \(iterations) runs …")
    for i in 0..<iterations {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                runJSCBench(wasmPath: wasmPath, run: i, emit: emit)
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

// MARK: - The JSC pass (the conformance suite's protocol, timed)

@MainActor
private func runJSCBench(wasmPath: String, run: Int, emit: (String) -> Void) {
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
        let runtime = JSCRuntime()
        let launchStart = Date()
        try runtime.launch(wasm: wasm, hostImports: imports)
        _ = try runtime.call("iso_hot_start", [.f64(390), .f64(680)])
        _ = try runtime.call("iso_hot_render", [])
        let startupMs = Date().timeIntervalSince(launchStart) * 1000

        guard contains(stream, "Tap me"), let tapID = firstTapID(in: stream) else {
            emit("jsc run \(run): first frame lacks the counter")
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
                emit("jsc run \(run): tap produced no update")
                return
            }
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        let sizeMB = Double(wasm.count) / 1e6
        print(String(
            format: "RESULT engine=jsc artifact=wasm size_mb=%.1f startup_ms=%.0f tap_med_ms=%.2f tap_mean_ms=%.2f taps=20",
            sizeMB, startupMs, samples[samples.count / 2], mean))
    } catch {
        emit("jsc run \(run) failed: \(error)")
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
