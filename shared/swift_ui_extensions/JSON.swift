import SwiftUI

// A tiny dependency-free JSON parser. Pure Swift (no Foundation, no CG types)
// so the same source compiles into the wasm/Android `SwiftUI` module and the
// Apple shim, letting app code read API responses identically everywhere.

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Member access for objects; `.null` for anything else or a missing key.
    public subscript(key: String) -> JSONValue {
        if case .object(let map) = self { return map[key] ?? .null }
        return .null
    }

    /// Element access for arrays; `.null` when out of range or not an array.
    public subscript(index: Int) -> JSONValue {
        if case .array(let items) = self, index >= 0, index < items.count {
            return items[index]
        }
        return .null
    }

    public var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    public var int: Int? {
        if case .number(let n) = self { return Int(n) }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var array: [JSONValue]? {
        if case .array(let items) = self { return items }
        return nil
    }

    /// The object's key/value pairs (useful for `prop=pageimages` maps keyed
    /// by page id), or nil when not an object.
    public var object: [String: JSONValue]? {
        if case .object(let map) = self { return map }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Serializes back to a compact JSON string.
    public func encoded() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let b):
            return b ? "true" : "false"
        case .number(let n):
            // Integers render without a trailing ".0".
            if n == n.rounded(), abs(n) < 1e15 {
                return String(Int64(n))
            }
            return String(n)
        case .string(let s):
            return encodeJSONString(s)
        case .array(let items):
            return "[" + items.map { $0.encoded() }.joined(separator: ",") + "]"
        case .object(let map):
            let pairs = map.map { "\(encodeJSONString($0.key)):\($0.value.encoded())" }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }
}

/// Quotes and escapes a string as a JSON string literal.
func encodeJSONString(_ s: String) -> String {
    var out = "\""
    for scalar in s.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\t": out += "\\t"
        case "\r": out += "\\r"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out += "\""
    return out
}

/// Parses a JSON document, returning nil on malformed input.
public func parseJSON(_ text: String) -> JSONValue? {
    var parser = _JSONParser(Array(text.unicodeScalars))
    guard let value = parser.parseValue() else { return nil }
    parser.skipWhitespace()
    return parser.atEnd ? value : value
}

private struct _JSONParser {
    let scalars: [Unicode.Scalar]
    var index = 0

    init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

    var atEnd: Bool { index >= scalars.count }

    mutating func skipWhitespace() {
        while index < scalars.count {
            switch scalars[index] {
            case " ", "\t", "\n", "\r":
                index += 1
            default:
                return
            }
        }
    }

    func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        guard let c = peek() else { return nil }
        switch c {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString().map { .string($0) }
        case "t", "f": return parseBool()
        case "n": return parseNull()
        default: return parseNumber()
        }
    }

    mutating func parseObject() -> JSONValue? {
        index += 1 // consume {
        var map: [String: JSONValue] = [:]
        skipWhitespace()
        if peek() == "}" { index += 1; return .object(map) }
        while true {
            skipWhitespace()
            guard peek() == "\"", let key = parseString() else { return nil }
            skipWhitespace()
            guard peek() == ":" else { return nil }
            index += 1
            guard let value = parseValue() else { return nil }
            map[key] = value
            skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "}": index += 1; return .object(map)
            default: return nil
            }
        }
    }

    mutating func parseArray() -> JSONValue? {
        index += 1 // consume [
        var items: [JSONValue] = []
        skipWhitespace()
        if peek() == "]" { index += 1; return .array(items) }
        while true {
            guard let value = parseValue() else { return nil }
            items.append(value)
            skipWhitespace()
            switch peek() {
            case ",": index += 1
            case "]": index += 1; return .array(items)
            default: return nil
            }
        }
    }

    mutating func parseString() -> String? {
        index += 1 // consume opening quote
        var result = ""
        while let c = peek() {
            index += 1
            switch c {
            case "\"":
                return result
            case "\\":
                guard let esc = peek() else { return nil }
                index += 1
                switch esc {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "b": result.unicodeScalars.append(Unicode.Scalar(8))
                case "f": result.unicodeScalars.append(Unicode.Scalar(12))
                case "u":
                    guard let scalar = parseUnicodeEscape() else { return nil }
                    result.unicodeScalars.append(scalar)
                default:
                    return nil
                }
            default:
                result.unicodeScalars.append(c)
            }
        }
        return nil
    }

    mutating func parseUnicodeEscape() -> Unicode.Scalar? {
        func hex4() -> UInt32? {
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                guard let c = peek(), let digit = hexDigit(c) else { return nil }
                value = value * 16 + digit
                index += 1
            }
            return value
        }
        guard let first = hex4() else { return nil }
        // Surrogate pair handling.
        if first >= 0xD800, first <= 0xDBFF {
            guard peek() == "\\" else { return Unicode.Scalar(0xFFFD) }
            index += 1
            guard peek() == "u" else { return Unicode.Scalar(0xFFFD) }
            index += 1
            guard let second = hex4() else { return Unicode.Scalar(0xFFFD) }
            let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
            return Unicode.Scalar(combined) ?? Unicode.Scalar(0xFFFD)
        }
        return Unicode.Scalar(first) ?? Unicode.Scalar(0xFFFD)
    }

    func hexDigit(_ c: Unicode.Scalar) -> UInt32? {
        switch c {
        case "0" ... "9": return c.value - 48
        case "a" ... "f": return c.value - 97 + 10
        case "A" ... "F": return c.value - 65 + 10
        default: return nil
        }
    }

    mutating func parseBool() -> JSONValue? {
        if match("true") { return .bool(true) }
        if match("false") { return .bool(false) }
        return nil
    }

    mutating func parseNull() -> JSONValue? {
        match("null") ? .null : nil
    }

    mutating func match(_ literal: String) -> Bool {
        let lit = Array(literal.unicodeScalars)
        guard index + lit.count <= scalars.count else { return false }
        for (offset, scalar) in lit.enumerated() where scalars[index + offset] != scalar {
            return false
        }
        index += lit.count
        return true
    }

    mutating func parseNumber() -> JSONValue? {
        let start = index
        while let c = peek() {
            switch c {
            case "0" ... "9", "-", "+", ".", "e", "E":
                index += 1
            default:
                return finishNumber(from: start)
            }
        }
        return finishNumber(from: start)
    }

    func finishNumber(from start: Int) -> JSONValue? {
        guard index > start else { return nil }
        var s = ""
        s.unicodeScalars.append(contentsOf: scalars[start ..< index])
        guard let value = Double(s) else { return nil }
        return .number(value)
    }
}
