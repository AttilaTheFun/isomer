// A field's key reaches a wasm page and is answered at once
// (`iso_hot_key_event`, through WasmFeatureRuntime.sendKey, as Android's
// WasmView sends it): the page takes Return (`.onKeyPress(.return)`), says
// so, and draws the change; a key it doesn't take is answered "not taken",
// so the field types it.

import Foundation
import IsomerWasmHost
import IsomerWasmKitRuntime
import IsomerWasmRuntime
import SwiftFFIWasmHost
import XCTest

@MainActor
final class WasmKeyEventTests: XCTestCase {
    func path(_ relative: String) -> String {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return "\(dir)/\(workspace)/\(relative)"
    }

    func testAFieldsKeyReachesThePage() throws {
        let wasm = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path("tests/wasm_key_event/key_press.wasm"))))
        var stream: [UInt8] = []
        let feature = WasmFeatureRuntime(runtime: { _ in WasmKitRuntime() })
        defer { feature.forceShutdown() }
        feature.epochMillis = { 1.7e12 }
        feature.onTree = { stream += $0 }
        feature.resize(width: 390, height: 680)
        feature.load(bundle: WasmBundle(label: "key_press", wasm: wasm))
        let runtime = try XCTUnwrap(feature.engineRuntime, feature.status)
        _ = try runtime.call("iso_hot_render", [])
        let keys = try XCTUnwrap(Self.keysID(in: stream), "no field takes keys in the first frame")
        XCTAssertTrue(Self.contains(stream, "Returns: 0"))

        XCTAssertFalse(feature.sendKey(id: keys, value: "d\u{1F}a\u{1F}a"), "a key the field doesn't take")
        XCTAssertTrue(feature.sendKey(id: keys, value: "d\u{1F}\r\u{1F}\r"), "Return, which the field takes")
        let drawn = stream.count
        _ = try runtime.call("iso_hot_render", [])
        XCTAssertTrue(Self.contains(Array(stream[drawn...]), "Returns: 1"), "the page didn't draw the key it took")
    }

    /// The id a field's keys are reported under (TreeEncoder's
    /// `<handle>.keys` parameter, its handle lowercase letters and digits),
    /// as the tree's bytes carry it.
    static func keysID(in stream: [UInt8]) -> String? {
        let suffix = Array(".keys".utf8)
        var index = 0
        while index + suffix.count <= stream.count {
            if Array(stream[index..<index + suffix.count]) == suffix {
                var start = index
                while start > 0, isHandle(stream[start - 1]) { start -= 1 }
                if start < index { return String(decoding: stream[start..<index + suffix.count], as: UTF8.self) }
            }
            index += 1
        }
        return nil
    }

    static func isHandle(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
    }

    static func contains(_ stream: [UInt8], _ text: String) -> Bool {
        let needle = Array(text.utf8)
        guard needle.count <= stream.count else { return false }
        return (0...(stream.count - needle.count)).contains { Array(stream[$0..<$0 + needle.count]) == needle }
    }
}
