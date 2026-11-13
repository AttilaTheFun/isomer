// The 2048 drag benchmark on an iPhone: event → frame for the Playground's
// 2048 sample as a self-contained reactor, as a side module over the
// Storybook's runtime (both interpreted by WasmKit), and as that side module
// over the runtime run in mixed mode (wasm2c'd native copies of its hot
// functions). Three runs of each, mixed last; each line on screen, in
// Documents/bench_output.txt and on standard output (devicectl --console).
import Foundation
import SwiftUI
import UIKit

@main
struct MixedBenchApp: App {
    var body: some Scene {
        WindowGroup { BenchView() }
    }
}

struct BenchView: View {
    @State private var lines: [String] = ["2048 drag benchmark: running…"]
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
            let emit: (String) -> Void = { line in DispatchQueue.main.async { lines.append(line) } }
            // Native code compiled from wasm recurses on the C stack, as the
            // interpreter's host calls do: a big stack, as the engine bench has.
            let thread = Thread { runBenches(emit: emit) }
            thread.stackSize = 64 << 20
            thread.start()
        }
    }
}

private func runBenches(emit: @escaping (String) -> Void) {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let outURL = docs.appendingPathComponent("bench_output.txt")
    try? FileManager.default.removeItem(at: outURL)
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    let out = try? FileHandle(forWritingTo: outURL)
    setvbuf(stdout, nil, _IONBF, 0)
    func say(_ line: String) {
        print(line)
        out?.write(Data((line + "\n").utf8))
        emit(line)
    }
    func resource(_ name: String) -> [UInt8] {
        let url = Bundle.main.url(forResource: name, withExtension: nil)!
        return Array(try! Data(contentsOf: url))
    }
    let device = UIDevice.current
    say("RESULT device \(device.model) \(device.systemName) \(device.systemVersion)")
    let reactor = resource("game2048_release.wasm")
    let runtime = resource("runtime.wasm")
    let namedRuntime = resource("runtime_named.wasm")
    let side = resource("game2048_side.wasm")
    let shim = resource("shim.wasm")
    let slots = String(decoding: resource("slots.txt"), as: UTF8.self)
    let routed = Set(String(decoding: resource("routed.txt"), as: UTF8.self).split(separator: "\n").map(String.init))
    say("RESULT sizes: reactor \(reactor.count) B, side module \(side.count) B, runtime \(runtime.count) B")

    for run in 1...3 {
        do {
            for line in try runInterpretedBench(main: reactor, sides: []) { say("RESULT before (self-contained reactor) #\(run): \(line)") }
        } catch { say("RESULT before #\(run) failed: \(error)") }
    }
    for run in 1...3 {
        do {
            for line in try runInterpretedBench(main: runtime, sides: [side]) { say("RESULT side module, interpreted #\(run): \(line)") }
        } catch { say("RESULT side module, interpreted #\(run) failed: \(error)") }
    }
    for run in 1...3 {
        do {
            for line in try runMixedBench(runtime: namedRuntime, shim: shim, slots: slots, sides: [side], routed: routed) {
                say("RESULT side module, mixed #\(run): \(line)")
            }
        } catch { say("RESULT side module, mixed #\(run) failed: \(error)") }
    }
    say("RESULT done")
}
