// Loads WebAssembly side modules (wasm-ld `--experimental-pic -shared`, with
// a `dylink.0` section) into a main module's memory and function table, as a
// dynamic loader places a shared library in a process: the engine-neutral
// part. What a side module needs, where it goes, what each of its imports
// is and the order its relocations and constructors run in are decided
// here; an engine (`WasmLinkEngine`: WasmKit's in IsomerWasmKitRuntime)
// only makes and calls its own objects. The web's twin is
// wasm/libraries/swift_ui/runtime/side_modules.js, which browsers and web
// views run; the tests (tests/wasm_dylink) hold both to the same modules.
//
// The conventions are the WebAssembly tool conventions' dynamic linking
// (github.com/WebAssembly/tool-conventions, DynamicLinking.md), as
// Emscripten's loader keeps them:
//
//   • The side module's memory, `dylink.0`'s size and alignment, comes from
//     the main module's heap (its allocator) and is zeroed; its table slots
//     are added at the end of the main module's table, aligned. Their starts
//     are its `env.__memory_base` and `env.__table_base`.
//   • `env.memory`, `env.__indirect_function_table` and `env.__stack_pointer`
//     are the main module's (linked with `--export-table --growable-table
//     --export=__stack_pointer`).
//   • Every other `env` import is a symbol: a function or global the main
//     module or a side module loaded before exports, the main module's
//     first. `GOT.mem.<name>` is a global holding a data symbol's address
//     (a module exports its data symbols as globals whose values are their
//     addresses); `GOT.func.<name>` one holding a function's table index
//     (the function gets one slot for all its GOT entries).
//   • Instantiating runs the side module's start function, which relocates
//     its globals; the loader then calls `__wasm_apply_data_relocs` (the
//     addresses in its data: pointers, function pointers in witness tables)
//     and `__wasm_call_ctors` (for Swift, `swiftrt.o`'s, which registers its
//     metadata with the runtime).
//
// Side modules must bind their own symbols locally (wasm-ld `-Bsymbolic`): a
// GOT entry for a symbol the side module itself defines would need its
// address before instantiation, which isn't resolved. Nothing is unloaded.

/// Why a side module couldn't be loaded.
public enum WasmLinkError: Error, Equatable, CustomStringConvertible, Sendable {
    case notASideModule
    case malformedDylink(String)
    case malformedModule(String)
    /// A `dylink.0` value no loader could honour (an alignment of 2^40, a
    /// table larger than 2^32 slots).
    case outOfRange(String)
    case missingMainExport(String)
    /// An import of the wrong kind for its name (`env.memory` as a function).
    case wrongImportKind(String)
    case unresolved([String])
    case allocationFailed(size: Int)
    /// The allocator answered with memory outside the main module's.
    case allocationOutOfBounds(address: UInt32, size: Int, memorySize: Int)

    public var description: String {
        switch self {
        case .notASideModule:
            return "not a side module: no dylink.0 section (link with wasm-ld --experimental-pic -shared)"
        case .malformedDylink(let reason):
            return "malformed dylink.0 section: \(reason)"
        case .malformedModule(let reason):
            return "malformed module: \(reason)"
        case .outOfRange(let reason):
            return "out of range: \(reason)"
        case .missingMainExport(let name):
            return "the main module exports no \(name)"
        case .wrongImportKind(let name):
            return "\(name) is imported as the wrong kind"
        case .unresolved(let names):
            let shown = names.prefix(20).joined(separator: ", ")
            return "unresolved imports (\(names.count)): \(shown)\(names.count > 20 ? ", …" : "")"
        case .allocationFailed(let size):
            return "the main module's allocator gave no memory for \(size) bytes"
        case .allocationOutOfBounds(let address, let size, let memorySize):
            return "the allocator's \(size) bytes at \(address) are outside the main module's \(memorySize)"
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

    public init(memorySize: Int, memoryAlignment: Int, tableSize: Int, tableAlignment: Int, neededLibraries: [String] = []) {
        self.memorySize = memorySize
        self.memoryAlignment = memoryAlignment
        self.tableSize = tableSize
        self.tableAlignment = tableAlignment
        self.neededLibraries = neededLibraries
    }

    /// The `dylink.0` section of `module`, a whole binary.
    public init(module bytes: [UInt8]) throws {
        let section: [UInt8]?
        do {
            section = try WasmBinary.customSection(bytes, named: "dylink.0")
        } catch let error as WasmBinaryError {
            throw WasmLinkError.malformedModule(error.reason)
        }
        guard let section else { throw WasmLinkError.notASideModule }
        try self.init(section: section)
    }

    /// Reads the section's contents (after its name): the subsections
    /// WASM_DYLINK_MEM_INFO (1) and WASM_DYLINK_NEEDED (2); the others
    /// (export and import flags, runtime paths) are skipped. Alignments above
    /// 2^31 are out of range.
    public init(section bytes: [UInt8]) throws {
        var reader = WasmByteReader(bytes)
        var memory = (size: 0, alignment: 0, tableSize: 0, tableAlignment: 0)
        var needed: [String] = []
        do {
            while !reader.atEnd {
                let kind = try reader.byte()
                let size = try reader.count()
                guard size <= reader.end - reader.position else { throw WasmBinaryError("subsection past the end") }
                let end = reader.position + size
                var sub = WasmByteReader(bytes, from: reader.position, to: end)
                switch kind {
                case 1:
                    memory = (try sub.count(), try sub.count(), try sub.count(), try sub.count())
                case 2:
                    for _ in 0..<(try sub.count()) { needed.append(try sub.name()) }
                default:
                    break
                }
                reader.position = end
            }
        } catch let error as WasmBinaryError {
            throw WasmLinkError.malformedDylink(error.reason)
        }
        guard memory.alignment < 32 else { throw WasmLinkError.outOfRange("memory alignment 2^\(memory.alignment)") }
        guard memory.tableAlignment < 32 else { throw WasmLinkError.outOfRange("table alignment 2^\(memory.tableAlignment)") }
        self.init(memorySize: memory.size, memoryAlignment: memory.alignment, tableSize: memory.tableSize,
                  tableAlignment: memory.tableAlignment, neededLibraries: needed)
    }
}

/// What the linker needs to know of a side module: its `dylink.0` and its
/// imports. An engine that parses modules itself can report them; otherwise
/// `init(bytes:)` reads them from the binary.
public struct WasmSideModuleDescription: Equatable, Sendable {
    public var dylink: WasmDylinkInfo
    public var imports: [WasmImportDescriptor]

    public init(dylink: WasmDylinkInfo, imports: [WasmImportDescriptor]) {
        self.dylink = dylink
        self.imports = imports
    }

    public init(bytes: [UInt8]) throws {
        let dylink = try WasmDylinkInfo(module: bytes)
        do {
            self.init(dylink: dylink, imports: try WasmBinary.imports(bytes))
        } catch let error as WasmBinaryError {
            throw WasmLinkError.malformedModule(error.reason)
        }
    }
}

/// What one import of a side module is bound to.
public enum WasmLinkBinding<Function, Global> {
    /// The main module's memory, table or stack pointer.
    case memory, table, stackPointer
    /// An immutable i32 global with this value (`__memory_base`, `__table_base`).
    case constant(UInt32)
    /// A mutable i32 global with this value (a `GOT.mem` or `GOT.func` entry).
    case got(UInt32)
    case function(Function)
    case global(Global)
}

/// An engine the linker places side modules with: the main module's memory,
/// table, allocator and symbols, and the engine's own objects. Methods are
/// called on the thread driving the main module.
public protocol WasmLinkEngine: AnyObject {
    associatedtype Module
    associatedtype Instance
    associatedtype Function
    associatedtype Global

    /// `size` bytes aligned to `alignment` from the main module's heap; 0
    /// when it can't.
    func allocate(size: Int, alignment: Int) throws -> UInt32
    /// The main module's memory size in bytes.
    var memoryByteCount: Int { get }
    func zeroMemory(at address: UInt32, count: Int) throws
    var tableCount: Int { get }
    /// Grows the table by `count` null slots; returns its count before.
    func growTable(by count: Int) throws -> Int
    /// Adds a slot holding `function`; returns its index.
    func appendToTable(_ function: Function) throws -> UInt32

    func mainFunction(named name: String) -> Function?
    func mainGlobal(named name: String) -> Global?
    func function(named name: String, in instance: Instance) -> Function?
    func global(named name: String, in instance: Instance) -> Global?
    /// An i32 global's value (a data symbol's address); nil for another type.
    func address(of global: Global) -> UInt32?

    /// Instantiates `module` with `bindings`, one per import, in the
    /// module's import order.
    func instantiate(_ module: Module, bindings: [(import: WasmImportDescriptor, binding: WasmLinkBinding<Function, Global>)]) throws -> Instance
    /// Calls a function of no arguments and no results.
    func call(_ function: Function) throws
    /// A side module was instantiated (its table slots filled), before its
    /// data relocations and constructors run.
    func didInstantiate(_ module: WasmSideModuleLinker<Self>.Loaded) throws
}

extension WasmLinkEngine {
    public func didInstantiate(_ module: WasmSideModuleLinker<Self>.Loaded) throws {}
}

/// Loads side modules into the main module an engine holds. Not
/// synchronized: drive it on the thread that drives the main module.
public final class WasmSideModuleLinker<Engine: WasmLinkEngine> {
    /// A side module once loaded: its instance and where it was placed.
    public struct Loaded {
        public let instance: Engine.Instance
        public let info: WasmDylinkInfo
        public let memoryBase: UInt32
        public let tableBase: UInt32
    }

    public let engine: Engine
    public private(set) var loaded: [Loaded] = []
    /// The table index given to each function a `GOT.func` entry named.
    private var functionSlots: [String: UInt32] = [:]

    public init(engine: Engine) {
        self.engine = engine
    }

    /// Places `module` (described by `description`), instantiates it, applies
    /// its data relocations and runs its constructors.
    @discardableResult
    public func load(_ module: Engine.Module, description: WasmSideModuleDescription) throws -> Loaded {
        let info = description.dylink

        // Its memory, zeroed (its .bss is in it, which no segment writes).
        var memoryBase: UInt32 = 0
        if info.memorySize > 0 {
            memoryBase = try engine.allocate(size: info.memorySize, alignment: 1 << info.memoryAlignment)
            guard memoryBase != 0 else { throw WasmLinkError.allocationFailed(size: info.memorySize) }
            let memorySize = engine.memoryByteCount
            guard Int(memoryBase) + info.memorySize <= memorySize else {
                throw WasmLinkError.allocationOutOfBounds(address: memoryBase, size: info.memorySize, memorySize: memorySize)
            }
            try engine.zeroMemory(at: memoryBase, count: info.memorySize)
        }

        // Its table slots, at the end of the table, aligned.
        let alignment = 1 << info.tableAlignment
        let count = engine.tableCount
        let padding = (alignment - count % alignment) % alignment
        guard count + padding + info.tableSize <= Int(UInt32.max) else {
            throw WasmLinkError.outOfRange("\(info.tableSize) table slots after \(count)")
        }
        let tableBase = UInt32(try engine.growTable(by: padding + info.tableSize) + padding)

        let bindings = try bind(description.imports, memoryBase: memoryBase, tableBase: tableBase)
        let instance = try engine.instantiate(module, bindings: bindings)
        let loadedModule = Loaded(instance: instance, info: info, memoryBase: memoryBase, tableBase: tableBase)
        loaded.append(loadedModule)
        try engine.didInstantiate(loadedModule)
        if let relocations = engine.function(named: "__wasm_apply_data_relocs", in: instance) {
            try engine.call(relocations)
        }
        if let constructors = engine.function(named: "__wasm_call_ctors", in: instance) {
            try engine.call(constructors)
        }
        return loadedModule
    }

    /// Each import's binding, or every import nothing binds.
    private func bind(_ imports: [WasmImportDescriptor], memoryBase: UInt32, tableBase: UInt32) throws
        -> [(import: WasmImportDescriptor, binding: WasmLinkBinding<Engine.Function, Engine.Global>)]
    {
        var bindings: [(import: WasmImportDescriptor, binding: WasmLinkBinding<Engine.Function, Engine.Global>)] = []
        var unresolved: [String] = []
        func expect(_ ok: Bool, _ item: WasmImportDescriptor) throws {
            guard ok else { throw WasmLinkError.wrongImportKind("\(item.module).\(item.name)") }
        }
        for item in imports {
            let binding: WasmLinkBinding<Engine.Function, Engine.Global>
            switch (item.module, item.name) {
            case ("env", "memory"):
                try expect(item.kind == .memory, item)
                binding = .memory
            case ("env", "__indirect_function_table"):
                try expect(item.kind == .table, item)
                binding = .table
            case ("env", "__stack_pointer"):
                try expect(item.isI32Global, item)
                binding = .stackPointer
            case ("env", "__memory_base"):
                try expect(item.isI32Global, item)
                binding = .constant(memoryBase)
            case ("env", "__table_base"):
                try expect(item.isI32Global, item)
                binding = .constant(tableBase)
            case ("GOT.mem", let name):
                try expect(item.isI32Global, item)
                guard let address = dataAddress(name) else { unresolved.append("GOT.mem.\(name)"); continue }
                binding = .got(address)
            case ("GOT.func", let name):
                try expect(item.isI32Global, item)
                guard let slot = try functionSlot(name) else { unresolved.append("GOT.func.\(name)"); continue }
                binding = .got(slot)
            case ("env", let name):
                switch item.kind {
                case .function:
                    guard let function = function(named: name) else { unresolved.append(name); continue }
                    binding = .function(function)
                case .global:
                    guard let global = global(named: name) else { unresolved.append(name); continue }
                    binding = .global(global)
                default:
                    unresolved.append(name)
                    continue
                }
            default:
                unresolved.append("\(item.module).\(item.name)")
                continue
            }
            bindings.append((item, binding))
        }
        guard unresolved.isEmpty else { throw WasmLinkError.unresolved(unresolved) }
        return bindings
    }

    // MARK: - Symbols

    /// A function the main module or a side module exports: the main
    /// module's first, then the side modules' in the order they were loaded.
    public func function(named name: String) -> Engine.Function? {
        if let function = engine.mainFunction(named: name) { return function }
        for module in loaded {
            if let function = engine.function(named: name, in: module.instance) { return function }
        }
        return nil
    }

    func global(named name: String) -> Engine.Global? {
        if let global = engine.mainGlobal(named: name) { return global }
        for module in loaded {
            if let global = engine.global(named: name, in: module.instance) { return global }
        }
        return nil
    }

    /// A data symbol's address: the value of the global its module exports
    /// for it (a side module's has its memory base added already, by its
    /// global relocations).
    func dataAddress(_ name: String) -> UInt32? {
        global(named: name).flatMap(engine.address(of:))
    }

    /// A function's index in the table: one slot added for it, the first
    /// time a GOT entry names it.
    func functionSlot(_ name: String) throws -> UInt32? {
        if let slot = functionSlots[name] { return slot }
        guard let function = function(named: name) else { return nil }
        let slot = try engine.appendToTable(function)
        functionSlots[name] = slot
        return slot
    }
}
