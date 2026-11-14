// What the dynamic linker reads of a WebAssembly binary itself, for engines
// that don't expose it (or to check what an engine reports): the sections,
// a custom section by name, the imports. Bounds-checked throughout: a
// truncated or malformed binary is an error, never a crash.

/// A read past the end of the bytes, or a value out of its range.
public struct WasmBinaryError: Error, Equatable, CustomStringConvertible, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// A cursor over bytes: LEB128 integers, names, slices.
struct WasmByteReader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(_ bytes: [UInt8], from start: Int = 0, to end: Int? = nil) {
        self.bytes = bytes
        position = start
        self.end = end ?? bytes.count
    }

    var atEnd: Bool { position >= end }

    mutating func byte() throws -> UInt8 {
        guard position < end else { throw WasmBinaryError("truncated") }
        defer { position += 1 }
        return bytes[position]
    }

    /// An unsigned LEB128 of at most 32 bits (what wasm's sizes, counts and
    /// indices are).
    mutating func u32() throws -> UInt32 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try byte()
            result |= UInt64(byte & 0x7f) << shift
            guard result <= UInt64(UInt32.max) else { throw WasmBinaryError("LEB128 out of range") }
            if byte & 0x80 == 0 { return UInt32(result) }
            shift += 7
            guard shift < 35 else { throw WasmBinaryError("LEB128 too long") }
        }
    }

    /// A u32 the reader will index or count with.
    mutating func count() throws -> Int { Int(try u32()) }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, count <= end - position else { throw WasmBinaryError("truncated") }
        position += count
    }

    mutating func slice(_ count: Int) throws -> ArraySlice<UInt8> {
        let start = position
        try skip(count)
        return bytes[start..<position]
    }

    mutating func name() throws -> String {
        String(decoding: try slice(try count()), as: UTF8.self)
    }

    /// A limits pair (tables, memories): flags, minimum, maybe maximum.
    mutating func skipLimits() throws {
        let flags = try byte()
        _ = try u32()
        if flags & 1 != 0 { _ = try u32() }
    }
}

/// A section of a module: its id and where its contents are.
struct WasmSection {
    let id: UInt8
    let start: Int
    let end: Int
}

enum WasmBinary {
    static func sections(_ bytes: [UInt8]) throws -> [WasmSection] {
        guard bytes.count >= 8, bytes[0..<4].elementsEqual([0x00, 0x61, 0x73, 0x6d]) else {
            throw WasmBinaryError("not a WebAssembly binary")
        }
        guard bytes[4..<8].elementsEqual([0x01, 0x00, 0x00, 0x00]) else {
            throw WasmBinaryError("not WebAssembly version 1")
        }
        var reader = WasmByteReader(bytes, from: 8)
        var sections: [WasmSection] = []
        while !reader.atEnd {
            let id = try reader.byte()
            let size = try reader.count()
            let start = reader.position
            try reader.skip(size)
            sections.append(WasmSection(id: id, start: start, end: reader.position))
        }
        return sections
    }

    /// The contents of the first custom section named `name`, if any.
    static func customSection(_ bytes: [UInt8], named name: String) throws -> [UInt8]? {
        for section in try sections(bytes) where section.id == 0 {
            var reader = WasmByteReader(bytes, from: section.start, to: section.end)
            if try reader.name() == name { return Array(bytes[reader.position..<section.end]) }
        }
        return nil
    }

    /// The import section's entries.
    static func imports(_ bytes: [UInt8]) throws -> [WasmImportDescriptor] {
        guard let section = try sections(bytes).first(where: { $0.id == 2 }) else { return [] }
        var reader = WasmByteReader(bytes, from: section.start, to: section.end)
        var imports: [WasmImportDescriptor] = []
        for _ in 0..<(try reader.count()) {
            let module = try reader.name()
            let name = try reader.name()
            let kind: WasmImportDescriptor.Kind
            switch try reader.byte() {
            case 0:
                kind = .function(typeIndex: try reader.u32())
            case 1:
                _ = try reader.byte()  // the reference type
                try reader.skipLimits()
                kind = .table
            case 2:
                try reader.skipLimits()
                kind = .memory
            case 3:
                let valueType = try reader.byte()
                let mutable = try reader.byte()
                guard mutable <= 1 else { throw WasmBinaryError("a global's mutability is \(mutable)") }
                kind = .global(valueType: valueType, mutable: mutable == 1)
            case 4:
                _ = try reader.byte()  // the tag's attribute
                _ = try reader.u32()
                kind = .tag
            case let other:
                throw WasmBinaryError("an import of unknown kind \(other)")
            }
            imports.append(WasmImportDescriptor(module: module, name: name, kind: kind))
        }
        return imports
    }
}

/// One import of a module, as the linker needs to know it.
public struct WasmImportDescriptor: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case function(typeIndex: UInt32)
        case table
        case memory
        /// `valueType` is the binary's type byte (0x7f is i32).
        case global(valueType: UInt8, mutable: Bool)
        case tag
    }

    public var module: String
    public var name: String
    public var kind: Kind

    public init(module: String, name: String, kind: Kind) {
        self.module = module
        self.name = name
        self.kind = kind
    }

    var isFunction: Bool { if case .function = kind { return true } else { return false } }
    var isI32Global: Bool { if case .global(0x7f, _) = kind { return true } else { return false } }
}
