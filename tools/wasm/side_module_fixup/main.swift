// side_module_fixup: corrects a side module that wasm-ld linked with Swift's
// relative pointers in it (R_WASM_MEMORY_ADDR_LOCREL_I32), for a wasm-ld
// without tools/patches/lld_wasm_pic_locrel.patch (Swift 6.4.2's).
//
// A relative pointer between two places in one module holds wherever the
// module is loaded, and wasm-ld writes its value into the data at link time.
// In a shared library (`--experimental-pic -shared`) it also emits a runtime
// relocation for it in `__wasm_apply_data_relocs`, which adds `__memory_base`
// to the value: Swift's conformance records and type descriptors then point
// outside memory, and the runtime's first conformance scan traps. This tool
// removes those stores, leaving the link-time values: what the patched
// wasm-ld writes.
//
//   side_module_fixup --map <wasm-ld -Map output> --out <fixed.wasm> \
//       <side module.wasm> <the archives and objects it was linked from>...
//
// Which stores: the inputs' `reloc.DATA` sections name each LOCREL site by
// its data segment and offset; the link map says where each input segment
// went. A store in `__wasm_apply_data_relocs` whose address is one of those
// sites goes. Anything the tool doesn't recognise there (an instruction
// outside the address-and-value pattern wasm-ld writes) is an error, not a
// guess. Every site must match one: the side module must be linked with
// `--no-gc-sections`, since the tool tells same-named segments apart by
// their order, which dead-stripping shifts. (`wasm-ld --emit-relocs` would
// name the sites directly, but it crashes on inputs the size of Isomer's
// runtime.)

import Foundation

struct FixupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Reading

struct Reader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    init(_ bytes: [UInt8], _ start: Int = 0, _ end: Int? = nil) {
        self.bytes = bytes
        position = start
        self.end = end ?? bytes.count
    }

    var atEnd: Bool { position >= end }

    mutating func byte() throws -> UInt8 {
        guard position < end else { throw FixupError("truncated at \(position)") }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func uleb() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7f) << shift
            if b & 0x80 == 0 { return result }
            shift += 7
            guard shift < 64 else { throw FixupError("LEB128 too long at \(position)") }
        }
    }

    mutating func sleb() throws -> Int64 {
        var result: Int64 = 0
        var shift: Int64 = 0
        var b: UInt8
        repeat {
            b = try byte()
            result |= Int64(b & 0x7f) << shift
            shift += 7
            guard shift < 71 else { throw FixupError("LEB128 too long at \(position)") }
        } while b & 0x80 != 0
        if shift < 64 && b & 0x40 != 0 { result |= -1 << shift }
        return result
    }

    mutating func count() throws -> Int {
        let value = try uleb()
        guard value <= UInt64(end - position) || value <= 1 << 31 else { throw FixupError("count out of range") }
        return Int(value)
    }

    mutating func name() throws -> String {
        let length = try count()
        guard length <= end - position else { throw FixupError("name past the end") }
        defer { position += length }
        return String(decoding: bytes[position..<(position + length)], as: UTF8.self)
    }
}

struct Section {
    let id: UInt8
    /// Where its id byte is, where its contents start and end.
    let header: Int
    let start: Int
    let end: Int
}

func sections(_ bytes: [UInt8]) throws -> [Section] {
    guard bytes.count >= 8, bytes[0..<4].elementsEqual([0x00, 0x61, 0x73, 0x6d]) else { throw FixupError("not a WebAssembly binary") }
    var reader = Reader(bytes, 8)
    var out: [Section] = []
    while !reader.atEnd {
        let header = reader.position
        let id = try reader.byte()
        let size = try reader.count()
        let start = reader.position
        guard size <= bytes.count - start else { throw FixupError("section past the end") }
        reader.position = start + size
        out.append(Section(id: id, header: header, start: start, end: start + size))
    }
    return out
}

func uleb(_ value: UInt64) -> [UInt8] {
    var value = value
    var out: [UInt8] = []
    repeat {
        var b = UInt8(value & 0x7f)
        value >>= 7
        if value != 0 { b |= 0x80 }
        out.append(b)
    } while value != 0
    return out
}

// MARK: - Archives

/// An archive's members (`ar`: GNU's long-name table and BSD's `#1/n`
/// names both), or the file itself when it's an object.
func members(of path: String) throws -> [(label: String, bytes: [UInt8])] {
    let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
    guard bytes.starts(with: Array("!<arch>\n".utf8)) else { return [(path, bytes)] }
    var out: [(String, [UInt8])] = []
    var position = 8
    var longNames: [UInt8] = []
    func field(_ start: Int, _ length: Int) -> String {
        String(decoding: bytes[start..<(start + length)], as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
    while position + 60 <= bytes.count {
        var name = field(position, 16)
        guard let size = Int(field(position + 48, 10)) else { throw FixupError("\(path): an archive member with no size") }
        var start = position + 60
        var length = size
        guard start + size <= bytes.count else { throw FixupError("\(path): a member past the end") }
        if name.hasPrefix("#1/"), let nameLength = Int(name.dropFirst(3)) {
            // BSD: the name follows the header.
            name = String(decoding: bytes[start..<(start + nameLength)], as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            start += nameLength
            length -= nameLength
        } else if name == "//" {
            longNames = Array(bytes[start..<(start + size)])
            name = ""
        } else if name.hasPrefix("/"), let offset = Int(name.dropFirst()) {
            // GNU: an offset into the long-name table, the name ending "/\n".
            guard offset < longNames.count else { throw FixupError("\(path): a long name past the table") }
            let tail = longNames[offset...]
            let stop = tail.firstIndex(of: 0x0a) ?? longNames.endIndex
            name = String(decoding: longNames[offset..<stop], as: UTF8.self)
            if name.hasSuffix("/") { name.removeLast() }
        } else if name.hasSuffix("/") {
            name.removeLast()
        }
        let skip = name.isEmpty || name == "/" || name.hasPrefix("__.SYMDEF") || name == "/SYM64"
        if !skip, bytes[start..<min(start + 4, bytes.count)].elementsEqual([0x00, 0x61, 0x73, 0x6d]) {
            out.append(("\(path)(\(name))", Array(bytes[start..<(start + length)])))
        }
        position += 60 + size + (size % 2)
    }
    return out
}

// MARK: - Objects

/// A LOCREL site in an input object: its data segment's name, which of the
/// object's segments of that name it is, and its offset in the segment.
struct Site: Hashable {
    let segment: String
    let rank: Int
    let offset: Int
}

let addendTypes: Set<UInt8> = [3, 4, 5, 8, 9, 11, 14, 15, 16, 17, 21, 23, 24, 25]
let locrelI32: UInt8 = 23

func locrelSites(inObject bytes: [UInt8]) throws -> [Site] {
    let all = try sections(bytes)
    guard let dataIndex = all.firstIndex(where: { $0.id == 11 }) else { return [] }
    let data = all[dataIndex]
    var segmentNames: [String] = []
    var relocations: (start: Int, end: Int)?
    for section in all where section.id == 0 {
        var reader = Reader(bytes, section.start, section.end)
        let name = try reader.name()
        if name == "linking" {
            _ = try reader.uleb()  // version
            while !reader.atEnd {
                let kind = try reader.byte()
                let size = try reader.count()
                let end = reader.position + size
                if kind == 5 {  // WASM_SEGMENT_INFO
                    for _ in 0..<(try reader.count()) {
                        segmentNames.append(try reader.name())
                        _ = try reader.uleb()  // alignment
                        _ = try reader.uleb()  // flags
                    }
                }
                reader.position = end
            }
        } else if name.hasPrefix("reloc.") {
            if try Int(reader.uleb()) == dataIndex { relocations = (reader.position, section.end) }
        }
    }
    guard let relocations else { return [] }

    // The data segments: where each one's bytes are in the section.
    var segments: [(offset: Int, size: Int)] = []
    var reader = Reader(bytes, data.start, data.end)
    for _ in 0..<(try reader.count()) {
        let flags = try reader.uleb()
        if flags == 2 { _ = try reader.uleb() }
        if flags != 1 {
            while try reader.byte() != 0x0b {
                switch bytes[reader.position - 1] {
                case 0x41: _ = try reader.sleb()
                case 0x42: _ = try reader.sleb()
                case 0x23: _ = try reader.uleb()
                default: throw FixupError("an unexpected instruction in a data segment's offset")
                }
            }
        }
        let size = try reader.count()
        segments.append((reader.position - data.start, size))
        reader.position += size
    }
    guard segmentNames.count == segments.count else { throw FixupError("\(segments.count) data segments but \(segmentNames.count) names") }

    var sites: [Site] = []
    var relocs = Reader(bytes, relocations.start, relocations.end)
    for _ in 0..<(try relocs.count()) {
        let type = try relocs.byte()
        let offset = Int(try relocs.uleb())
        _ = try relocs.uleb()  // the symbol
        if addendTypes.contains(type) { _ = try relocs.sleb() }
        guard type == locrelI32 else { continue }
        guard let k = segments.firstIndex(where: { $0.offset <= offset && offset < $0.offset + $0.size }) else {
            throw FixupError("a LOCREL relocation outside every data segment")
        }
        let rank = segmentNames[..<k].filter { $0 == segmentNames[k] }.count
        sites.append(Site(segment: segmentNames[k], rank: rank, offset: offset - segments[k].offset))
    }
    return sites
}

// MARK: - The map

/// Where each input's data segments went: `(input, segment name)` → the
/// addresses (relative to the module's memory base) of its segments of that
/// name, in order. wasm-ld's map lists them under the output's DATA section
/// as `<address> <lma> <size>  <input>:(<segment>)`.
func placements(map: String) throws -> [String: [String: [Int]]] {
    var out: [String: [String: [Int]]] = [:]
    var inData = false
    let line = try NSRegularExpression(pattern: #"^\s*([0-9a-f]+)\s+[0-9a-f]+\s+[0-9a-f]+\s+(.*):\((.*)\)\s*$"#)
    for text in map.split(separator: "\n", omittingEmptySubsequences: false) {
        let s = String(text)
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(" DATA") || trimmed == "DATA" { inData = true; continue }
        if inData, s.range(of: #"^\s+-\s"#, options: .regularExpression) != nil { inData = false }
        guard inData, let match = line.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { continue }
        let address = Int(s[Range(match.range(at: 1), in: s)!], radix: 16)!
        let input = String(s[Range(match.range(at: 2), in: s)!])
        let segment = String(s[Range(match.range(at: 3), in: s)!])
        out[input, default: [:]][segment, default: []].append(address)
    }
    return out
}

// MARK: - __wasm_apply_data_relocs

/// The module with the stores to `sites` (offsets from the memory base)
/// removed from `__wasm_apply_data_relocs`; and how many it removed.
func removingStores(to sites: Set<Int>, in bytes: [UInt8]) throws -> (bytes: [UInt8], removed: Int, kept: Int) {
    let all = try sections(bytes)
    var importedFunctions = 0
    if let imports = all.first(where: { $0.id == 2 }) {
        var r = Reader(bytes, imports.start, imports.end)
        for _ in 0..<(try r.count()) {
            _ = try r.name()
            _ = try r.name()
            switch try r.byte() {
            case 0: importedFunctions += 1; _ = try r.uleb()
            case 1: _ = try r.byte(); let f = try r.byte(); _ = try r.uleb(); if f & 1 != 0 { _ = try r.uleb() }
            case 2: let f = try r.byte(); _ = try r.uleb(); if f & 1 != 0 { _ = try r.uleb() }
            case 3: _ = try r.byte(); _ = try r.byte()
            case 4: _ = try r.byte(); _ = try r.uleb()
            default: throw FixupError("an import of unknown kind")
            }
        }
    }
    var target: Int?
    if let exports = all.first(where: { $0.id == 7 }) {
        var r = Reader(bytes, exports.start, exports.end)
        for _ in 0..<(try r.count()) {
            let name = try r.name()
            let kind = try r.byte()
            let index = Int(try r.uleb())
            if name == "__wasm_apply_data_relocs", kind == 0 { target = index }
        }
    }
    guard let target else { return (bytes, 0, 0) }
    guard target >= importedFunctions, let code = all.first(where: { $0.id == 10 }) else {
        throw FixupError("__wasm_apply_data_relocs isn't a function the module defines")
    }

    var r = Reader(bytes, code.start, code.end)
    let functionCount = try r.count()
    let entriesStart = r.position
    var bodyStart = 0, bodyEnd = 0
    for k in 0..<functionCount {
        let size = try r.count()
        if k == target - importedFunctions { bodyStart = r.position; bodyEnd = r.position + size }
        r.position += size
    }
    guard bodyEnd > 0 else { throw FixupError("no body for __wasm_apply_data_relocs") }

    // Its locals, then statements: an address (global.get base, i32.const
    // offset, i32.add), a value, a store.
    var body = Reader(bytes, bodyStart, bodyEnd)
    for _ in 0..<(try body.count()) { _ = try body.uleb(); _ = try body.byte() }
    var out = Array(bytes[bodyStart..<body.position])
    var removed = 0, kept = 0
    while true {
        let statementStart = body.position
        let first = try body.byte()
        if first == 0x0b {
            guard body.position == bodyEnd else { throw FixupError("code after __wasm_apply_data_relocs' end") }
            out.append(0x0b)
            break
        }
        // The address: the offset and the base, in either order (Swift
        // 6.4.2's wasm-ld puts the offset first).
        let site: Int
        switch first {
        case 0x41:
            site = Int(try body.sleb())
            guard try body.byte() == 0x23 else { throw FixupError("an address without its base") }
            _ = try body.uleb()
        case 0x23:
            _ = try body.uleb()
            guard try body.byte() == 0x41 else { throw FixupError("an address without its offset") }
            site = Int(try body.sleb())
        default:
            throw FixupError(String(format: "a statement starting with opcode 0x%02x", first))
        }
        guard try body.byte() == 0x6a else { throw FixupError("an address without its add") }
        // The value, up to the store.
        while true {
            let op = try body.byte()
            switch op {
            case 0x23: _ = try body.uleb()
            case 0x41, 0x42: _ = try body.sleb()
            case 0x6a, 0x7c: break
            case 0x36, 0x37:
                _ = try body.uleb()  // alignment
                _ = try body.uleb()  // offset
            default:
                throw FixupError(String(format: "opcode 0x%02x in a relocation's value", op))
            }
            if op == 0x36 || op == 0x37 { break }
        }
        if sites.contains(site) {
            removed += 1
        } else {
            out += bytes[statementStart..<body.position]
            kept += 1
        }
    }

    // The function's new size; the code section's.
    var entries: [UInt8] = []
    r = Reader(bytes, entriesStart, code.end)
    for k in 0..<functionCount {
        let size = try r.count()
        if k == target - importedFunctions {
            entries += uleb(UInt64(out.count)) + out
        } else {
            entries += uleb(UInt64(size)) + bytes[r.position..<(r.position + size)]
        }
        r.position += size
    }
    let contents = uleb(UInt64(functionCount)) + entries
    let rewritten = Array(bytes[..<code.header]) + [10] + uleb(UInt64(contents.count)) + contents + Array(bytes[code.end...])
    return (rewritten, removed, kept)
}

// MARK: - Main

func run() throws {
    var arguments = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) throws -> String {
        guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { throw FixupError("missing \(name)") }
        defer { arguments.removeSubrange(i...(i + 1)) }
        return arguments[i + 1]
    }
    let mapPath = try option("--map")
    let outPath = try option("--out")
    guard let input = arguments.first else {
        throw FixupError("usage: side_module_fixup --map <map> --out <fixed.wasm> <side module.wasm> <archives and objects>...")
    }
    let placed = try placements(map: String(decoding: try Data(contentsOf: URL(fileURLWithPath: mapPath)), as: UTF8.self))

    var targets = Set<Int>()
    var unplaced = 0
    for path in arguments.dropFirst() {
        for member in try members(of: path) {
            for site in try locrelSites(inObject: member.bytes) {
                if let addresses = placed[member.label]?[site.segment], site.rank < addresses.count {
                    targets.insert(addresses[site.rank] + site.offset)
                } else {
                    unplaced += 1
                }
            }
        }
    }
    let module = Array(try Data(contentsOf: URL(fileURLWithPath: input)))
    let (fixed, removed, kept) = try removingStores(to: targets, in: module)
    try Data(fixed).write(to: URL(fileURLWithPath: outPath))
    FileHandle.standardError.write(Data(
        "side_module_fixup: removed the runtime relocations of \(removed) LOCREL sites, kept \(kept) others\n".utf8))
    // Every site must be accounted for: a site the map doesn't place, or
    // one with no runtime relocation, means the placement is wrong (a link
    // with --gc-sections drops segments, shifting the rest), the map is
    // another link's, or this wasm-ld is already fixed.
    if unplaced > 0 || removed != targets.count {
        throw FixupError("\(unplaced) LOCREL sites unplaced and \(targets.count - removed) without a runtime relocation (link with --no-gc-sections)")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("side_module_fixup: \(error)\n".utf8))
    exit(1)
}
