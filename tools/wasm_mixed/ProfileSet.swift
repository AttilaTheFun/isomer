// `profile-set`: a native set from profiles of the runtime module under
// WasmKit's interpreter (WasmKitFunctionProfile: `<index> <calls> <self ns>`
// lines), such as a corpus's (tools/wasm_mixed_corpus): the functions that
// together took `time` of the runtime's own time, and every function called
// at least `calls` times (a crossing from native code costs more than a small
// function's work). Several profiles add up. The set names functions by
// name (Select.swift takes a name as every function by it), so it outlives
// the runtime build it was made from.

enum ProfileSet {
    static func run(runtime: String, profiles: [String], output: String, time: Double, calls minimumCalls: Int) throws {
        let names = try Wasm.functionNames(try FileIO.read(runtime))
        var calls: [Int: Int] = [:], nanos: [Int: Int] = [:]
        for path in profiles {
            for line in PythonText.splitLines(String(decoding: try FileIO.read(path), as: UTF8.self)) {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let index = Int(parts[0]), let c = Int(parts[1]), let n = Int(parts[2]) else { continue }
                calls[index, default: 0] += c
                nanos[index, default: 0] += n
            }
        }
        let total = nanos.values.reduce(0, +)
        var chosen: Set<Int> = []
        var covered = 0
        for (index, n) in nanos.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) {
            if Double(covered) >= time * Double(total) { break }
            chosen.insert(index)
            covered += n
        }
        let byTime = chosen.count
        for (index, c) in calls where c >= minimumCalls { chosen.insert(index) }
        var lines: Set<String> = []
        for index in chosen { if let name = names[index] { lines.insert(String(decoding: name, as: UTF8.self)) } }
        try FileIO.write(output, lines.sorted().joined(separator: "\n") + "\n")
        print("profile-set: \(calls.count) functions ran; \(byTime) took \(Int(time * 100))% of the runtime's \(total / 1_000_000) ms, \(chosen.count - byTime) more were called \(minimumCalls)+ times: \(lines.count) names")
    }
}
