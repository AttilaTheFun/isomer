// The corpus (tools/wasm_mixed_corpus) run under WasmKit's interpreter with
// WasmKitFunctionProfile: its screens one after another (each shown for its
// dwell, a timer changing its state), and a driver operating whatever each
// screen's frames show, by the interactive ids the tree carries (taps, drags,
// text, sliders, toggles and pickers, long presses, context menus). The
// profile (`<function index> <calls> <self ns>`) goes to the test's outputs,
// for `wasm_mixed profile-set` (corpus_native_set.txt; the BUILD file says
// how). CORPUS_SECONDS: how long (the corpus's 88 screens take 225 s).

import CoreFoundation
import Foundation
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import XCTest

@MainActor
final class CorpusProfile: XCTestCase {
    static let kinds = [".tap", ".drag", ".text", ".slider", ".host", ".longpress", ".ctx"]

    func artifact(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/tests/side_modules/\(relative)")))
    }

    func testProfileTheCorpus() throws {
        let environment = ProcessInfo.processInfo.environment
        var renderRequested = false
        var onFrame: ([UInt8]) -> Void = { _ in }
        var first: [UInt8] = []
        var frames = 0
        let imports = WasmHostImports(
            onRenderTree: { bytes in
                frames += 1
                if frames == 1 { first = bytes }
                onFrame(bytes)
            },
            onLog: { print("guest log: \($0)") },
            epochMillis: { Date().timeIntervalSince1970 * 1000 },
            onScheduleRender: { renderRequested = true })

        let profile = WasmKitFunctionProfile()
        let runtime = WasmKitRuntime()
        runtime.profile = profile
        try runtime.launch(wasm: try artifact("storybook_runtime.wasm"), hostImports: imports)
        try runtime.loadSideModule(wasm: try artifact("corpus_side.wasm"))

        func settle() {
            while CFRunLoopRunInMode(.defaultMode, 0, true) == .handledSource {}
        }
        // A 120 Hz display's ticks; between them the loop runs (the
        // screens' timers). Far behind (the profiler is slow), it doesn't
        // hurry to catch up.
        var tick = DispatchTime.now().uptimeNanoseconds
        func nextTick() {
            tick += 8_333_333
            let now = DispatchTime.now().uptimeNanoseconds
            if now > tick + 100_000_000 { tick = now }
            while DispatchTime.now().uptimeNanoseconds < tick {
                CFRunLoopRunInMode(.defaultMode, 0.0005, true)
            }
        }
        func send(_ id: String, _ value: String) throws {
            let idBytes = Array(id.utf8), v = Array(value.utf8)
            let idPointer = try runtime.call("iso_hot_alloc", [.i32(Int32(idBytes.count))])?.u32Value ?? 0
            let valuePointer = try runtime.call("iso_hot_alloc", [.i32(Int32(max(v.count, 1)))])?.u32Value ?? 0
            runtime.writeBytes(idPointer, idBytes)
            runtime.writeBytes(valuePointer, v)
            _ = try runtime.call("iso_hot_event", [
                .i32(Int32(bitPattern: idPointer)), .i32(Int32(idBytes.count)),
                .i32(Int32(bitPattern: valuePointer)), .i32(Int32(v.count)),
            ])
            _ = try runtime.call("iso_hot_free", [.i32(Int32(bitPattern: idPointer))])
            _ = try runtime.call("iso_hot_free", [.i32(Int32(bitPattern: valuePointer))])
            _ = try runtime.call("iso_hot_render", [])
            settle()
        }

        // As a host injecting its dependencies does: registering one
        // installs the guest's Swift executor, without which no Task runs
        // (the screens' timers).
        _ = try runtime.call("swift_ffi_isomer_register_HTTPHost", [])
        _ = try runtime.call("iso_hot_start", [.f64(420), .f64(912)])
        _ = try runtime.call("iso_hot_render", [])
        settle()

        // Each screen's interactive ids, from its frames; a new screen
        // (its title, "corpus-screen-<n>") starts a new pool.
        var pool: [String] = []
        var seen: Set<String> = []
        var screen = -1, screens = 0
        let marker = Array("corpus-screen-".utf8)
        onFrame = { bytes in
            if let n = Self.number(after: marker, in: bytes), n != screen {
                screen = n
                screens += 1
                pool = []
                seen = []
            }
            for kind in Self.kinds {
                for id in Self.ids(in: bytes, suffix: kind) where seen.insert(id).inserted { pool.append(id) }
            }
        }
        onFrame(first)

        let seconds = Double(environment["CORPUS_SECONDS"] ?? "") ?? 225
        let start = Date()
        var n = 0, next = 0, events = 0
        var dragging: (id: String, step: Int)?
        while Date().timeIntervalSince(start) < seconds {
            nextTick()
            if renderRequested {
                renderRequested = false
                _ = try runtime.call("iso_hot_render", [])
                settle()
            }
            n += 1
            guard n % 3 == 0 else { continue }
            if let d = dragging {
                if d.step < 8 {
                    try send(d.id, "changed:\((d.step + 1) * 7),\((d.step + 1) * (n % 2 == 0 ? 3 : -3))")
                    dragging = (d.id, d.step + 1)
                } else {
                    try send(d.id, "ended:56,0")
                    dragging = nil
                }
                continue
            }
            guard !pool.isEmpty else { continue }
            let id = pool[next % pool.count]
            next += 1
            events += 1
            switch Self.kinds.first(where: { id.hasSuffix($0) }) ?? ".tap" {
            case ".drag": dragging = (id, 0)
            case ".text": try send(id, "typed \(n)")
            case ".slider": try send(id, "0.\(n % 10)")
            case ".host": try send(id, ["1", "0", "2", "1", "back"][next % 5])
            case ".longpress":
                try send(id, "press:1")
                try send(id, "fire")
                try send(id, "press:0")
            case ".ctx": try send(id, "0")
            default: try send(id, "")
            }
        }

        let ran = profile.calls.filter { $0 > 0 }.count
        print("[corpus] \(screens) screens, \(frames) frames, \(events) events; \(ran) runtime functions ran")
        if let out = environment["TEST_UNDECLARED_OUTPUTS_DIR"] {
            try profile.report().write(toFile: "\(out)/corpus_profile.txt", atomically: true, encoding: .utf8)
        }
        XCTAssertGreaterThan(screens, 10)
        XCTAssertGreaterThan(ran, 1000)
    }

    /// The decimal number right after `marker` in a frame's bytes, if any.
    static func number(after marker: [UInt8], in bytes: [UInt8]) -> Int? {
        var i = 0
        while i + marker.count < bytes.count {
            if bytes[i] == marker[0], bytes[i..<(i + marker.count)].elementsEqual(marker) {
                var j = i + marker.count, value = 0, digits = 0
                while j < bytes.count, (48...57).contains(bytes[j]) {
                    value = value * 10 + Int(bytes[j] - 48)
                    j += 1
                    digits += 1
                }
                if digits > 0 { return value }
            }
            i += 1
        }
        return nil
    }

    /// Every distinct `<…><suffix>` id in a frame's bytes, in order.
    static func ids(in bytes: [UInt8], suffix: String) -> [String] {
        let s = Array(suffix.utf8)
        func ok(_ c: UInt8) -> Bool { (c >= 48 && c <= 57) || c == 46 || (c >= 97 && c <= 122) }
        var out: [String] = []
        var i = 0
        while i + s.count <= bytes.count {
            if bytes[i] == s[0], bytes[i..<(i + s.count)].elementsEqual(s), i + s.count == bytes.count || !ok(bytes[i + s.count]) {
                var start = i
                while start > 0 && ok(bytes[start - 1]) { start -= 1 }
                var id = String(decoding: bytes[start..<(i + s.count)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                if id.count > s.count, !out.contains(id) { out.append(id) }
            }
            i += 1
        }
        return out
    }
}
