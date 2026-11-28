// Parsed modules (WasmKitModules) are kept to spare the next launch its
// parse while a view shows pages, and dropped with the last view, or when
// the system is short of memory (`forget`, on a memory warning or
// Android's trim).

import Foundation
import IsomerWasmKitRuntime
import XCTest

final class WasmKitModulesTests: XCTestCase {
    func artifact(_ relative: String) throws -> [UInt8] {
        let dir = ProcessInfo.processInfo.environment["TEST_SRCDIR"] ?? ""
        let workspace = ProcessInfo.processInfo.environment["TEST_WORKSPACE"] ?? "_main"
        return [UInt8](try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(workspace)/\(relative)")))
    }

    func testParsedModulesGoWithTheLastViewAndOnForget() throws {
        let bytes = try artifact("wasm/tap_counter_feature/tap_counter_release.wasm")
        WasmKitModules.forget()
        WasmKitModules.viewOpened()
        WasmKitModules.viewOpened()
        _ = try WasmKitModules.module(bytes)
        XCTAssertEqual(WasmKitModules.keptCount, 1)
        WasmKitModules.viewClosed()
        XCTAssertEqual(WasmKitModules.keptCount, 1, "a view still shows pages")
        WasmKitModules.viewClosed()
        XCTAssertEqual(WasmKitModules.keptCount, 0, "the last view went")

        WasmKitModules.viewOpened()
        _ = try WasmKitModules.module(bytes)
        XCTAssertEqual(WasmKitModules.keptCount, 1)
        WasmKitModules.forget()
        XCTAssertEqual(WasmKitModules.keptCount, 0, "short of memory")
        WasmKitModules.viewClosed()
    }
}
