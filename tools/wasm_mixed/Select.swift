// Which of the runtime's functions go native, as wasm-split names them: the
// native set's functions, every function no bigger than `maxSize` bytes of
// code, and every Swift function of the named modules (`modules`): one whose
// mangled name has the module in it, which takes in its closures, its
// witnesses and the standard library's generics specialized for it; `C` in
// `modules` names every function that isn't Swift's. With `closure`, every
// function a chosen function (or an entry point) calls directly goes native
// too, and so on down: interpreted code never calls native code, so one
// interpreted function on the way down (a standard library generic
// specialized for the runtime: `MainActor.assumeIsolated` under every entry
// point) leaves everything beneath it interpreted.
//
// A runtime has many functions under one name (compiler-made helpers: 140
// `.L__unnamed_6`, outlined copies, existential projections, merged `…Tm`
// thunks), which Binaryen tells apart as `<name>_<function index>`. Indices
// change with every build of the runtime, so a set naming one copy that way
// names another copy, or none, in the next build. A set's name here therefore
// means every function by that name (and `<name>_<digits>` that isn't a
// function of the runtime means `<name>`'s): the set survives rebuilds of the
// runtime, at the cost of a few copies more.
//
// Small functions by size, because crossing from native code into the
// interpreter costs far more than a small function's own work, whichever
// feature runs: in a played 2048 game, functions of at most 128 bytes took
// 99% of native code's calls into the interpreter.

enum Select {
    struct Result {
        var names: [String]
        var fromSet = 0
        var bySize = 0
        var byModule = 0
        var byClosure = 0
        var bytes = 0
        var absent: [String] = []
    }

    static func run(runtime b: [UInt8], set: [String], maxSize: Int, modules: [String] = [],
                    closure: Bool = false, entries: Set<[UInt8]> = []) throws -> Result {
        let names = try Wasm.functionNames(b)
        let (imported, sizes) = try definedFunctionSizes(b)

        var byName: [[UInt8]: [Int]] = [:]
        for (index, name) in names.sorted(by: { $0.key < $1.key }) { byName[name, default: []].append(index) }

        var chosen: Set<Int> = []
        var result = Result(names: [])
        for line in set {
            let entry = line.trimmingCharacters(in: .whitespaces)
            if entry.isEmpty { continue }
            var copies = byName[Array(entry.utf8)]
            if copies == nil, let base = indexedBase(entry) { copies = byName[Array(base.utf8)] }
            guard let copies else { result.absent.append(entry); continue }
            for index in copies where index >= imported && chosen.insert(index).inserted { result.fromSet += 1 }
        }
        if maxSize > 0 {
            for (k, size) in sizes.enumerated() where size <= maxSize && names[imported + k] != nil {
                if chosen.insert(imported + k).inserted { result.bySize += 1 }
            }
        }

        // A module's name in a mangling: its length, then the name.
        // `C`: every function that isn't Swift's (the Swift runtime's C++,
        // the C library, the allocator).
        let withC = modules.contains("C")
        let tokens = modules.filter { !$0.isEmpty && $0 != "C" }.map { Array("\($0.utf8.count)\($0)".utf8) }
        if !tokens.isEmpty || withC {
            for k in 0..<sizes.count {
                guard let name = names[imported + k] else { continue }
                let swift = name.starts(with: Array("$s".utf8))
                let take = swift ? tokens.contains(where: { contains(name, $0) }) : withC
                if take, chosen.insert(imported + k).inserted { result.byModule += 1 }
            }
        }

        if closure {
            let (imported2, bodies) = try functionBodies(b)
            precondition(imported2 == imported)
            var frontier = chosen
            for (name, index) in try exportedFunctions(b) where entries.contains(name) && index >= imported {
                if chosen.insert(index).inserted { result.byClosure += 1 }
                frontier.insert(index)
            }
            while !frontier.isEmpty {
                var next: Set<Int> = []
                for f in frontier {
                    for callee in try directCalls(b, bodies[f - imported]) where callee >= imported {
                        if chosen.insert(callee).inserted {
                            result.byClosure += 1
                            next.insert(callee)
                        }
                    }
                }
                frontier = next
            }
        }

        // wasm-split's names: the first function by a name keeps it, the
        // others are `<name>_<index>` (MapSlots reads them back so).
        for index in chosen.sorted() {
            guard let name = names[index], let first = byName[name]?.first else { continue }
            let text = String(decoding: name, as: UTF8.self)
            result.names.append(first == index ? text : "\(text)_\(index)")
            result.bytes += sizes[index - imported]
        }
        return result
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], haystack[i..<(i + needle.count)].elementsEqual(needle) { return true }
            i += 1
        }
        return false
    }

    /// The exported functions: name -> function index.
    static func exportedFunctions(_ b: [UInt8]) throws -> [([UInt8], Int)] {
        var out: [([UInt8], Int)] = []
        for section in try Wasm.sections(b) where section.id == 7 {
            var r = WasmReader(b, at: section.start)
            for _ in 0..<(try r.uleb()) {
                let name = Array(try r.take(try r.uleb()))
                let kind = try r.byte()
                let index = try r.uleb()
                if kind == 0 { out.append((name, index)) }
            }
        }
        return out
    }

    /// Each defined function's body: (start, end) in `b`.
    static func functionBodies(_ b: [UInt8]) throws -> (imported: Int, bodies: [(Int, Int)]) {
        let (imported, _) = try definedFunctionSizes(b)
        var bodies: [(Int, Int)] = []
        for section in try Wasm.sections(b) where section.id == 10 {
            var r = WasmReader(b, at: section.start)
            for _ in 0..<(try r.uleb()) {
                let size = try r.uleb()
                bodies.append((r.position, r.position + size))
                try r.skip(size)
            }
        }
        return (imported, bodies)
    }

    /// The functions a body calls directly (`call`, `return_call`).
    static func directCalls(_ b: [UInt8], _ body: (Int, Int)) throws -> [Int] {
        var r = WasmReader(b, at: body.0)
        for _ in 0..<(try r.uleb()) {
            _ = try r.uleb()
            _ = try r.byte()
        }
        var out: [Int] = []
        while r.position < body.1 {
            let op = try r.byte()
            switch op {
            case 0x02, 0x03, 0x04:
                let t = try r.peek()
                if t == 0x40 || t >= 0x6F { _ = try r.byte() } else { _ = try r.sleb() }
            case 0x0C, 0x0D, 0x20...0x26, 0xD2:
                _ = try r.uleb()
            case 0x0E:
                for _ in 0...(try r.uleb()) { _ = try r.uleb() }
            case 0x10, 0x12:
                out.append(try r.uleb())
            case 0x11, 0x13:
                _ = try r.uleb()
                _ = try r.uleb()
            case 0x1C:
                try r.skip(try r.uleb())
            case 0x28...0x3E:
                _ = try r.uleb()
                _ = try r.uleb()
            case 0x3F, 0x40, 0xD0:
                _ = try r.byte()
            case 0x41, 0x42:
                _ = try r.sleb()
            case 0x43:
                try r.skip(4)
            case 0x44:
                try r.skip(8)
            case 0xFC:
                switch try r.uleb() {
                case 8:
                    _ = try r.uleb()
                    _ = try r.byte()
                case 9, 13, 15, 16, 17:
                    _ = try r.uleb()
                case 10:
                    try r.skip(2)
                case 11:
                    try r.skip(1)
                case 12, 14:
                    _ = try r.uleb()
                    _ = try r.uleb()
                default:
                    break
                }
            case 0xFE:
                if try r.uleb() == 3 {
                    _ = try r.byte()
                } else {
                    _ = try r.uleb()
                    _ = try r.uleb()
                }
            case 0xFD:
                // SIMD: the runtime has none; a function with it is left
                // where the closure found it.
                return out
            default:
                break
            }
        }
        return out
    }

    /// `<name>` of `<name>_<digits>`.
    static func indexedBase(_ name: String) -> String? {
        guard let underscore = name.lastIndex(of: "_") else { return nil }
        let digits = name[name.index(after: underscore)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(name[..<underscore])
    }

    /// The number of imported functions, and each defined function's body
    /// size in bytes.
    static func definedFunctionSizes(_ b: [UInt8]) throws -> (imported: Int, sizes: [Int]) {
        var imported = 0
        var sizes: [Int] = []
        for section in try Wasm.sections(b) {
            var r = WasmReader(b, at: section.start)
            if section.id == 2 {
                for _ in 0..<(try r.uleb()) {
                    try r.skip(try r.uleb())
                    try r.skip(try r.uleb())
                    switch try r.byte() {
                    case 0:
                        _ = try r.uleb()
                        imported += 1
                    case 1:
                        _ = try r.byte()
                        try limits(&r)
                    case 2:
                        try limits(&r)
                    case 3:
                        try r.skip(2)
                    case 4:
                        _ = try r.byte()
                        _ = try r.uleb()
                    case let kind:
                        throw ToolError("import kind \(kind) unknown")
                    }
                }
            } else if section.id == 10 {
                for _ in 0..<(try r.uleb()) {
                    let size = try r.uleb()
                    sizes.append(size)
                    try r.skip(size)
                }
            }
        }
        return (imported, sizes)
    }

    private static func limits(_ r: inout WasmReader) throws {
        let flags = try r.uleb()
        _ = try r.uleb()
        if flags & 1 != 0 { _ = try r.uleb() }
    }
}
