// Text the way the Python tools this replaces read it, so that every output
// stays byte-identical to theirs: a file opened in text mode (strict UTF-8,
// universal newlines), str.split(), str.splitlines(), str.strip() and int().
// Strings are compared and hashed by their UTF-8 bytes (Python's by code
// point), never by Swift's canonical equivalence.

enum PythonText {
    /// str.isspace(): Unicode's White_Space plus the separators U+001C-U+001F.
    static func isSpace(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// The line boundaries str.splitlines() breaks at (\r\n counts as one).
    static func isLineBreak(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x0A...0x0D, 0x1C...0x1E, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// The bytes as strict UTF-8, or nil (Python's decode() would raise).
    static func strictUTF8(_ bytes: some Collection<UInt8>) -> String? {
        let s = String(decoding: bytes, as: UTF8.self)
        return s.utf8.elementsEqual(bytes) ? s : nil
    }

    /// open(path).read(): strict UTF-8, \r\n and \r read as \n.
    static func readText(_ path: String) throws -> String {
        let bytes = try FileIO.read(path)
        guard let s = strictUTF8(bytes) else {
            throw ToolError("\(path) is not UTF-8 text")
        }
        var out = String.UnicodeScalarView()
        var previousCR = false
        for u in s.unicodeScalars {
            if u == "\r" {
                out.append("\n")
                previousCR = true
                continue
            }
            if !(u == "\n" && previousCR) { out.append(u) }
            previousCR = false
        }
        return String(out)
    }

    /// str.split(sep) with an explicit one-character separator: empty fields kept.
    static func split(_ s: String, on sep: Unicode.Scalar, maxSplits: Int = .max) -> [String] {
        var fields: [String] = []
        var current = String.UnicodeScalarView()
        var splits = 0
        for u in s.unicodeScalars {
            if u == sep && splits < maxSplits {
                fields.append(String(current))
                current = String.UnicodeScalarView()
                splits += 1
            } else {
                current.append(u)
            }
        }
        fields.append(String(current))
        return fields
    }

    /// str.split(): runs of whitespace separate, no empty fields.
    static func splitWhitespace(_ s: String) -> [String] {
        var fields: [String] = []
        var current = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if isSpace(u) {
                if !current.isEmpty { fields.append(String(current)) }
                current = String.UnicodeScalarView()
            } else {
                current.append(u)
            }
        }
        if !current.isEmpty { fields.append(String(current)) }
        return fields
    }

    /// str.splitlines(): no terminators, no empty last line.
    static func splitLines(_ s: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var afterCR = false
        var pending = false
        for u in s.unicodeScalars {
            if afterCR && u == "\n" {
                afterCR = false
                continue
            }
            afterCR = false
            if isLineBreak(u) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
                afterCR = u == "\r"
                pending = false
            } else {
                current.append(u)
                pending = true
            }
        }
        if pending { lines.append(String(current)) }
        return lines
    }

    /// str.strip().
    static func strip(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
              let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: scalars[first...last])
        return String(out)
    }

    /// The value of a Unicode decimal digit (category Nd, Python's \d), or nil.
    static func decimalDigit(_ u: Unicode.Scalar) -> Int? {
        guard u.properties.generalCategory == .decimalNumber,
              let v = u.properties.numericValue else { return nil }
        return Int(v)
    }

    enum Integer: Hashable {
        case value(Int)
        /// Beyond Int: a key nothing can look up (Python's would be a big int).
        case tooLarge
    }

    /// int(s): surrounding whitespace, a sign, Unicode digits, single
    /// underscores between digits. nil where Python raises ValueError.
    static func int(_ s: String) -> Integer? {
        var scalars = Array(strip(s).unicodeScalars)[...]
        var negative = false
        if let sign = scalars.first, sign == "+" || sign == "-" {
            negative = sign == "-"
            scalars = scalars.dropFirst()
        }
        var value = 0
        var overflow = false
        var digits = 0
        var lastWasUnderscore = false
        for u in scalars {
            if u == "_" {
                if digits == 0 || lastWasUnderscore { return nil }
                lastWasUnderscore = true
                continue
            }
            guard let d = decimalDigit(u) else { return nil }
            lastWasUnderscore = false
            digits += 1
            let (m, o1) = value.multipliedReportingOverflow(by: 10)
            let (a, o2) = m.addingReportingOverflow(d)
            if o1 || o2 { overflow = true } else { value = a }
        }
        if digits == 0 || lastWasUnderscore { return nil }
        if overflow { return .tooLarge }
        return .value(negative ? -value : value)
    }
}
