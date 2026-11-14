// The tap targets of a serialized frame, for the render tests: what a
// person could tap on the first screen.

enum TapTargets {
    /// Every distinct tap target id in a frame, in order: an ASCII run of
    /// digits, dots and lower-case letters ending in ".tap".
    static func ids(_ bytes: [UInt8]) -> [String] {
        let suffix = Array(".tap".utf8)
        func idByte(_ c: UInt8) -> Bool { (48...57).contains(c) || c == 46 || (97...122).contains(c) }
        var ids: [String] = []
        var i = 0
        while i + 4 <= bytes.count {
            if bytes[i..<(i + 4)].elementsEqual(suffix) {
                var start = i
                while start > 0 && idByte(bytes[start - 1]) { start -= 1 }
                var id = String(decoding: bytes[start..<(i + 4)], as: UTF8.self)
                while id.hasPrefix(".") { id.removeFirst() }
                if !id.isEmpty && !ids.contains(id) { ids.append(id) }
            }
            i += 1
        }
        return ids
    }
}
