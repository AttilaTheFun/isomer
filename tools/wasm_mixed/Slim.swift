import Foundation

// `slim`: a module with only the given exports and its data segments emptied
// (the interpreted runtime initializes memory), and of its custom sections
// only `name` and `target_features`. Made twice in a build: from the runtime,
// the split's input (wasm-split keeps every exported function in the part it
// is told to keep, so the input exports only the entry points), and from the
// split's native part, what wasm2c compiles. Was slim_native.py.

enum Slim {
    /// The names a keep list names: comma-separated, `@file` for a file of
    /// whitespace-separated names (read relative to the working directory).
    /// As UTF-8 bytes: the comparison is Python's, by code point.
    static func keepSet(_ spec: String) throws -> Set<[UInt8]> {
        var keep: Set<[UInt8]> = []
        for item in PythonText.split(spec, on: ",") {
            if item.unicodeScalars.first == "@" {
                let path = String(String.UnicodeScalarView(item.unicodeScalars.dropFirst()))
                for name in PythonText.splitWhitespace(try PythonText.readText(path)) {
                    keep.insert(Array(name.utf8))
                }
            } else {
                keep.insert(Array(item.utf8))
            }
        }
        return keep
    }

    static func slim(_ b: [UInt8], keeping keep: Set<[UInt8]>) throws -> [UInt8] {
        var out = Array(b.prefix(8))
        for section in try Wasm.sections(b) {
            var body = Array(b[section.start..<section.end])
            switch section.id {
            case 7:  // exports: the kept ones, as they were
                var r = WasmReader(b, at: section.start)
                var kept: [ArraySlice<UInt8>] = []
                for _ in 0..<max(try r.uleb(), 0) {
                    let start = r.position
                    let length = try r.uleb()
                    let name = try r.take(length)
                    guard PythonText.strictUTF8(name) != nil else {
                        throw ToolError("an export's name at byte \(start) is not UTF-8")
                    }
                    try r.skip(1)  // the kind
                    _ = try r.uleb()  // the index
                    if keep.contains(Array(name)) { kept.append(b[start..<r.position]) }
                }
                body = Wasm.encodeULEB(kept.count) + kept.flatMap { $0 }
            case 11:  // data: the same segments, no bytes
                var r = WasmReader(b, at: section.start)
                let count = try r.uleb()
                var segments: [UInt8] = []
                for _ in 0..<max(count, 0) {
                    let start = r.position
                    let flags = try r.uleb()
                    if flags == 2 { _ = try r.uleb() }  // the memory
                    if flags != 1 {
                        // The offset expression, up to its end. Only i32.const
                        // and global.get take an immediate here, as before.
                        while try r.peek() != 0x0B {
                            let op = try r.byte()
                            if op == 0x41 {
                                _ = try r.sleb()
                            } else if op == 0x23 {
                                _ = try r.uleb()
                            }
                        }
                        r.position += 1
                    }
                    let head = b[start..<r.position]
                    try r.skip(try r.uleb())
                    segments += head
                    segments += Wasm.encodeULEB(0)
                }
                body = Wasm.encodeULEB(count) + segments
            case 0:  // custom: only the names and the target features stay
                var r = WasmReader(b, at: section.start)
                let length = try r.uleb()
                let name = try r.take(length)
                if !(name.elementsEqual("name".utf8) || name.elementsEqual("target_features".utf8)) {
                    continue
                }
            default:
                break
            }
            out.append(section.id)
            out += Wasm.encodeULEB(body.count)
            out += body
        }
        return out
    }

    /// `wasm_mixed slim <in.wasm> <out.wasm> <keep list>`.
    static func run(input: String, output: String, keep spec: String) throws {
        let b = try FileIO.read(input)
        let out = try slim(b, keeping: try keepSet(spec))
        try FileIO.write(output, out)
        print("\(megabytes(b.count)) MB -> \(megabytes(out.count)) MB")
    }

    /// Python's f'{n/1e6:.1f}'.
    static func megabytes(_ n: Int) -> String {
        String(format: "%.1f", Double(n) / 1e6)
    }
}
