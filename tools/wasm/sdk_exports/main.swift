// Writes an SDK bundle's manifest with the exports a program linked from it
// needs added: the entries its hosts call by name, read from the archives'
// symbol indexes (the GNU ar `/` member) and matched against patterns
// (`prefix*` or a name; a name is exported when defined).
//
//     sdk_exports <base manifest.json> <out manifest.json> <archive>... -- <pattern>...
//
// A link with these exports and `--gc-sections` keeps what the hosts reach and
// drops the rest, where `--export-all` kept every function of every archive
// (Foundation's included). It was sdk_exports.py until 0.54: the manifest is
// written as Python's json.dump(indent=2) wrote it, byte for byte.
import Foundation
import WasmToolSupport

/// The global symbols an archive's index lists.
func archiveSymbols(_ path: String) -> [String] {
    guard let contents = FileManager.default.contents(atPath: path) else { fail("sdk_exports", "cannot read \(path)") }
    let data = [UInt8](contents)
    guard data.count >= 8, data[0..<8].elementsEqual(Array("!<arch>\n".utf8)) else { return [] }
    var position = 8
    while position + 60 <= data.count {
        let header = data[position..<position + 60]
        let name = String(decoding: header.prefix(16), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        let sizeField = String(decoding: header.dropFirst(48).prefix(10), as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard let size = Int(sizeField) else { fail("sdk_exports", "\(path): a member's size is not a number") }
        let body = Array(data[(position + 60)..<min(position + 60 + size, data.count)])
        if name == "/" {
            let count = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
            // The names follow the offsets, each ended by a NUL.
            let names = body[(4 + 4 * count)...].split(separator: 0, omittingEmptySubsequences: false)
            return names.prefix(count).map { String(decoding: $0, as: UTF8.self) }
        }
        position += 60 + size + (size & 1)
    }
    return []
}

let arguments = Array(CommandLine.arguments)
guard arguments.count >= 3, let separator = arguments.firstIndex(of: "--") else {
    fail("sdk_exports", "usage: sdk_exports <base manifest.json> <out manifest.json> <archive>... -- <pattern>...")
}
let (basePath, outPath) = (arguments[1], arguments[2])
let archives = arguments[3..<separator], patterns = arguments[(separator + 1)...]
var symbols = Set<String>()
for archive in archives {
    symbols.formUnion(archiveSymbols(archive))
}
var exports = Set<String>()
for pattern in patterns {
    if pattern.contains("*") {
        exports.formUnion(symbols.filter { fnmatch($0, pattern) })
    } else {
        exports.insert(pattern)
    }
}
guard let base = FileManager.default.contents(atPath: basePath) else { fail("sdk_exports", "cannot read \(basePath)") }
var manifest: JSONValue
do {
    manifest = try JSONValue.parse([UInt8](base))
} catch {
    fail("sdk_exports", "\(basePath): \(error)")
}
guard case .object(var members) = manifest else { fail("sdk_exports", "\(basePath) is not a JSON object") }
let sorted = JSONValue.array(exports.sorted(by: codePointOrder).map { .string($0) })
if let at = members.firstIndex(where: { $0.0 == "exports" }) {
    members[at].1 = sorted
} else {
    members.append(("exports", sorted))
}
do {
    try Data(JSONValue.object(members).pythonIndented().utf8).write(to: URL(fileURLWithPath: outPath))
} catch {
    fail("sdk_exports", "cannot write \(outPath): \(error)")
}
