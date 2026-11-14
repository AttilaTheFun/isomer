// The dynamic linker (IsomerWasmDylink, and WasmKit's adapter in
// IsomerWasmKitRuntime) on WasmFixtures' modules: dylink.0 and import
// sections read or refused, side modules placed (memory allocated, aligned
// and zeroed; table slots aligned at the table's end), their imports bound
// (the main module's symbols first, then earlier side modules', GOT entries
// shared), their data relocations and constructors run in order, and what
// can't be loaded refused with an error rather than a crash.

import IsomerWasmDylink
import IsomerWasmKitRuntime
import WasmFixtures
import WasmKit
import XCTest

final class WasmDylinkInfoTests: XCTestCase {
    func testReadsMemoryInfoAndNeededLibraries() throws {
        let info = try WasmDylinkInfo(module: WasmFixtures.sideA())
        XCTAssertEqual(info, WasmDylinkInfo(memorySize: 64, memoryAlignment: 4, tableSize: 2, tableAlignment: 2, neededLibraries: ["libmain.so"]))
    }

    func testAModuleWithoutDylinkIsNotASideModule() {
        XCTAssertThrowsError(try WasmDylinkInfo(module: WasmFixtures.main())) {
            XCTAssertEqual($0 as? WasmLinkError, .notASideModule)
        }
    }

    func testTruncatedSubsection() {
        XCTAssertThrowsError(try WasmDylinkInfo(section: [0x01, 0x05, 0x40])) {
            XCTAssertEqual($0 as? WasmLinkError, .malformedDylink("subsection past the end"))
        }
    }

    func testTruncatedInsideASubsection() {
        // MEM_INFO says 2 bytes, then holds one LEB that runs past them.
        XCTAssertThrowsError(try WasmDylinkInfo(section: [0x01, 0x02, 0x80, 0x80, 0x01])) {
            XCTAssertEqual($0 as? WasmLinkError, .malformedDylink("truncated"))
        }
    }

    func testOverlongLEB() {
        XCTAssertThrowsError(try WasmDylinkInfo(section: [0x01, 0x06, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01])) {
            guard case .malformedDylink = $0 as? WasmLinkError else { return XCTFail("\($0)") }
        }
    }

    func testAlignmentOutOfRange() {
        let payload = WasmModuleBuilder.dylink(memorySize: 64, memoryAlignment: 40, tableSize: 0, tableAlignment: 0)
        XCTAssertThrowsError(try WasmDylinkInfo(section: payload)) {
            XCTAssertEqual($0 as? WasmLinkError, .outOfRange("memory alignment 2^40"))
        }
        let table = WasmModuleBuilder.dylink(memorySize: 0, memoryAlignment: 0, tableSize: 1, tableAlignment: 32)
        XCTAssertThrowsError(try WasmDylinkInfo(section: table)) {
            XCTAssertEqual($0 as? WasmLinkError, .outOfRange("table alignment 2^32"))
        }
    }

    func testTruncatedModule() {
        let bytes = WasmFixtures.sideA()
        for length in [0, 4, 9, 20, bytes.count / 2] {
            XCTAssertThrowsError(try WasmSideModuleDescription(bytes: Array(bytes.prefix(length))), "\(length) bytes")
        }
    }

    func testImports() throws {
        let description = try WasmSideModuleDescription(bytes: WasmFixtures.sideB())
        XCTAssertEqual(description.imports.map { "\($0.module).\($0.name)" },
                       ["env.memory", "env.__memory_base", "env.side_f", "GOT.mem.side_data", "GOT.func.side_f"])
        XCTAssertEqual(description.imports[0].kind, .memory)
        XCTAssertEqual(description.imports[1].kind, .global(valueType: 0x7f, mutable: false))
        XCTAssertEqual(description.imports[2].kind, .function(typeIndex: 1))
        XCTAssertEqual(description.imports[3].kind, .global(valueType: 0x7f, mutable: true))
    }
}

/// An engine of the test's own: a memory and table of counts, symbols by
/// name, and a record of what the linker asked of it.
final class FakeEngine: WasmLinkEngine {
    typealias Module = String
    typealias Instance = String
    typealias Function = String
    typealias Global = UInt32

    var memoryByteCount = 1 << 16
    var tableCount = 1
    var nextAddress: UInt32 = 4096
    var allocations: [(size: Int, alignment: Int)] = []
    var zeroed: [(UInt32, Int)] = []
    var mainFunctions: [String: String] = [:]
    var mainGlobals: [String: UInt32] = [:]
    var instanceFunctions: [String: [String: String]] = [:]
    var instanceGlobals: [String: [String: UInt32]] = [:]
    var tableFunctions: [UInt32: String] = [:]
    var instantiated: [(module: String, bindings: [String])] = []
    var calls: [String] = []
    var allocationResult: UInt32?

    func allocate(size: Int, alignment: Int) throws -> UInt32 {
        allocations.append((size, alignment))
        if let allocationResult { return allocationResult }
        let address = (nextAddress + UInt32(alignment) - 1) & ~(UInt32(alignment) - 1)
        nextAddress = address + UInt32(size)
        return address
    }
    func zeroMemory(at address: UInt32, count: Int) throws { zeroed.append((address, count)) }
    func growTable(by count: Int) throws -> Int { defer { tableCount += count }; return tableCount }
    func appendToTable(_ function: String) throws -> UInt32 {
        defer { tableCount += 1 }
        tableFunctions[UInt32(tableCount)] = function
        return UInt32(tableCount)
    }
    func mainFunction(named name: String) -> String? { mainFunctions[name] }
    func mainGlobal(named name: String) -> UInt32? { mainGlobals[name] }
    func function(named name: String, in instance: String) -> String? { instanceFunctions[instance]?[name] }
    func global(named name: String, in instance: String) -> UInt32? { instanceGlobals[instance]?[name] }
    func address(of global: UInt32) -> UInt32? { global }
    func instantiate(_ module: String, bindings: [(import: WasmImportDescriptor, binding: WasmLinkBinding<String, UInt32>)]) throws -> String {
        instantiated.append((module, bindings.map { "\($0.import.module).\($0.import.name)=\(describe($0.binding))" }))
        return module
    }
    func call(_ function: String) throws { calls.append(function) }

    private func describe(_ binding: WasmLinkBinding<String, UInt32>) -> String {
        switch binding {
        case .memory: return "memory"
        case .table: return "table"
        case .stackPointer: return "sp"
        case .constant(let value): return "const \(value)"
        case .got(let value): return "got \(value)"
        case .function(let function): return function
        case .global(let global): return "global \(global)"
        }
    }
}

final class WasmSideModuleLinkerTests: XCTestCase {
    func description(_ dylink: WasmDylinkInfo, _ imports: [(String, String, WasmImportDescriptor.Kind)]) -> WasmSideModuleDescription {
        WasmSideModuleDescription(dylink: dylink, imports: imports.map { WasmImportDescriptor(module: $0.0, name: $0.1, kind: $0.2) })
    }

    func testPlacesMemoryAndTableAligned() throws {
        let engine = FakeEngine()
        engine.nextAddress = 4097
        engine.tableCount = 5
        let linker = WasmSideModuleLinker(engine: engine)
        let loaded = try linker.load("a", description: description(
            WasmDylinkInfo(memorySize: 100, memoryAlignment: 4, tableSize: 3, tableAlignment: 3), []))
        XCTAssertEqual(engine.allocations.first?.alignment, 16)
        XCTAssertEqual(loaded.memoryBase, 4112)
        XCTAssertEqual(engine.zeroed.first?.0, 4112)
        XCTAssertEqual(engine.zeroed.first?.1, 100)
        // 5 slots, aligned to 8: 3 of padding, then 3 of its own.
        XCTAssertEqual(loaded.tableBase, 8)
        XCTAssertEqual(engine.tableCount, 11)
    }

    func testNoMemoryNoAllocation() throws {
        let engine = FakeEngine()
        let loaded = try WasmSideModuleLinker(engine: engine).load("a", description: description(
            WasmDylinkInfo(memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0), []))
        XCTAssertTrue(engine.allocations.isEmpty)
        XCTAssertEqual(loaded.memoryBase, 0)
    }

    func testAllocationFailureAndOutOfBounds() {
        let engine = FakeEngine()
        engine.allocationResult = 0
        let info = WasmDylinkInfo(memorySize: 64, memoryAlignment: 0, tableSize: 0, tableAlignment: 0)
        XCTAssertThrowsError(try WasmSideModuleLinker(engine: engine).load("a", description: description(info, []))) {
            XCTAssertEqual($0 as? WasmLinkError, .allocationFailed(size: 64))
        }
        engine.allocationResult = UInt32(engine.memoryByteCount - 10)
        XCTAssertThrowsError(try WasmSideModuleLinker(engine: engine).load("a", description: description(info, []))) {
            XCTAssertEqual($0 as? WasmLinkError, .allocationOutOfBounds(address: UInt32(engine.memoryByteCount - 10), size: 64, memorySize: engine.memoryByteCount))
        }
    }

    func testTablePastFourBillionSlots() {
        let engine = FakeEngine()
        engine.tableCount = Int(UInt32.max) - 1
        let info = WasmDylinkInfo(memorySize: 0, memoryAlignment: 0, tableSize: 4, tableAlignment: 0)
        XCTAssertThrowsError(try WasmSideModuleLinker(engine: engine).load("a", description: description(info, []))) {
            guard case .outOfRange = $0 as? WasmLinkError else { return XCTFail("\($0)") }
        }
    }

    func testBindingsAndSymbolOrder() throws {
        let engine = FakeEngine()
        engine.mainFunctions = ["shared": "main.shared", "only_main": "main.only_main"]
        engine.mainGlobals = ["data": 1024]
        engine.instanceFunctions = ["a": ["shared": "a.shared", "only_a": "a.only_a"]]
        engine.instanceGlobals = ["a": ["a_data": 5000]]
        let linker = WasmSideModuleLinker(engine: engine)
        let none = WasmDylinkInfo(memorySize: 16, memoryAlignment: 0, tableSize: 0, tableAlignment: 0)
        let i32 = WasmImportDescriptor.Kind.global(valueType: 0x7f, mutable: false)
        let got = WasmImportDescriptor.Kind.global(valueType: 0x7f, mutable: true)
        let a = try linker.load("a", description: description(none, [
            ("env", "memory", .memory), ("env", "__indirect_function_table", .table),
            ("env", "__stack_pointer", got), ("env", "__memory_base", i32), ("env", "__table_base", i32),
        ]))
        _ = try linker.load("b", description: description(none, [
            ("env", "shared", .function(typeIndex: 0)), ("env", "only_a", .function(typeIndex: 0)),
            ("GOT.mem", "data", got), ("GOT.mem", "a_data", got),
            ("GOT.func", "only_main", got), ("GOT.func", "only_a", got), ("GOT.func", "only_main", got),
        ]))
        XCTAssertEqual(engine.instantiated[0].bindings, [
            "env.memory=memory", "env.__indirect_function_table=table", "env.__stack_pointer=sp",
            "env.__memory_base=const \(a.memoryBase)", "env.__table_base=const 1",
        ])
        // The main module's `shared` before side module a's; GOT.func gives
        // `only_main` one slot however many entries name it.
        XCTAssertEqual(engine.instantiated[1].bindings, [
            "env.shared=main.shared", "env.only_a=a.only_a",
            "GOT.mem.data=got 1024", "GOT.mem.a_data=got 5000",
            "GOT.func.only_main=got 1", "GOT.func.only_a=got 2", "GOT.func.only_main=got 1",
        ])
        XCTAssertEqual(engine.tableFunctions, [1: "main.only_main", 2: "a.only_a"])
    }

    func testRelocationsThenConstructors() throws {
        let engine = FakeEngine()
        engine.instanceFunctions = ["a": ["__wasm_call_ctors": "ctors", "__wasm_apply_data_relocs": "relocs"]]
        _ = try WasmSideModuleLinker(engine: engine).load("a", description: description(
            WasmDylinkInfo(memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0), []))
        XCTAssertEqual(engine.calls, ["relocs", "ctors"])
    }

    func testEveryUnresolvedImportReported() {
        let engine = FakeEngine()
        XCTAssertThrowsError(try WasmSideModuleLinker(engine: engine).load("u", description: WasmSideModuleDescription(bytes: WasmFixtures.unresolved()))) {
            XCTAssertEqual($0 as? WasmLinkError, .unresolved(["nowhere", "GOT.mem.no_data", "GOT.func.no_function", "elsewhere.thing"]))
        }
        XCTAssertTrue(engine.instantiated.isEmpty)
    }

    func testWrongImportKind() {
        XCTAssertThrowsError(try WasmSideModuleLinker(engine: FakeEngine()).load("w", description: WasmSideModuleDescription(bytes: WasmFixtures.wrongKind()))) {
            XCTAssertEqual($0 as? WasmLinkError, .wrongImportKind("env.memory"))
        }
    }
}

/// The fixtures loaded by WasmKit, through `WasmDynamicLinker`.
final class WasmKitDynamicLinkerTests: XCTestCase {
    var store: Store!
    var main: Instance!
    var linker: WasmDynamicLinker!

    override func setUpWithError() throws {
        store = Store(engine: Engine())
        main = try parseWasm(bytes: WasmFixtures.main()).instantiate(store: store, imports: Imports())
        linker = try WasmDynamicLinker(main: main, store: store)
    }

    var memory: Memory { main.exports[memory: "memory"]! }
    var table: Table { main.exports[table: "__indirect_function_table"]! }

    func word(_ address: UInt32) -> UInt32 {
        memory.withUnsafeBufferPointer(offset: UInt(address), count: 4) { $0.loadUnaligned(as: UInt32.self) }
    }

    func bytes(_ address: UInt32, _ count: Int) -> [UInt8] {
        memory.withUnsafeBufferPointer(offset: UInt(address), count: count) { Array($0) }
    }

    func callSlot(_ slot: UInt32, _ argument: UInt32) throws -> UInt32? {
        try table.function(at: Int(slot), store: store)?([.i32(argument)]).first?.i32
    }

    func testLoadsAndRelocates() throws {
        let a = try linker.load(WasmFixtures.sideA())
        // Memory from the main module's allocator, aligned to 16.
        XCTAssertEqual(a.memoryBase % 16, 0)
        XCTAssertGreaterThanOrEqual(a.memoryBase, WasmFixtures.heapStart)
        // Table: one slot before, aligned to 4: three of padding, its two.
        XCTAssertEqual(a.tableBase, 4)
        XCTAssertEqual(try callSlot(4, 5), 106)
        XCTAssertEqual(try callSlot(5, 0), 101)
        // Its data segment, at its base.
        XCTAssertEqual(bytes(a.memoryBase + 32, 4), Array("SIDE".utf8))
        // Its data relocations: its own address, the main module's data
        // symbol, the main module's function (a slot added for it).
        XCTAssertEqual(word(a.memoryBase + 8), a.memoryBase + 16)
        XCTAssertEqual(word(a.memoryBase + 12), WasmFixtures.mainDataAddress)
        XCTAssertEqual(word(a.memoryBase + 20), 6)
        XCTAssertEqual(try callSlot(6, 1), 101)
        // Then its constructor.
        XCTAssertEqual(word(a.memoryBase), 42)
        XCTAssertEqual(table.count, 7)
    }

    func testASecondSideModuleBindsTheFirstOnes() throws {
        let a = try linker.load(WasmFixtures.sideA())
        let b = try linker.load(WasmFixtures.sideB())
        XCTAssertEqual(b.memoryBase % 4, 0)
        XCTAssertGreaterThanOrEqual(b.memoryBase, a.memoryBase + 64)
        XCTAssertEqual(word(b.memoryBase), 102)
        XCTAssertEqual(word(b.memoryBase + 4), a.memoryBase)
        XCTAssertEqual(word(b.memoryBase + 8), 7)
        XCTAssertEqual(try callSlot(7, 2), 103)
        XCTAssertNotNil(linker.function(named: "side_f"))
        XCTAssertEqual(linker.loaded.count, 2)
    }

    func testZeroesItsMemory() throws {
        // Dirty the heap where side module A will go, then load it.
        let next = (WasmFixtures.heapStart + 15) & ~15
        memory.withUnsafeMutableBufferPointer(offset: UInt(next), count: 64) { _ = $0.initializeMemory(as: UInt8.self, repeating: 0xAB) }
        let a = try linker.load(WasmFixtures.sideA())
        XCTAssertEqual(a.memoryBase, next)
        XCTAssertEqual(bytes(a.memoryBase + 36, 28), [UInt8](repeating: 0, count: 28))
    }

    func testRefusals() throws {
        XCTAssertThrowsError(try linker.load(WasmFixtures.main())) { XCTAssertEqual($0 as? WasmLinkError, .notASideModule) }
        XCTAssertThrowsError(try linker.load(WasmFixtures.wrongKind()))
        XCTAssertThrowsError(try linker.load(WasmFixtures.unresolved()))
        XCTAssertThrowsError(try linker.load(Array(WasmFixtures.sideA().prefix(30))))
        // Nothing half-loaded stays.
        XCTAssertTrue(linker.loaded.isEmpty)
    }

    func testElementsPastItsSlotsFailToInstantiate() {
        let before = table.count
        XCTAssertThrowsError(try linker.load(WasmFixtures.overlongElements()))
        XCTAssertTrue(linker.loaded.isEmpty)
        // Its own slot was added; nothing past it was written.
        XCTAssertEqual(table.count, before + 1)
    }
}
