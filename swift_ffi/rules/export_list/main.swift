// Writes a link response file exporting only a module's host entries.
//
//     export_list <module.wasm> <out.rsp> <prefix-or-name>...
//
// Reads the exports of a module linked with every symbol exported
// (`--export-all`) and writes `-Wl,--export-if-defined=<name>` (for the clang
// driver rules_swift links through, which expands the file itself) for each
// one whose name starts with one of the prefixes given (an argument ending in
// `*`) or is one of the names given: the list a second link of the same
// objects takes with `--gc-sections`, which then drops whatever no export
// reaches. Hosts look their entries up by name (swift_ffi's `swift_ffi_*`,
// the `iso_hot_*` bridge), so the names cannot be listed while the build is
// planned; read from the first link, they cannot drift from the code either.
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("export_list: \(message)\n".utf8))
    exit(1)
}

/// An unsigned LEB128 at `i`, and the index after it.
func leb(_ data: [UInt8], _ start: Int) -> (Int, Int) {
    var result = 0, shift = 0, i = start
    while true {
        let byte = data[i]
        i += 1
        result |= Int(byte & 0x7F) &<< shift
        shift += 7
        if byte < 0x80 { return (result, i) }
    }
}

/// The names a module exports, in the order of its export section.
func exports(_ data: [UInt8]) -> [String] {
    guard data.count >= 4, data[0..<4].elementsEqual([0, 0x61, 0x73, 0x6D]) else { fail("not a wasm module") }
    var names: [String] = []
    var i = 8
    while i < data.count {
        let section = data[i]
        let (size, start) = leb(data, i + 1)
        i = start
        let end = i + size
        if section == 7 {
            let (count, first) = leb(data, i)
            i = first
            for _ in 0..<count {
                let (length, at) = leb(data, i)
                names.append(String(decoding: data[at..<at + length], as: UTF8.self))
                i = at + length + 1  // the kind
                i = leb(data, i).1  // the index
            }
        }
        i = end
    }
    return names
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 2 else { fail("usage: export_list <module.wasm> <out.rsp> <prefix-or-name>...") }
let (module, out, wanted) = (arguments[0], arguments[1], arguments.dropFirst(2))
let prefixes = wanted.filter { $0.hasSuffix("*") }.map { String($0.dropLast()) }
let names = Set(wanted.filter { !$0.hasSuffix("*") })
guard let bytes = FileManager.default.contents(atPath: module) else { fail("cannot read \(module)") }
// Sorted by their UTF-8 bytes, as Python sorted them.
let found = Set(exports(Array(bytes)).filter { name in names.contains(name) || prefixes.contains { name.hasPrefix($0) } })
    .sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
let missing = names.subtracting(found).sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
if !missing.isEmpty {
    fail("\(module) does not export \(missing.joined(separator: ", "))")
}
do {
    try Data(found.map { "-Wl,--export-if-defined=\($0)\n" }.joined().utf8).write(to: URL(fileURLWithPath: out))
} catch {
    fail("cannot write \(out): \(error)")
}
