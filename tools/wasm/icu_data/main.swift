// Writes a wasm object holding a module's ICU data, less what it is told to drop.
//
//     icu_data <module.wasm> <out.o> [locales=en,fr,…] <pattern>...
//
// The full Foundation links ICU with all of its data (`icudt<N>_dat`, 34 MB in
// Visor's reactor: every locale, every legacy character set). Read from a
// module linked with every symbol exported (whose exports give the data's
// address and the next symbol's), the package's items whose names match a
// pattern (fnmatch, against the name without the package's own prefix:
// `*.cnv`, `brkitr/*.dict`) are left out, and the rest is written as a
// relocatable wasm object defining the same symbol. Linked ahead of the SDK's
// ICU archive (whole, so it is loaded first), it is the data the program
// finds; the archive's member holding the original is then never loaded. A
// module without ICU gets an object defining nothing.
//
// The package is ICU's common data format ("CmnD"): a header, a table of
// contents (a count, then for each item the offsets of its name and its data,
// both from the table's start), the names, then the items, each at a 16-byte
// boundary. ICU finds items by a binary search of the names, which stay in
// their order.
//
// `locales=en,fr` keeps the locale data of those languages only (every
// region and script of each: `fr_CA`, `zh_Hant`), with `root` and the
// indexes: a locale left out formats as its nearest kept parent does, root's
// when there is none. Items that are not a locale's (supplemental data,
// time zones, units' definitions) all stay.
//
// It was icu_data.py until 0.54, and writes what that wrote, byte for byte.
import Foundation
import WasmToolSupport

func fail(_ message: String) -> Never { WasmToolSupport.fail("icu_data", message) }

/// An unsigned LEB128 at `i`, and the index after it.
func leb(_ data: [UInt8], _ start: Int) -> (Int, Int) {
    var result = 0, shift = 0, i = start
    while true {
        let byte = data[i]
        i += 1
        // Bits past 64 (an i64.const's, read only to be skipped) are dropped.
        if shift < 64 { result |= Int(byte & 0x7F) &<< shift }
        shift += 7
        if byte < 0x80 { return (result, i) }
    }
}

func uleb(_ value: Int) -> [UInt8] {
    var value = value, out: [UInt8] = []
    while true {
        let byte = UInt8(value & 0x7F)
        value >>= 7
        if value != 0 {
            out.append(byte | 0x80)
        } else {
            out.append(byte)
            return out
        }
    }
}

/// The module's exported globals' addresses (by name; nil for a global whose
/// initializer is not an i32.const) and its memory as its data segments lay
/// it out.
func readModule(_ data: [UInt8]) -> (exports: [(String, Int?)], memory: [UInt8]) {
    guard data.count >= 4, data[0..<4].elementsEqual([0, 0x61, 0x73, 0x6D]) else { fail("not a wasm module") }
    var importedGlobals = 0
    var globals: [Int?] = []
    var exports: [(String, Int?)] = []
    var memory: [UInt8] = []
    var i = 8
    while i < data.count {
        let section = data[i]
        var size: Int
        (size, i) = leb(data, i + 1)
        let end = i + size
        switch section {
        case 2:  // imports: count the globals, which come first
            var count: Int
            (count, i) = leb(data, i)
            for _ in 0..<count {
                for _ in 0..<2 {
                    var length: Int
                    (length, i) = leb(data, i)
                    i += length
                }
                let kind = data[i]
                i += 1
                switch kind {
                case 0:
                    i = leb(data, i).1
                case 1:
                    i += 1
                    var flags: Int
                    (flags, i) = leb(data, i)
                    i = leb(data, i).1
                    if flags & 1 != 0 { i = leb(data, i).1 }
                case 2:
                    var flags: Int
                    (flags, i) = leb(data, i)
                    i = leb(data, i).1
                    if flags & 1 != 0 { i = leb(data, i).1 }
                case 3:
                    importedGlobals += 1
                    i += 2
                default:
                    break
                }
            }
        case 6:  // globals: i32.const initializers are addresses
            var count: Int
            (count, i) = leb(data, i)
            for _ in 0..<count {
                i += 2  // the type, mutability
                let opcode = data[i]
                var value: Int? = nil
                switch opcode {
                case 0x41:  // i32.const (read unsigned: addresses)
                    var address: Int
                    (address, i) = leb(data, i + 1)
                    value = address
                case 0x42, 0x23:  // i64.const, global.get
                    i = leb(data, i + 1).1
                case 0x43:  // f32.const
                    i += 5
                case 0x44:  // f64.const
                    i += 9
                default:
                    fail("a global's initializer is not read (0x\(String(format: "%02x", opcode)))")
                }
                if data[i] != 0x0B { fail("a global's initializer is longer than one instruction") }
                globals.append(value)
                i += 1
            }
        case 7:
            var count: Int
            (count, i) = leb(data, i)
            for _ in 0..<count {
                var length: Int
                (length, i) = leb(data, i)
                let name = String(decoding: data[i..<i + length], as: UTF8.self)
                i += length
                let kind = data[i]
                var index: Int
                (index, i) = leb(data, i + 1)
                if kind == 3 && index >= importedGlobals {
                    let value = globals[index - importedGlobals]
                    // A name exported twice keeps its first place and its
                    // last value, as the Python's dict did.
                    if let earlier = exports.firstIndex(where: { $0.0 == name }) {
                        exports[earlier].1 = value
                    } else {
                        exports.append((name, value))
                    }
                }
            }
        case 11:
            var count: Int
            (count, i) = leb(data, i)
            for _ in 0..<count {
                var flags: Int
                (flags, i) = leb(data, i)
                if flags != 0 { fail("passive or indexed data segments are not read") }
                if data[i] != 0x41 { fail("a data segment's offset is not a constant") }
                var offset: Int, length: Int
                (offset, i) = leb(data, i + 1)
                i += 1
                (length, i) = leb(data, i)
                if memory.count < offset + length {
                    memory.append(contentsOf: repeatElement(0, count: offset + length - memory.count))
                }
                memory.replaceSubrange(offset..<offset + length, with: data[i..<i + length])
                i += length
            }
        default:
            break
        }
        i = end
    }
    return (exports, memory)
}

/// The ICU data's symbol and bytes (from its address to the next exported
/// address above it), or nil for a module without ICU.
func icuPackage(_ exports: [(String, Int?)], _ memory: [UInt8]) -> (String, [UInt8])? {
    let names = exports.map(\.0).filter { $0.hasPrefix("icudt") && $0.hasSuffix("_dat") }
    guard !names.isEmpty else { return nil }
    if names.count != 1 {
        fail("more than one icudt*_dat export ([\(names.map { "'\($0)'" }.joined(separator: ", "))])")
    }
    let symbol = names[0]
    guard let start = exports.first(where: { $0.0 == symbol })?.1 else {
        fail("\(symbol)'s address is not a constant")
    }
    let following = exports.compactMap(\.1).filter { $0 > start }
    let end = following.min() ?? memory.count
    // Python's slice: clamped to the memory.
    let lower = min(start, memory.count), upper = max(lower, min(end, memory.count))
    return (symbol, Array(memory[lower..<upper]))
}

let always: Set<String> = ["root.res", "res_index.res", "pool.res"]

/// Whether a base name is a locale's data file: `^([a-z]{2,3})(_[A-Za-z0-9]+)*\.res$`,
/// and if so its language.
func localeLanguage(_ base: String) -> String? {
    guard base.hasSuffix(".res") else { return nil }
    let stem = base.dropLast(4)
    let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
    let language = parts[0]
    guard (2...3).contains(language.count),
          language.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }) else { return nil }
    for part in parts.dropFirst() {
        guard !part.isEmpty, part.unicodeScalars.allSatisfy({
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }) else { return nil }
    }
    return String(language)
}

/// Whether an item is locale data of a language not in `languages`.
func droppedLocale(_ name: String, _ languages: Set<String>?) -> Bool {
    guard let languages else { return false }
    let base = String(name.split(separator: "/", omittingEmptySubsequences: false).last ?? "")
    if always.contains(base) { return false }
    guard let language = localeLanguage(base) else { return false }
    return !languages.contains(language)
}

func uint16(_ bytes: [UInt8], _ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
func uint32(_ bytes: [UInt8], _ at: Int) -> Int {
    Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
}
func littleEndian32(_ value: Int) -> [UInt8] {
    [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
}

/// Python's `-x % 16`: the padding that takes `x` to a multiple of 16.
func padding(_ x: Int) -> Int { ((-x % 16) + 16) % 16 }

/// The package without the items `drop` and `languages` leave out, and how
/// many were left out.
func trim(_ package: [UInt8], _ drop: [String], _ languages: Set<String>?) -> ([UInt8], Int) {
    let headerSize = uint16(package, 0)
    guard package.count >= 16, package[2] == 0xDA, package[3] == 0x27,
          package[12..<16].elementsEqual(Array("CmnD".utf8)) else { fail("not ICU common data") }
    let toc = headerSize
    let count = uint32(package, toc)
    let entries = (0..<count).map { k in (uint32(package, toc + 4 + 8 * k), uint32(package, toc + 4 + 8 * k + 4)) }
    var items: [(String, ArraySlice<UInt8>)] = []
    for (k, (nameOffset, dataOffset)) in entries.enumerated() {
        let nameStart = toc + nameOffset
        guard let nameEnd = package[nameStart...].firstIndex(of: 0) else { fail("an item's name never ends") }
        let name = String(decoding: package[nameStart..<nameEnd], as: UTF8.self)
        let end = k + 1 < count ? toc + entries[k + 1].1 : package.count
        items.append((name, package[(toc + dataOffset)..<end]))
    }
    func withoutPrefix(_ name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return name }
        return String(name[name.index(after: slash)...])
    }
    let kept = items.filter { name, _ in
        let short = withoutPrefix(name)
        return !drop.contains { fnmatch(short, $0) } && !droppedLocale(short, languages)
    }

    var names: [UInt8] = []
    for (name, _) in kept { names += Array(name.utf8) + [0] }
    let table = 4 + 8 * kept.count
    var first = table + names.count
    first += padding(headerSize + first)
    var nameOffsets: [Int] = [], dataOffsets: [Int] = [], body: [UInt8] = []
    var at = table
    for (name, _) in kept {
        nameOffsets.append(at)
        at += name.utf8.count + 1
    }
    for (_, data) in kept {
        body += repeatElement(0, count: padding(headerSize + first + body.count))
        dataOffsets.append(first + body.count)
        body += data
    }
    var out = Array(package[0..<headerSize])
    out += littleEndian32(kept.count)
    for (nameOffset, dataOffset) in zip(nameOffsets, dataOffsets) {
        out += littleEndian32(nameOffset) + littleEndian32(dataOffset)
    }
    out += names
    out += repeatElement(0, count: max(0, headerSize + first - out.count))
    out += body
    return (out, items.count - kept.count)
}

func section(_ kind: UInt8, _ payload: [UInt8]) -> [UInt8] { [kind] + uleb(payload.count) + payload }

func name(_ text: String) -> [UInt8] {
    let raw = Array(text.utf8)
    return uleb(raw.count) + raw
}

let magic: [UInt8] = [0, 0x61, 0x73, 0x6D, 1, 0, 0, 0]

/// A relocatable wasm object defining nothing (a module without ICU).
func emptyObjectFile() -> [UInt8] {
    magic + section(0, name("linking") + uleb(2))
}

/// A relocatable wasm object (as clang writes one) with one read-only data
/// segment, `.rodata.<symbol>`, and one data symbol over it.
func objectFile(_ symbol: String, _ package: [UInt8]) -> [UInt8] {
    let imports = uleb(1) + name("env") + name("__linear_memory") + [0x02, 0x00, 0x00]
    let dataCount = uleb(1)
    let data = uleb(1) + [0x00, 0x41, 0x00, 0x0B] + uleb(package.count) + package
    let symbols = uleb(1) + [0x01] + uleb(0) + name(symbol) + uleb(0) + uleb(0) + uleb(package.count)
    let segments = uleb(1) + name(".rodata." + symbol) + uleb(4) + uleb(0)
    let linking = name("linking") + uleb(2)
        + [8] + uleb(symbols.count) + symbols
        + [5] + uleb(segments.count) + segments
    return magic
        + section(2, imports)
        + section(12, dataCount)
        + section(11, data)
        + section(0, linking)
}

func write(_ bytes: [UInt8], to path: String) {
    do {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    } catch {
        fail("cannot write \(path): \(error)")
    }
}

/// Python's "%.1f" of bytes in MB.
func megabytes(_ count: Int) -> String { String(format: "%.1f", Double(count) / 1e6) }

var arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage: icu_data <module.wasm> <out.o> [locales=en,fr,…] <pattern>...") }
let (modulePath, outPath) = (arguments[0], arguments[1])
var drop = Array(arguments.dropFirst(2))
var languages: Set<String>? = nil
for argument in drop where argument.hasPrefix("locales=") {
    languages = Set(argument.dropFirst("locales=".count).split(separator: ",", omittingEmptySubsequences: false).map(String.init))
    drop.remove(at: drop.firstIndex(of: argument)!)
}
guard let contents = FileManager.default.contents(atPath: modulePath) else { fail("cannot read \(modulePath)") }
let (exports, memory) = readModule([UInt8](contents))
guard let found = icuPackage(exports, memory) else {
    write(emptyObjectFile(), to: outPath)
    print("icu_data: \(modulePath) has no ICU data")
    exit(0)
}
let (symbol, data) = found
let (trimmed, dropped) = trim(data, drop, languages)
write(objectFile(symbol, trimmed), to: outPath)
print("icu_data: \(symbol) \(megabytes(data.count)) MB -> \(megabytes(trimmed.count)) MB (\(dropped) items dropped)")
