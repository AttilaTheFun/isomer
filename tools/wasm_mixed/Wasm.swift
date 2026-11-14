import Foundation

// Reading wasm binaries, with a clear error (not a crash, nor a silently
// truncated read) where the module is malformed.

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum FileIO {
    static func read(_ path: String) throws -> [UInt8] {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw ToolError("can't read \(path)")
        }
        return [UInt8](data)
    }

    static func write(_ path: String, _ bytes: [UInt8]) throws {
        do {
            try Data(bytes).write(to: URL(fileURLWithPath: path))
        } catch {
            throw ToolError("can't write \(path): \(error.localizedDescription)")
        }
    }

    static func write(_ path: String, _ text: String) throws {
        try write(path, Array(text.utf8))
    }
}

/// A position in a module's bytes, read forward.
struct WasmReader {
    let bytes: [UInt8]
    var position: Int

    init(_ bytes: [UInt8], at position: Int) {
        self.bytes = bytes
        self.position = position
    }

    var atEnd: Bool { position >= bytes.count }

    func peek() throws -> UInt8 {
        guard position >= 0, position < bytes.count else {
            throw ToolError("the module ends early (byte \(position) of \(bytes.count))")
        }
        return bytes[position]
    }

    mutating func byte() throws -> UInt8 {
        let b = try peek()
        position += 1
        return b
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= bytes.count else {
            throw ToolError("the module ends early (\(count) bytes at \(position) of \(bytes.count))")
        }
        position += count
    }

    /// The next count bytes.
    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        let start = position
        try skip(count)
        return bytes[start..<position]
    }

    /// An unsigned LEB128 (anything past 64 bits dropped: a valid module's are 32).
    mutating func uleb() throws -> Int {
        var r: UInt64 = 0
        var s: UInt64 = 0
        while true {
            let x = try byte()
            if s < 64 { r |= UInt64(x & 0x7F) &<< s }
            s += 7
            if x & 0x80 == 0 { return Int(truncatingIfNeeded: r) }
        }
    }

    /// A signed LEB128.
    mutating func sleb() throws -> Int {
        var r: Int64 = 0
        var s: Int64 = 0
        while true {
            let x = try byte()
            if s < 64 { r |= Int64(x & 0x7F) &<< s }
            s += 7
            if x & 0x80 == 0 {
                if x & 0x40 != 0 && s < 64 { r = r &- (Int64(1) &<< s) }
                return Int(r)
            }
        }
    }
}

enum Wasm {
    struct Section {
        let id: UInt8
        /// The body's bounds in the module's bytes.
        let start: Int
        let end: Int
    }

    static func encodeULEB(_ value: Int) -> [UInt8] {
        var n = UInt64(value)
        var out: [UInt8] = []
        while true {
            let x = UInt8(n & 0x7F)
            n >>= 7
            out.append(x | (n != 0 ? 0x80 : 0))
            if n == 0 { return out }
        }
    }

    static func sections(_ b: [UInt8]) throws -> [Section] {
        var r = WasmReader(b, at: 8)
        var out: [Section] = []
        while !r.atEnd {
            let id = try r.byte()
            let size = try r.uleb()
            let start = r.position
            guard size >= 0, start + size <= b.count else {
                throw ToolError("section \(id) at byte \(start) runs past the end of the module")
            }
            out.append(Section(id: id, start: start, end: start + size))
            r.position = start + size
        }
        return out
    }

    /// The name section's function names: index -> the name's UTF-8 (invalid
    /// UTF-8 replaced by U+FFFD, as Python's decode(errors='replace')).
    static func functionNames(_ b: [UInt8]) throws -> [Int: [UInt8]] {
        var names: [Int: [UInt8]] = [:]
        for section in try sections(b) where section.id == 0 {
            var r = WasmReader(b, at: section.start)
            let length = try r.uleb()
            guard try r.take(length).elementsEqual("name".utf8) else { continue }
            while r.position < section.end {
                let sub = try r.byte()
                let size = try r.uleb()
                let end = r.position + size
                if sub == 1 {
                    for _ in 0..<max(try r.uleb(), 0) {
                        let index = try r.uleb()
                        let length = try r.uleb()
                        names[index] = Array(String(decoding: try r.take(length), as: UTF8.self).utf8)
                    }
                }
                r.position = end
            }
        }
        return names
    }

    /// The active funcref element segments with i32.const offsets: (offset,
    /// function indices, nil for ref.null). Passive and declarative segments
    /// are an error, as they were in wasmtool.py.
    static func activeElements(_ b: [UInt8]) throws -> [(offset: Int, functions: [Int?])] {
        var out: [(offset: Int, functions: [Int?])] = []
        for section in try sections(b) where section.id == 9 {
            var r = WasmReader(b, at: section.start)
            for _ in 0..<max(try r.uleb(), 0) {
                let flags = try r.uleb()
                switch flags {
                case 0, 2:
                    if flags == 2 { _ = try r.uleb() }
                    let offset = try constantOffset(&r)
                    if flags == 2 {
                        guard try r.peek() == 0 else { throw ToolError("element segment's kind is not funcref") }
                        r.position += 1
                    }
                    var functions: [Int?] = []
                    for _ in 0..<max(try r.uleb(), 0) { functions.append(try r.uleb()) }
                    out.append((offset, functions))
                case 4, 6:
                    if flags == 6 { _ = try r.uleb() }
                    let offset = try constantOffset(&r)
                    if flags == 6 { r.position += 1 }  // the reference type
                    var functions: [Int?] = []
                    for _ in 0..<max(try r.uleb(), 0) {
                        let op = try r.byte()
                        if op == 0xD2 {
                            functions.append(try r.uleb())
                        } else if op == 0xD0 {
                            r.position += 1
                            functions.append(nil)
                        } else {
                            throw ToolError("elem expression \(hex(op))")
                        }
                        guard try r.peek() == 0x0B else { throw ToolError("element expression is not one instruction") }
                        r.position += 1
                    }
                    out.append((offset, functions))
                default:
                    throw ToolError("elem flags \(flags) not handled")
                }
            }
        }
        return out
    }

    /// An element segment's offset: i32.const n, end.
    private static func constantOffset(_ r: inout WasmReader) throws -> Int {
        guard try r.byte() == 0x41 else { throw ToolError("elem offset not i32.const") }
        let offset = try r.sleb()
        guard try r.peek() == 0x0B else { throw ToolError("elem offset is not one instruction") }
        r.position += 1
        return offset
    }

    /// The first table's minimum size, or nil without a table section.
    static func tableMinimum(_ b: [UInt8]) throws -> Int? {
        for section in try sections(b) where section.id == 4 {
            var r = WasmReader(b, at: section.start)
            _ = try r.uleb()  // the table count
            r.position += 1  // the reference type
            _ = try r.uleb()  // the limits' flags
            return try r.uleb()
        }
        return nil
    }

    /// Python's f'{op:#x}'.
    static func hex(_ value: UInt8) -> String { "0x" + String(value, radix: 16) }
}
