// `map-slots`: every table slot of the split's two parts mapped back to the
// runtime's function index (by name, through wasm-split's symbol maps), and
// the slots the split added written out as `<slot> <function>` lines: the
// host fills them in the interpreter's table so native code's calls through
// them reach the runtime's functions. Was map_slots.py.

enum MapSlots {
    static func run(
        runtime: String, cold: String, coldSymbols: String,
        hot: String, hotSymbols: String, output: String
    ) throws {
        let original = try FileIO.read(runtime)
        let names = try Wasm.functionNames(original)
        var count: [[UInt8]: Int] = [:]
        for name in names.values { count[name, default: 0] += 1 }
        var unique: [[UInt8]: Int] = [:]
        for (i, name) in names where count[name] == 1 { unique[name] = i }
        var first: [[UInt8]: Int] = [:]
        for (i, name) in names.sorted(by: { $0.key < $1.key }) where first[name] == nil {
            first[name] = i
        }

        /// The runtime's index of a function wasm-split names `name`.
        func originalIndex(_ name: String) -> Int? {
            // `<name>_<index>`: a name the runtime has more than once, made
            // unique with its index (Python's re `(.*)_(\d+)$`).
            let scalars = Array(name.unicodeScalars)
            if let underscore = scalars.lastIndex(of: "_") {
                let digits = scalars[(underscore + 1)...]
                if !digits.isEmpty, digits.allSatisfy({ PythonText.decimalDigit($0) != nil }) {
                    var value = 0
                    var fits = true
                    for d in digits {
                        let (m, o1) = value.multipliedReportingOverflow(by: 10)
                        let (a, o2) = m.addingReportingOverflow(PythonText.decimalDigit(d)!)
                        if o1 || o2 { fits = false; break }
                        value = a
                    }
                    var prefix = String.UnicodeScalarView()
                    prefix.append(contentsOf: scalars[..<underscore])
                    if fits, let indexed = names[value], indexed == Array(String(prefix).utf8) {
                        return value
                    }
                }
            }
            // Binaryen keeps the first function's plain name, suffixes the others.
            let key = Array(name.utf8)
            return unique[key] ?? first[key]
        }

        var originalSlots: [Int: Int] = [:]
        for (offset, functions) in try Wasm.activeElements(original) {
            for (k, f) in functions.enumerated() {
                if let f { originalSlots[offset + k] = f }
            }
        }

        var out: [String] = []
        var kept = 0, moved = 0, missing = 0
        for (part, symbolPath) in [(cold, coldSymbols), (hot, hotSymbols)] {
            var symbols: [PythonText.Integer: String] = [:]
            for line in PythonText.splitLines(try PythonText.readText(symbolPath))
            where line.unicodeScalars.contains(":") {
                let fields = PythonText.split(line, on: ":", maxSplits: 1)
                guard let index = PythonText.int(fields[0]) else {
                    throw ToolError("\(symbolPath): not an index: \(fields[0])")
                }
                symbols[index] = fields[1]
            }
            for (offset, functions) in try Wasm.activeElements(try FileIO.read(part)) {
                for (k, f) in functions.enumerated() {
                    guard let f else { continue }
                    let slot = offset + k
                    guard let index = originalIndex(symbols[.value(f)] ?? "") else {
                        missing += 1
                        continue
                    }
                    if let was = originalSlots[slot] {
                        kept += 1
                        if was != index { moved += 1 }
                    } else {
                        out.append("\(slot) \(index)")
                    }
                }
            }
        }
        let table = try Wasm.tableMinimum(original).map(String.init) ?? "None"
        print("original table \(table); \(kept) slots kept (\(moved) with another function), \(out.count) added, \(missing) unmapped")
        try FileIO.write(output, out.joined(separator: "\n") + "\n")
    }
}
