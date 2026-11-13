// Event → frame for a drag, as tests/wasm_engines' testBenchmarkDrag measures
// it: launch is done; the first frame; then drags across the view that has a
// DragGesture, each 60 `changed` events with a render after each (the time
// of each is a sample), then its release and the frames of the animation it
// starts. Ten drags, in turn right, left, down and up.
import Foundation
@_spi(OnlyForCLI) import WasmKit

enum DragBench {
    static func run(
        call: (String, [Value]) throws -> [Value],
        write: (UInt32, [UInt8]) -> Void,
        stream: () -> [UInt8], clearStream: () -> Void,
        takeWantsRender: () -> Bool
    ) throws -> String {
        let t0 = Date()
        _ = try call("iso_hot_start", [.f64(390.0.bitPattern), .f64(680.0.bitPattern)])
        _ = try call("iso_hot_render", [])
        let firstMs = Date().timeIntervalSince(t0) * 1000
        guard let dragID = firstID(in: stream(), suffix: ".drag") else { return "[drag-bench] no drag id" }

        func send(_ value: String) throws {
            let id = Array(dragID.utf8), v = Array(value.utf8)
            let idPtr = try call("iso_hot_alloc", [.i32(UInt32(id.count))])[0].i32
            let vPtr = try call("iso_hot_alloc", [.i32(UInt32(max(v.count, 1)))])[0].i32
            write(idPtr, id)
            write(vPtr, v)
            _ = try call("iso_hot_event", [.i32(idPtr), .i32(UInt32(id.count)), .i32(vPtr), .i32(UInt32(v.count))])
            _ = try call("iso_hot_free", [.i32(idPtr)])
            _ = try call("iso_hot_free", [.i32(vPtr)])
        }

        var samples: [Double] = [], releases: [Double] = [], releaseFrames = 0
        let directions = [(2, 0), (-2, 0), (0, 2), (0, -2)]
        for drag in 0..<10 {
            let (dx, dy) = directions[drag % 4]
            for step in 1...60 {
                clearStream()
                let t = Date()
                try send("changed:\(step * dx),\(step * dy)")
                _ = try call("iso_hot_render", [])
                samples.append(Date().timeIntervalSince(t) * 1000)
            }
            let t = Date()
            _ = takeWantsRender()
            try send("ended:\(60 * dx),\(60 * dy)")
            var frames = 0
            repeat { _ = try call("iso_hot_render", []); frames += 1 } while takeWantsRender() && frames < 40
            releases.append(Date().timeIntervalSince(t) * 1000)
            releaseFrames += frames
        }
        samples.sort()
        let mean = samples.reduce(0, +) / Double(samples.count)
        return (String(format: "[drag-bench] first frame %.1f ms; event→frame (%d drag events): mean %.2f ms, median %.2f, p90 %.2f, max %.2f; release %.1f ms mean (%.1f frames)",
                     firstMs, samples.count, mean, samples[samples.count / 2], samples[samples.count * 9 / 10], samples.last!,
                     releases.reduce(0, +) / Double(releases.count), Double(releaseFrames) / Double(releases.count)))
    }

    static func firstID(in bytes: [UInt8], suffix: String) -> String? {
        let s = Array(suffix.utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        var i = 0
        while i + s.count <= bytes.count {
            if Array(bytes[i..<(i + s.count)]) == s {
                var start = i
                while start > 0 && ok(bytes[start - 1]) { start -= 1 }
                var id = String(decoding: bytes[start..<(i + s.count)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                if !id.isEmpty { return id }
            }
            i += 1
        }
        return nil
    }
}
