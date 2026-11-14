// WasmToolSupport: what the web build's small tools share (sdk_exports,
// icu_data, site_imports_check): their failures, Python's fnmatch and
// sort order, and JSON written as Python's json.dump(indent=2) wrote it.
// The tools were Python until 0.54; their outputs are byte for byte what
// the Python wrote, so these keep Python's rules where they show in a file.
import Foundation

/// Prints `<tool>: <message>` to standard error and exits with 1 (Python's
/// `raise SystemExit(message)`).
public func fail(_ tool: String, _ message: String) -> Never {
    FileHandle.standardError.write(Data("\(tool): \(message)\n".utf8))
    exit(1)
}

/// Python's order for strings: by code point (here by UTF-8 bytes, the same
/// order).
public func codePointOrder(_ a: String, _ b: String) -> Bool {
    a.utf8.lexicographicallyPrecedes(b.utf8)
}

/// Python's `fnmatch.fnmatchcase`: the whole name against a pattern of `*`
/// (anything, `/` too), `?` (one character), `[seq]` and `[!seq]` (with
/// ranges; a `]` first is literal; a `[` never closed is literal).
public func fnmatch(_ name: String, _ pattern: String) -> Bool {
    matches(Array(name.unicodeScalars), 0, Array(pattern.unicodeScalars), 0)
}

private func matches(_ name: [Unicode.Scalar], _ n: Int, _ pattern: [Unicode.Scalar], _ p: Int) -> Bool {
    var n = n, p = p
    while p < pattern.count {
        switch pattern[p] {
        case "*":
            // Runs of stars are one; then every split of the rest.
            while p < pattern.count && pattern[p] == "*" { p += 1 }
            if p == pattern.count { return true }
            for start in n...name.count where matches(name, start, pattern, p) { return true }
            return false
        case "?":
            guard n < name.count else { return false }
            n += 1
            p += 1
        case "[":
            guard let (set, negated, next) = characterClass(pattern, p) else {
                guard n < name.count, name[n] == "[" else { return false }
                n += 1
                p += 1
                continue
            }
            guard n < name.count else { return false }
            let inSet = set.contains { $0.contains(name[n]) }
            guard inSet != negated else { return false }
            n += 1
            p = next
        default:
            guard n < name.count, name[n] == pattern[p] else { return false }
            n += 1
            p += 1
        }
    }
    return n == name.count
}

/// The ranges of a `[...]` at `start`, whether it is negated, and the index
/// after it; nil when it never closes.
private func characterClass(_ pattern: [Unicode.Scalar], _ start: Int) -> ([ClosedRange<Unicode.Scalar>], Bool, Int)? {
    var i = start + 1
    var negated = false
    if i < pattern.count && pattern[i] == "!" {
        negated = true
        i += 1
    }
    var ranges: [ClosedRange<Unicode.Scalar>] = []
    var first = true
    while i < pattern.count {
        let scalar = pattern[i]
        if scalar == "]" && !first { return (ranges, negated, i + 1) }
        first = false
        if i + 2 < pattern.count && pattern[i + 1] == "-" && pattern[i + 2] != "]" {
            // A reversed range matches nothing, as in Python.
            if scalar <= pattern[i + 2] { ranges.append(scalar...pattern[i + 2]) }
            i += 3
        } else {
            ranges.append(scalar...scalar)
            i += 1
        }
    }
    return nil
}

/// A JSON value whose objects keep their members' order (Python's dicts
/// do), parsed and written as Python's `json` module does.
public indirect enum JSONValue: Equatable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case integer(Int)
    case double(Double)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.integer(x), .integer(y)): return x == y
        case let (.double(x), .double(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ bytes: [UInt8]) throws -> JSONValue {
        var parser = Parser(bytes: bytes)
        parser.skipSpace()
        let value = try parser.value()
        parser.skipSpace()
        guard parser.at == bytes.count else { throw ParseError(description: "extra data at byte \(parser.at)") }
        return value
    }

    /// The text `json.dump(value, f, indent=2)` writes: ensure_ascii, ", " is
    /// "," at line ends, ": " between a key and its value, no final newline.
    public func pythonIndented() -> String {
        var out = ""
        write(to: &out, level: 0)
        return out
    }

    private func write(to out: inout String, level: Int) {
        let inner = String(repeating: "  ", count: level + 1)
        let closing = String(repeating: "  ", count: level)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, (key, value)) in members.enumerated() {
                out += inner + Self.quoted(key) + ": "
                value.write(to: &out, level: level + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += closing + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(to: &out, level: level + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += closing + "]"
        case .string(let text): out += Self.quoted(text)
        case .integer(let number): out += String(number)
        case .double(let number): out += Self.pythonFloat(number)
        case .bool(let value): out += value ? "true" : "false"
        case .null: out += "null"
        }
    }

    /// A string as Python's json writes it with ensure_ascii: everything
    /// outside ' '...'~' escaped, as \uXXXX (lowercase, surrogate pairs past
    /// the first plane) unless it has a short escape.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for unit in text.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20...0x7E: out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default:
                let hex = String(unit, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            }
        }
        return out + "\""
    }

    /// A float as Python writes it, near enough: Swift's shortest
    /// round-tripping digits, which are Python's repr but for the exponent
    /// form of numbers from 2^53 to 1e16. (The manifests these tools write
    /// hold no floats.)
    static func pythonFloat(_ number: Double) -> String {
        if number.isNaN { return "NaN" }
        if number.isInfinite { return number < 0 ? "-Infinity" : "Infinity" }
        return "\(number)"
    }

    private struct Parser {
        let bytes: [UInt8]
        var at = 0

        mutating func skipSpace() {
            while at < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
        }

        func error(_ what: String) -> ParseError { ParseError(description: "\(what) at byte \(at)") }

        mutating func expect(_ text: String) throws {
            let expected = Array(text.utf8)
            guard at + expected.count <= bytes.count, bytes[at..<at + expected.count].elementsEqual(expected) else {
                throw error("expected \(text)")
            }
            at += expected.count
        }

        mutating func value() throws -> JSONValue {
            guard at < bytes.count else { throw error("unexpected end") }
            switch bytes[at] {
            case UInt8(ascii: "{"):
                at += 1
                var members: [(String, JSONValue)] = []
                skipSpace()
                if at < bytes.count && bytes[at] == UInt8(ascii: "}") { at += 1; return .object(members) }
                while true {
                    skipSpace()
                    guard at < bytes.count, bytes[at] == UInt8(ascii: "\"") else { throw error("expected a key") }
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    let item = try value()
                    // A repeated key keeps its first place and its last value,
                    // as a Python dict does.
                    if let earlier = members.firstIndex(where: { $0.0 == key }) {
                        members[earlier].1 = item
                    } else {
                        members.append((key, item))
                    }
                    skipSpace()
                    guard at < bytes.count else { throw error("unexpected end") }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    try expect("}")
                    return .object(members)
                }
            case UInt8(ascii: "["):
                at += 1
                var items: [JSONValue] = []
                skipSpace()
                if at < bytes.count && bytes[at] == UInt8(ascii: "]") { at += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard at < bytes.count else { throw error("unexpected end") }
                    if bytes[at] == UInt8(ascii: ",") { at += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"):
                try expect("true")
                return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false")
                return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null")
                return .null
            default:
                return try number()
            }
        }

        mutating func number() throws -> JSONValue {
            let start = at
            var isInteger = true
            while at < bytes.count, let scalar = Optional(bytes[at]),
                  (scalar >= UInt8(ascii: "0") && scalar <= UInt8(ascii: "9")) || "-+.eE".utf8.contains(scalar) {
                if "eE.".utf8.contains(scalar) { isInteger = false }
                at += 1
            }
            let text = String(decoding: bytes[start..<at], as: UTF8.self)
            if isInteger, let integer = Int(text) { return .integer(integer) }
            guard let double = Double(text) else { throw error("not a number: \(text)") }
            return .double(double)
        }

        mutating func string() throws -> String {
            at += 1  // the opening quote
            var units: [UInt16] = []
            var raw: [UInt8] = []
            func flush() {
                units.append(contentsOf: String(decoding: raw, as: UTF8.self).utf16)
                raw.removeAll()
            }
            while true {
                guard at < bytes.count else { throw error("unterminated string") }
                let byte = bytes[at]
                at += 1
                switch byte {
                case UInt8(ascii: "\""):
                    flush()
                    return String(decoding: units, as: UTF16.self)
                case UInt8(ascii: "\\"):
                    flush()
                    guard at < bytes.count else { throw error("unterminated escape") }
                    let escape = bytes[at]
                    at += 1
                    switch escape {
                    case UInt8(ascii: "\""): units.append(0x22)
                    case UInt8(ascii: "\\"): units.append(0x5C)
                    case UInt8(ascii: "/"): units.append(0x2F)
                    case UInt8(ascii: "b"): units.append(0x08)
                    case UInt8(ascii: "f"): units.append(0x0C)
                    case UInt8(ascii: "n"): units.append(0x0A)
                    case UInt8(ascii: "r"): units.append(0x0D)
                    case UInt8(ascii: "t"): units.append(0x09)
                    case UInt8(ascii: "u"):
                        guard at + 4 <= bytes.count,
                              let unit = UInt16(String(decoding: bytes[at..<at + 4], as: UTF8.self), radix: 16)
                        else { throw error("bad \\u escape") }
                        units.append(unit)
                        at += 4
                    default: throw error("bad escape")
                    }
                default:
                    raw.append(byte)
                }
            }
        }
    }
}
