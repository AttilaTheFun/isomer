// Small modules, assembled byte by byte, that exercise the dynamic linker:
// a main module (memory, a growable table, `__stack_pointer`, a bump
// `aligned_alloc`, an exported function and data symbol) and two side
// modules with every kind of import a side module has (`env.memory`, the
// table, `__memory_base`, `__table_base`, `__stack_pointer`, an `env`
// function, `GOT.mem` and `GOT.func` entries), data and element segments
// placed at their bases, `__wasm_apply_data_relocs` and `__wasm_call_ctors`.
// No toolchain is needed to make them, so the tests don't depend on a
// patched wasm-ld; both linkers (Swift's and the web's) load the same bytes.

/// A module built section by section.
public struct WasmModuleBuilder {
    public static let i32: UInt8 = 0x7f
    public var customs: [(name: String, payload: [UInt8])] = []
    public var types: [(params: [UInt8], results: [UInt8])] = []
    public var imports: [[UInt8]] = []
    public var functions: [UInt32] = []
    public var tables: [[UInt8]] = []
    public var memories: [[UInt8]] = []
    public var globals: [[UInt8]] = []
    public var exports: [[UInt8]] = []
    public var elements: [[UInt8]] = []
    public var codes: [[UInt8]] = []
    public var datas: [[UInt8]] = []

    public init() {}

    public static func uleb(_ value: UInt64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7f)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    public static func sleb(_ value: Int64) -> [UInt8] {
        var value = value
        var out: [UInt8] = []
        while true {
            let byte = UInt8(value & 0x7f)
            value >>= 7
            if (value == 0 && byte & 0x40 == 0) || (value == -1 && byte & 0x40 != 0) {
                out.append(byte)
                return out
            }
            out.append(byte | 0x80)
        }
    }

    public static func name(_ string: String) -> [UInt8] { uleb(UInt64(string.utf8.count)) + Array(string.utf8) }
    static func vector(_ items: [[UInt8]]) -> [UInt8] { uleb(UInt64(items.count)) + items.flatMap { $0 } }
    static func section(_ id: UInt8, _ contents: [UInt8]) -> [UInt8] { [id] + uleb(UInt64(contents.count)) + contents }

    /// `i32.const value` then `end`: a constant expression.
    public static func const32(_ value: Int64) -> [UInt8] { [0x41] + sleb(value) + [0x0b] }
    /// `global.get index` then `end`.
    public static func globalGet(_ index: UInt32) -> [UInt8] { [0x23] + uleb(UInt64(index)) + [0x0b] }

    public mutating func type(_ params: [UInt8], _ results: [UInt8]) -> UInt32 {
        types.append((params, results))
        return UInt32(types.count - 1)
    }

    public mutating func importFunction(_ module: String, _ name: String, type: UInt32) {
        imports.append(Self.name(module) + Self.name(name) + [0x00] + Self.uleb(UInt64(type)))
    }
    public mutating func importMemory(_ module: String, _ name: String, minimum: UInt32 = 0) {
        imports.append(Self.name(module) + Self.name(name) + [0x02, 0x00] + Self.uleb(UInt64(minimum)))
    }
    public mutating func importTable(_ module: String, _ name: String) {
        imports.append(Self.name(module) + Self.name(name) + [0x01, 0x70, 0x00, 0x00])
    }
    public mutating func importGlobal(_ module: String, _ name: String, mutable: Bool) {
        imports.append(Self.name(module) + Self.name(name) + [0x03, Self.i32, mutable ? 1 : 0])
    }

    public mutating func function(type: UInt32, locals: Int = 0, code: [UInt8]) {
        functions.append(type)
        let declared: [UInt8] = locals == 0 ? [0x00] : [0x01] + Self.uleb(UInt64(locals)) + [Self.i32]
        let body = declared + code
        codes.append(Self.uleb(UInt64(body.count)) + body)
    }

    public mutating func global(mutable: Bool, _ initializer: [UInt8]) {
        globals.append([Self.i32, mutable ? 1 : 0] + initializer)
    }

    /// kind: 0 function, 1 table, 2 memory, 3 global.
    public mutating func export(_ name: String, kind: UInt8, index: UInt32) {
        exports.append(Self.name(name) + [kind] + Self.uleb(UInt64(index)))
    }

    /// An active element segment on table 0 at `offset` (a constant expression).
    public mutating func elements(at offset: [UInt8], functions: [UInt32]) {
        elements.append([0x00] + offset + Self.vector(functions.map { Self.uleb(UInt64($0)) }))
    }

    /// An active data segment on memory 0 at `offset` (a constant expression).
    public mutating func data(at offset: [UInt8], _ bytes: [UInt8]) {
        datas.append([0x00] + offset + Self.uleb(UInt64(bytes.count)) + bytes)
    }

    public func build() -> [UInt8] {
        var out: [UInt8] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
        for custom in customs { out += Self.section(0, Self.name(custom.name) + custom.payload) }
        if !types.isEmpty {
            out += Self.section(1, Self.vector(types.map { [0x60] + Self.vector($0.params.map { [$0] }) + Self.vector($0.results.map { [$0] }) }))
        }
        if !imports.isEmpty { out += Self.section(2, Self.vector(imports)) }
        if !functions.isEmpty { out += Self.section(3, Self.vector(functions.map { Self.uleb(UInt64($0)) })) }
        if !tables.isEmpty { out += Self.section(4, Self.vector(tables)) }
        if !memories.isEmpty { out += Self.section(5, Self.vector(memories)) }
        if !globals.isEmpty { out += Self.section(6, Self.vector(globals)) }
        if !exports.isEmpty { out += Self.section(7, Self.vector(exports)) }
        if !elements.isEmpty { out += Self.section(9, Self.vector(elements)) }
        if !codes.isEmpty { out += Self.section(10, Self.vector(codes)) }
        if !datas.isEmpty { out += Self.section(11, Self.vector(datas)) }
        return out
    }

    /// A `dylink.0` payload: WASM_DYLINK_MEM_INFO, then WASM_DYLINK_NEEDED
    /// when `needed` isn't empty.
    public static func dylink(memorySize: UInt64, memoryAlignment: UInt64, tableSize: UInt64, tableAlignment: UInt64, needed: [String] = []) -> [UInt8] {
        let memoryInfo = uleb(memorySize) + uleb(memoryAlignment) + uleb(tableSize) + uleb(tableAlignment)
        var payload = [UInt8(1)] + uleb(UInt64(memoryInfo.count)) + memoryInfo
        if !needed.isEmpty {
            let names = vector(needed.map(name))
            payload += [2] + uleb(UInt64(names.count)) + names
        }
        return payload
    }
}

/// The modules the tests load, and what loading them should do.
public enum WasmFixtures {
    /// Where the main module's data symbol `main_data` is.
    public static let mainDataAddress: UInt32 = 1024
    /// The main module's heap starts here (`aligned_alloc` is a bump).
    public static let heapStart: UInt32 = 4096

    /// A main module (a runtime module's shape): memory (2 pages), a table of
    /// one slot, growable, `__stack_pointer`, `main_data` (an address, with
    /// "MAIN" there), `aligned_alloc(alignment, size)` (a bump allocator
    /// from 4096) and `main_helper(x) = x + 100`.
    public static func main() -> [UInt8] {
        var m = WasmModuleBuilder()
        let alloc = m.type([WasmModuleBuilder.i32, WasmModuleBuilder.i32], [WasmModuleBuilder.i32])
        let unary = m.type([WasmModuleBuilder.i32], [WasmModuleBuilder.i32])
        m.memories = [[0x00, 0x02]]
        m.tables = [[0x70, 0x00, 0x01]]
        m.global(mutable: true, WasmModuleBuilder.const32(65536))  // 0: __stack_pointer
        m.global(mutable: true, WasmModuleBuilder.const32(Int64(heapStart)))  // 1: the heap's top
        m.global(mutable: false, WasmModuleBuilder.const32(Int64(mainDataAddress)))  // 2: main_data
        // aligned_alloc(alignment, size): p = (top + alignment - 1) & -alignment; top = p + size
        m.function(type: alloc, locals: 1, code: [
            0x23, 0x01, 0x20, 0x00, 0x6a, 0x41, 0x01, 0x6b,
            0x41, 0x00, 0x20, 0x00, 0x6b, 0x71,
            0x22, 0x02, 0x20, 0x01, 0x6a, 0x24, 0x01,
            0x20, 0x02, 0x0b,
        ])
        m.function(type: unary, code: [0x20, 0x00, 0x41] + WasmModuleBuilder.sleb(100) + [0x6a, 0x0b])
        m.export("memory", kind: 2, index: 0)
        m.export("__indirect_function_table", kind: 1, index: 0)
        m.export("__stack_pointer", kind: 3, index: 0)
        m.export("main_data", kind: 3, index: 2)
        m.export("aligned_alloc", kind: 0, index: 0)
        m.export("main_helper", kind: 0, index: 1)
        m.data(at: WasmModuleBuilder.const32(Int64(mainDataAddress)), Array("MAIN".utf8))
        return m.build()
    }

    /// Side module A: 64 bytes of memory aligned to 16, two table slots
    /// aligned to 4 (both `side_f`), `side_f(x) = main_helper(x) + 1`, and
    /// `side_data` (its memory base, where "SIDE" is at +32). Its data
    /// relocations write, at its memory base: +8 its own address +16, +12
    /// `GOT.mem.main_data`, +20 `GOT.func.main_helper`; its constructor 42 at +0.
    public static func sideA(dylink: [UInt8]? = nil) -> [UInt8] {
        var m = WasmModuleBuilder()
        m.customs = [("dylink.0", dylink ?? WasmModuleBuilder.dylink(memorySize: 64, memoryAlignment: 4, tableSize: 2, tableAlignment: 2, needed: ["libmain.so"]))]
        let void = m.type([], [])
        let unary = m.type([WasmModuleBuilder.i32], [WasmModuleBuilder.i32])
        m.importMemory("env", "memory")
        m.importTable("env", "__indirect_function_table")
        m.importGlobal("env", "__memory_base", mutable: false)  // global 0
        m.importGlobal("env", "__table_base", mutable: false)  // global 1
        m.importGlobal("env", "__stack_pointer", mutable: true)  // global 2
        m.importFunction("env", "main_helper", type: unary)  // function 0
        m.importGlobal("GOT.mem", "main_data", mutable: true)  // global 3
        m.importGlobal("GOT.func", "main_helper", mutable: true)  // global 4
        m.function(type: unary, code: [0x20, 0x00, 0x10, 0x00, 0x41, 0x01, 0x6a, 0x0b])  // 1: side_f
        m.function(type: void, code: [  // 2: __wasm_apply_data_relocs
            0x23, 0x00, 0x41, 0x08, 0x6a, 0x23, 0x00, 0x41, 0x10, 0x6a, 0x36, 0x02, 0x00,
            0x23, 0x00, 0x41, 0x0c, 0x6a, 0x23, 0x03, 0x36, 0x02, 0x00,
            0x23, 0x00, 0x41, 0x14, 0x6a, 0x23, 0x04, 0x36, 0x02, 0x00,
            0x0b,
        ])
        m.function(type: void, code: [0x23, 0x00, 0x41, 0x2a, 0x36, 0x02, 0x00, 0x0b])  // 3: __wasm_call_ctors
        m.global(mutable: false, WasmModuleBuilder.globalGet(0))  // 5: side_data = __memory_base
        m.export("side_f", kind: 0, index: 1)
        m.export("__wasm_apply_data_relocs", kind: 0, index: 2)
        m.export("__wasm_call_ctors", kind: 0, index: 3)
        m.export("side_data", kind: 3, index: 5)
        m.elements(at: WasmModuleBuilder.globalGet(1), functions: [1, 1])
        m.data(at: WasmModuleBuilder.globalGet(0), [UInt8](repeating: 0, count: 32) + Array("SIDE".utf8))
        return m.build()
    }

    /// Side module B, loaded after A: 16 bytes aligned to 4, no table slots;
    /// its constructor writes at its memory base: +0 `side_f(1)` (102: A's
    /// function calling the main module's), +4 `GOT.mem.side_data` (A's
    /// memory base), +8 `GOT.func.side_f` (a new slot for A's function).
    public static func sideB() -> [UInt8] {
        var m = WasmModuleBuilder()
        m.customs = [("dylink.0", WasmModuleBuilder.dylink(memorySize: 16, memoryAlignment: 2, tableSize: 0, tableAlignment: 0))]
        let void = m.type([], [])
        let unary = m.type([WasmModuleBuilder.i32], [WasmModuleBuilder.i32])
        m.importMemory("env", "memory")
        m.importGlobal("env", "__memory_base", mutable: false)  // global 0
        m.importFunction("env", "side_f", type: unary)  // function 0
        m.importGlobal("GOT.mem", "side_data", mutable: true)  // global 1
        m.importGlobal("GOT.func", "side_f", mutable: true)  // global 2
        m.function(type: void, code: [  // 1: __wasm_call_ctors
            0x23, 0x00, 0x41, 0x01, 0x10, 0x00, 0x36, 0x02, 0x00,
            0x23, 0x00, 0x41, 0x04, 0x6a, 0x23, 0x01, 0x36, 0x02, 0x00,
            0x23, 0x00, 0x41, 0x08, 0x6a, 0x23, 0x02, 0x36, 0x02, 0x00,
            0x0b,
        ])
        m.export("__wasm_call_ctors", kind: 0, index: 1)
        return m.build()
    }

    /// A side module importing `env.memory` as a function.
    public static func wrongKind() -> [UInt8] {
        var m = WasmModuleBuilder()
        m.customs = [("dylink.0", WasmModuleBuilder.dylink(memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0))]
        let void = m.type([], [])
        m.importFunction("env", "memory", type: void)
        return m.build()
    }

    /// A side module importing symbols nothing defines.
    public static func unresolved() -> [UInt8] {
        var m = WasmModuleBuilder()
        m.customs = [("dylink.0", WasmModuleBuilder.dylink(memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0))]
        let void = m.type([], [])
        m.importFunction("env", "nowhere", type: void)
        m.importGlobal("GOT.mem", "no_data", mutable: true)
        m.importGlobal("GOT.func", "no_function", mutable: true)
        m.importGlobal("elsewhere", "thing", mutable: false)
        return m.build()
    }

    /// A side module whose element segment needs more slots than its
    /// `dylink.0` claims: instantiating it must fail, not write past the
    /// table.
    public static func overlongElements() -> [UInt8] {
        var m = WasmModuleBuilder()
        m.customs = [("dylink.0", WasmModuleBuilder.dylink(memorySize: 0, memoryAlignment: 0, tableSize: 1, tableAlignment: 0))]
        let void = m.type([], [])
        m.importTable("env", "__indirect_function_table")
        m.importGlobal("env", "__table_base", mutable: false)
        m.function(type: void, code: [0x0b])
        m.elements(at: WasmModuleBuilder.globalGet(0), functions: [0, 0, 0, 0])
        return m.build()
    }

    /// Every fixture by file name, for the web's linker test.
    public static var all: [String: [UInt8]] {
        [
            "main.wasm": main(),
            "side_a.wasm": sideA(),
            "side_b.wasm": sideB(),
            "wrong_kind.wasm": wrongKind(),
            "unresolved.wasm": unresolved(),
            "overlong_elements.wasm": overlongElements(),
            "truncated_dylink.wasm": sideA(dylink: [0x01, 0x05, 0x40]),
            "huge_alignment.wasm": sideA(dylink: WasmModuleBuilder.dylink(memorySize: 64, memoryAlignment: 40, tableSize: 0, tableAlignment: 0)),
        ]
    }
}
