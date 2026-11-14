// `WasmDynamicLinker` — side modules under WasmKit: IsomerWasmDylink's
// engine-neutral linker (placement, symbols, relocation order; see
// dylink/WasmSideModuleLinker.swift) with WasmKit's memory, table,
// functions and globals. With it a feature ships as a side module of a few
// kilobytes over one runtime module (the Swift standard library, Foundation
// and Isomer's SwiftUI, linked once with its symbols exported) instead of a
// reactor carrying its own copy of all of it.
//
// Swift's relative pointers need a side module linked by a wasm-ld that
// doesn't add `__memory_base` to them (tools/patches/
// lld_wasm_pic_locrel.patch), or one corrected after the link
// (//tools/wasm/side_module_fixup).

@_exported import IsomerWasmDylink
import WasmKit

public typealias WasmDynamicLinkerError = WasmLinkError

/// What side modules are loaded into: the main module's memory, table,
/// stack pointer, allocator and symbols. A WasmKit instance is one
/// (`WasmInstanceLinkMain`); a main module whose hot functions also run as
/// native code over the same memory and table (mixed mode) is another.
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
            throw WasmLinkError.missingMainExport("memory")
        }
        guard let table = main.exports[table: "__indirect_function_table"] else {
            throw WasmLinkError.missingMainExport("__indirect_function_table (link it with --export-table)")
        }
        guard let stackPointer = main.exports[global: "__stack_pointer"] else {
            throw WasmLinkError.missingMainExport("__stack_pointer (link it with --export=__stack_pointer)")
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
            throw WasmLinkError.missingMainExport("aligned_alloc or malloc")
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

/// WasmKit as a `WasmLinkEngine`: the link main's memory and table, side
/// modules instantiated in the main module's store.
public final class WasmKitLinkEngine: WasmLinkEngine {
    public let main: any WasmLinkMain
    public let store: Store

    public init(main: any WasmLinkMain, store: Store) {
        self.main = main
        self.store = store
    }

    public func allocate(size: Int, alignment: Int) throws -> UInt32 { try main.allocate(size: size, alignment: alignment) }
    public var memoryByteCount: Int { main.memory.byteCount }

    public func zeroMemory(at address: UInt32, count: Int) throws {
        main.memory.withUnsafeMutableBufferPointer(offset: UInt(address), count: count) {
            _ = $0.initializeMemory(as: UInt8.self, repeating: 0)
        }
    }

    public var tableCount: Int { main.table.count }
    public func growTable(by count: Int) throws -> Int { try main.table.grow(by: count, store: store) }
    public func appendToTable(_ function: Function) throws -> UInt32 {
        UInt32(try main.table.grow(by: 1, value: function.reference, store: store))
    }

    public func mainFunction(named name: String) -> Function? { main.function(named: name) }
    public func mainGlobal(named name: String) -> Global? { main.global(named: name) }
    public func function(named name: String, in instance: Instance) -> Function? { instance.exports[function: name] }
    public func global(named name: String, in instance: Instance) -> Global? { instance.exports[global: name] }
    public func address(of global: Global) -> UInt32? {
        if case .i32(let address) = global.value { return address }
        return nil
    }

    public func instantiate(
        _ module: Module, bindings: [(import: WasmImportDescriptor, binding: WasmLinkBinding<Function, Global>)]
    ) throws -> Instance {
        var imports = Imports()
        let constant = GlobalType(mutability: .constant, valueType: .i32)
        let variable = GlobalType(mutability: .variable, valueType: .i32)
        for (item, binding) in bindings {
            switch binding {
            case .memory:
                imports.define(module: item.module, name: item.name, main.memory)
            case .table:
                imports.define(module: item.module, name: item.name, main.table)
            case .stackPointer:
                imports.define(module: item.module, name: item.name, main.stackPointer)
            case .constant(let value):
                imports.define(module: item.module, name: item.name, try Global(store: store, type: constant, value: .i32(value)))
            case .got(let value):
                imports.define(module: item.module, name: item.name, try Global(store: store, type: variable, value: .i32(value)))
            case .function(let function):
                imports.define(module: item.module, name: item.name, function)
            case .global(let global):
                imports.define(module: item.module, name: item.name, global)
            }
        }
        return try module.instantiate(store: store, imports: imports)
    }

    public func call(_ function: Function) throws { _ = try function([]) }

    public func didInstantiate(_ module: WasmSideModuleLinker<WasmKitLinkEngine>.Loaded) throws {
        try main.didInstantiate(module)
    }
}

/// Loads side modules into a main module's memory and table under WasmKit.
/// Drive it on the thread that drives the main module; it is not
/// synchronized.
public final class WasmDynamicLinker {
    public typealias LoadedModule = WasmSideModuleLinker<WasmKitLinkEngine>.Loaded

    public let main: any WasmLinkMain
    public let store: Store
    private let linker: WasmSideModuleLinker<WasmKitLinkEngine>

    public var loaded: [LoadedModule] { linker.loaded }

    /// - Parameters:
    ///   - main: What side modules are loaded into.
    ///   - store: The store side modules are instantiated in: the one the
    ///     main module's memory and table belong to.
    public init(main: any WasmLinkMain, store: Store) {
        self.main = main
        self.store = store
        linker = WasmSideModuleLinker(engine: WasmKitLinkEngine(main: main, store: store))
    }

    /// Side modules loaded into a WasmKit instance (see `WasmInstanceLinkMain`).
    public convenience init(main: Instance, store: Store) throws {
        self.init(main: try WasmInstanceLinkMain(main), store: store)
    }

    /// Loads `bytes`, a side module, and runs its constructors.
    @discardableResult
    public func load(_ bytes: [UInt8]) throws -> LoadedModule {
        let description = try WasmSideModuleDescription(bytes: bytes)
        return try linker.load(try parseWasm(bytes: bytes), description: description)
    }

    /// A function the main module or a side module exports, the main
    /// module's first.
    public func function(named name: String) -> Function? { linker.function(named: name) }
}
