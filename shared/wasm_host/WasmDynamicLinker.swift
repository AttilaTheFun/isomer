// `WasmDynamicLinker` — loads WebAssembly side modules (wasm-ld
// `--experimental-pic -shared`, with a `dylink.0` section) into a main
// instance's memory and function table, as a dynamic loader places a shared
// library in a process. With it a feature ships as a side module of a few
// kilobytes over one runtime module (the Swift standard library, Foundation
// and Isomer's SwiftUI, linked once with its symbols exported) instead of a
// reactor carrying its own copy of all of it.
//
// The conventions are the WebAssembly tool conventions' dynamic linking
// (github.com/WebAssembly/tool-conventions, DynamicLinking.md), as
// Emscripten's loader keeps them:
//
//   • The side module's memory, `dylink.0`'s size and alignment, is
//     allocated from the main module's heap (its `aligned_alloc`, else
//     `malloc`) and zeroed; its table slots are added at the end of the
//     main module's table. Their starts are its `env.__memory_base` and
//     `env.__table_base`.
//   • `env.memory`, `env.__indirect_function_table` and
//     `env.__stack_pointer` are the main module's (linked with
//     `--export-table --growable-table --export=__stack_pointer`).
//   • Every other `env` import is a symbol: a function or global the main
//     module or a side module loaded before exports. `GOT.mem.<name>` is a
//     global holding a data symbol's address (the main module exports its
//     data symbols as globals whose values are their addresses);
//     `GOT.func.<name>` one holding a function's table index (the function
//     is added to the table for it, once).
//   • Instantiating runs the side module's start function, which relocates
//     its globals (`__wasm_apply_global_relocs`); the loader then calls
//     `__wasm_apply_data_relocs`, which writes the addresses in its data
//     (pointers, function pointers in witness tables), and
//     `__wasm_call_ctors`, its constructors (for Swift, `swiftrt.o`'s, which
//     registers its metadata sections with the runtime's
//     `swift_addNewDSOImage`).
//
// Side modules must bind their own symbols locally (wasm-ld `-Bsymbolic`):
// a GOT entry for a symbol the side module itself defines would need its
// address before instantiation, which this loader doesn't resolve.
//
// Swift's relative pointers need wasm-ld with tools/patches/
// lld_wasm_pic_locrel.patch: Swift 6.4.2's wasm-ld adds `__memory_base` to
// them in a side module, and the runtime's first conformance scan traps.
//
// Nothing is unloaded: a side module's memory, table slots and registered
// Swift metadata live as long as the main instance.

import WasmKit

public enum WasmDynamicLinkerError: Error, CustomStringConvertible {
    case notASideModule
    case malformedDylink(String)
    case missingMainExport(String)
    case unresolved([String])
    case allocationFailed(size: Int)

    public var description: String {
        switch self {
        case .notASideModule:
            return "not a side module: no dylink.0 section (link with wasm-ld --experimental-pic -shared)"
        case .malformedDylink(let reason):
            return "malformed dylink.0 section: \(reason)"
        case .missingMainExport(let name):
            return "the main module exports no \(name)"
        case .unresolved(let names):
            let shown = names.prefix(20).joined(separator: ", ")
            return "unresolved imports (\(names.count)): \(shown)\(names.count > 20 ? ", …" : "")"
        case .allocationFailed(let size):
            return "the main module's allocator gave no memory for \(size) bytes"
        }
    }
}

/// A side module's `dylink.0` section: what it needs of the memory and table
/// it is loaded into, and the libraries it names.
public struct WasmDylinkInfo: Equatable, Sendable {
    public var memorySize: Int
    /// log2 of the alignment its memory needs.
    public var memoryAlignment: Int
    public var tableSize: Int
    /// log2 of the alignment its table slots need.
    public var tableAlignment: Int
    public var neededLibraries: [String]

    public init(module: Module) throws {
        guard let section = module.customSections.first(where: { $0.name == "dylink.0" }) else {
            throw WasmDynamicLinkerError.notASideModule
        }
        try self.init(bytes: Array(section.bytes))
    }

    /// Reads the section's subsections: WASM_DYLINK_MEM_INFO (1) and
    /// WASM_DYLINK_NEEDED (2); the others (export and import flags,
    /// runtime paths) are skipped.
    public init(bytes: [UInt8]) throws {
        var reader = LEBReader(bytes: bytes)
        var info = (memorySize: 0, memoryAlignment: 0, tableSize: 0, tableAlignment: 0)
        var needed: [String] = []
        while !reader.atEnd {
            let kind = try reader.byte()
            let size = try reader.uleb()
            let end = reader.position + size
            guard end <= bytes.count else { throw WasmDynamicLinkerError.malformedDylink("subsection past the end") }
            switch kind {
            case 1:
                info = (try reader.uleb(), try reader.uleb(), try reader.uleb(), try reader.uleb())
            case 2:
                for _ in 0..<(try reader.uleb()) {
                    let length = try reader.uleb()
                    needed.append(String(decoding: try reader.bytes(length), as: UTF8.self))
                }
            default:
                break
            }
            reader.position = end
        }
        memorySize = info.memorySize
        memoryAlignment = info.memoryAlignment
        tableSize = info.tableSize
        tableAlignment = info.tableAlignment
        neededLibraries = needed
    }
}

/// What side modules are loaded into: the main module's memory, table,
/// stack pointer, allocator and symbols. A WasmKit instance is one
/// (`WasmInstanceLinkMain`); a main module compiled to native code that
/// shares its memory and table with WasmKit is another.
public protocol WasmLinkMain: AnyObject {
    var memory: Memory { get }
    var table: Table { get }
    var stackPointer: Global { get }
    /// Allocates `size` bytes aligned to `alignment` from the main
    /// module's heap; 0 when it can't.
    func allocate(size: Int, alignment: Int) throws -> UInt32
    func function(named name: String) -> Function?
    func global(named name: String) -> Global?
    /// A side module was instantiated (its table slots filled), before its
    /// relocations and constructors run.
    func didInstantiate(_ module: WasmDynamicLinker.LoadedModule) throws
}

extension WasmLinkMain {
    public func didInstantiate(_ module: WasmDynamicLinker.LoadedModule) throws {}
}

/// A main module that is a WasmKit instance, its `_initialize` already run:
/// it exports `memory`, `__indirect_function_table`, `__stack_pointer` and
/// `aligned_alloc` or `malloc`.
public final class WasmInstanceLinkMain: WasmLinkMain {
    public let instance: Instance
    public let memory: Memory
    public let table: Table
    public let stackPointer: Global
    private let allocator: (_ size: Int, _ alignment: Int) throws -> UInt32

    public init(_ main: Instance) throws {
        guard let memory = main.exports[memory: "memory"] else {
            throw WasmDynamicLinkerError.missingMainExport("memory")
        }
        guard let table = main.exports[table: "__indirect_function_table"] else {
            throw WasmDynamicLinkerError.missingMainExport("__indirect_function_table (link it with --export-table)")
        }
        guard let stackPointer = main.exports[global: "__stack_pointer"] else {
            throw WasmDynamicLinkerError.missingMainExport("__stack_pointer (link it with --export=__stack_pointer)")
        }
        if let alignedAlloc = main.exports[function: "aligned_alloc"] {
            allocator = { size, alignment in
                let result = try alignedAlloc([.i32(UInt32(alignment)), .i32(UInt32(size))])
                return result.first?.i32 ?? 0
            }
        } else if let malloc = main.exports[function: "malloc"] {
            // malloc's own alignment (16 in wasi-libc) is enough for what
            // wasm-ld asks of a side module's data, up to 16.
            allocator = { size, _ in try malloc([.i32(UInt32(size))]).first?.i32 ?? 0 }
        } else {
            throw WasmDynamicLinkerError.missingMainExport("aligned_alloc or malloc")
        }
        self.instance = main
        self.memory = memory
        self.table = table
        self.stackPointer = stackPointer
    }

    public func allocate(size: Int, alignment: Int) throws -> UInt32 { try allocator(size, alignment) }
    public func function(named name: String) -> Function? { instance.exports[function: name] }
    public func global(named name: String) -> Global? { instance.exports[global: name] }
}

/// Loads side modules into a main module's memory and table. Drive it on
/// the thread that drives the main module; it is not synchronized.
public final class WasmDynamicLinker {
    /// A side module once loaded: its instance and where it was placed.
    public struct LoadedModule {
        public let instance: Instance
        public let info: WasmDylinkInfo
        public let memoryBase: UInt32
        public let tableBase: UInt32
    }

    public let main: any WasmLinkMain
    public let store: Store
    public private(set) var loaded: [LoadedModule] = []

    private var memory: Memory { main.memory }
    private var table: Table { main.table }
    /// The table index given to each function a `GOT.func` entry named.
    private var functionSlots: [String: UInt32] = [:]

    /// - Parameters:
    ///   - main: What side modules are loaded into.
    ///   - store: The store side modules are instantiated in: the one the
    ///     main module's memory and table belong to.
    public init(main: any WasmLinkMain, store: Store) {
        self.main = main
        self.store = store
    }

    /// Side modules loaded into a WasmKit instance (see `WasmInstanceLinkMain`).
    public convenience init(main: Instance, store: Store) throws {
        self.init(main: try WasmInstanceLinkMain(main), store: store)
    }

    /// Loads `bytes`, a side module, and runs its constructors.
    @discardableResult
    public func load(_ bytes: [UInt8]) throws -> LoadedModule {
        try load(parseWasm(bytes: bytes))
    }

    /// Loads `module`, a side module, and runs its constructors.
    @discardableResult
    public func load(_ module: Module) throws -> LoadedModule {
        let info = try WasmDylinkInfo(module: module)

        // Its memory, zeroed (its .bss is in it, uninitialized by segments).
        var memoryBase: UInt32 = 0
        if info.memorySize > 0 {
            let alignment = max(1 << info.memoryAlignment, 1)
            memoryBase = try main.allocate(size: info.memorySize, alignment: alignment)
            guard memoryBase != 0 else { throw WasmDynamicLinkerError.allocationFailed(size: info.memorySize) }
            memory.withUnsafeMutableBufferPointer(offset: UInt(memoryBase), count: info.memorySize) {
                _ = $0.initializeMemory(as: UInt8.self, repeating: 0)
            }
        }

        // Its table slots, at the end of the table, aligned.
        let tableAlignment = 1 << info.tableAlignment
        let padding = (tableAlignment - table.count % tableAlignment) % tableAlignment
        let tableBase = UInt32(try table.grow(by: padding + info.tableSize, store: store) + padding)

        var imports = Imports()
        var unresolved: [String] = []
        let constant = GlobalType(mutability: .constant, valueType: .i32)
        let variable = GlobalType(mutability: .variable, valueType: .i32)
        for item in module.imports {
            switch (item.module, item.name) {
            case ("env", "memory"):
                imports.define(module: "env", name: "memory", memory)
            case ("env", "__indirect_function_table"):
                imports.define(module: "env", name: "__indirect_function_table", table)
            case ("env", "__stack_pointer"):
                imports.define(module: "env", name: "__stack_pointer", main.stackPointer)
            case ("env", "__memory_base"):
                imports.define(module: "env", name: "__memory_base", try Global(store: store, type: constant, value: .i32(memoryBase)))
            case ("env", "__table_base"):
                imports.define(module: "env", name: "__table_base", try Global(store: store, type: constant, value: .i32(tableBase)))
            case ("GOT.mem", let name):
                guard let address = dataAddress(name) else { unresolved.append("GOT.mem.\(name)"); continue }
                imports.define(module: "GOT.mem", name: name, try Global(store: store, type: variable, value: .i32(address)))
            case ("GOT.func", let name):
                guard let slot = try functionSlot(name) else { unresolved.append("GOT.func.\(name)"); continue }
                imports.define(module: "GOT.func", name: name, try Global(store: store, type: variable, value: .i32(slot)))
            case ("env", let name):
                switch item.descriptor {
                case .function:
                    guard let function = function(named: name) else { unresolved.append(name); continue }
                    imports.define(module: "env", name: name, function)
                case .global:
                    guard let global = global(named: name) else { unresolved.append(name); continue }
                    imports.define(module: "env", name: name, global)
                default:
                    unresolved.append(name)
                }
            default:
                unresolved.append("\(item.module).\(item.name)")
            }
        }
        guard unresolved.isEmpty else { throw WasmDynamicLinkerError.unresolved(unresolved) }

        // Instantiating runs its start function (its globals' relocations);
        // its data's are the loader's to apply, before its constructors.
        let instance = try module.instantiate(store: store, imports: imports)
        let loadedModule = LoadedModule(instance: instance, info: info, memoryBase: memoryBase, tableBase: tableBase)
        loaded.append(loadedModule)
        try main.didInstantiate(loadedModule)
        if let relocations = instance.exports[function: "__wasm_apply_data_relocs"] {
            try relocations()
        }
        if let constructors = instance.exports[function: "__wasm_call_ctors"] {
            try constructors()
        }
        return loadedModule
    }

    // MARK: - Symbols

    /// A function the main module or a side module exports, the main
    /// module's first, then the side modules' in the order they were loaded.
    public func function(named name: String) -> Function? {
        if let function = main.function(named: name) { return function }
        for module in loaded {
            if let function = module.instance.exports[function: name] { return function }
        }
        return nil
    }

    private func global(named name: String) -> Global? {
        if let global = main.global(named: name) { return global }
        for module in loaded {
            if let global = module.instance.exports[global: name] { return global }
        }
        return nil
    }

    /// A data symbol's address: the value of the global its module exports
    /// for it (a side module's already has its memory base added, by its
    /// global relocations).
    private func dataAddress(_ name: String) -> UInt32? {
        guard let global = global(named: name), case .i32(let address) = global.value else { return nil }
        return address
    }

    /// A function's index in the table: one slot added for it, the first
    /// time a GOT entry names it.
    private func functionSlot(_ name: String) throws -> UInt32? {
        if let slot = functionSlots[name] { return slot }
        guard let function = function(named: name) else { return nil }
        let slot = UInt32(try table.grow(by: 1, value: function.reference, store: store))
        functionSlots[name] = slot
        return slot
    }
}

/// The few LEB128 reads `dylink.0` needs.
private struct LEBReader {
    let bytes: [UInt8]
    var position = 0

    var atEnd: Bool { position >= bytes.count }

    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw WasmDynamicLinkerError.malformedDylink("truncated") }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func uleb() throws -> Int {
        var result = 0
        var shift = 0
        while true {
            let byte = try byte()
            guard shift < 35 else { throw WasmDynamicLinkerError.malformedDylink("LEB128 too long") }
            result |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard position + count <= bytes.count else { throw WasmDynamicLinkerError.malformedDylink("truncated") }
        defer { position += count }
        return bytes[position..<(position + count)]
    }
}
