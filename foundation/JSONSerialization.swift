// JSONSerialization and NSNull (Apple's Foundation and corelibs have them;
// swift-foundation has JSONEncoder and JSONDecoder): JSON text to and from
// Foundation's untyped values. Objects are [String: Any], arrays [Any],
// strings String, numbers and booleans NSNumber, null NSNull. Written as
// Apple's writes it: slashes escaped unless asked not to, pretty printing
// two spaces deep with " : " after a key.

import FoundationEssentials

/// JSON's null, in collections of Foundation's untyped values.
open class NSNull: Hashable, CustomStringConvertible, @unchecked Sendable {
    public init() {}
    public static func == (lhs: NSNull, rhs: NSNull) -> Bool { true }
    public func hash(into hasher: inout Hasher) {}
    open var description: String { "<null>" }
}

open class JSONSerialization: @unchecked Sendable {
    public struct ReadingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var mutableContainers: ReadingOptions { ReadingOptions(rawValue: 1 << 0) }
        public static var mutableLeaves: ReadingOptions { ReadingOptions(rawValue: 1 << 1) }
        public static var fragmentsAllowed: ReadingOptions { ReadingOptions(rawValue: 1 << 2) }
        public static var json5Allowed: ReadingOptions { ReadingOptions(rawValue: 1 << 3) }
        public static var topLevelDictionaryAssumed: ReadingOptions { ReadingOptions(rawValue: 1 << 4) }
    }

    public struct WritingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static var prettyPrinted: WritingOptions { WritingOptions(rawValue: 1 << 0) }
        public static var sortedKeys: WritingOptions { WritingOptions(rawValue: 1 << 1) }
        public static var fragmentsAllowed: WritingOptions { WritingOptions(rawValue: 1 << 2) }
        public static var withoutEscapingSlashes: WritingOptions { WritingOptions(rawValue: 1 << 3) }
    }

    /// Whether `obj` can be written: an array or an object at the top,
    /// holding only JSON's values, objects keyed by strings, numbers finite.
    open class func isValidJSONObject(_ obj: Any) -> Bool {
        guard obj is [Any] || obj is [String: Any] || obj is [AnyHashable: Any] else { return false }
        var writer = Writer(options: [])
        return (try? writer.write(obj)) != nil
    }

    open class func data(withJSONObject obj: Any, options opt: WritingOptions = []) throws -> Data {
        if !opt.contains(.fragmentsAllowed), !(obj is [Any] || obj is [String: Any] || obj is [AnyHashable: Any]) {
            throw CocoaError(.propertyListWriteInvalid)
        }
        var writer = Writer(options: opt)
        try writer.write(obj)
        return Data(writer.text.utf8)
    }

    open class func jsonObject(with data: Data, options opt: ReadingOptions = []) throws -> Any {
        var reader = Reader(bytes: Array(data))
        reader.skipWhitespace()
        let value = try reader.value()
        reader.skipWhitespace()
        guard reader.atEnd else { throw Reader.corrupt("Garbage at end around line \(reader.line).") }
        if !opt.contains(.fragmentsAllowed), !(value is [Any] || value is [String: Any]) {
            throw Reader.corrupt("JSON text did not start with array or object and option to allow fragments not set.")
        }
        return value
    }

    // MARK: Writing

    private struct Writer {
        let options: WritingOptions
        var text = ""
        var depth = 0

        init(options: WritingOptions) { self.options = options }

        mutating func write(_ value: Any) throws {
            switch value {
            case let string as String: writeString(string)
            case let number as NSNumber: try writeNumber(number)
            case let bool as Bool: text += bool ? "true" : "false"
            case let int as Int: text += String(int)
            case let int as Int8: text += String(int)
            case let int as Int16: text += String(int)
            case let int as Int32: text += String(int)
            case let int as Int64: text += String(int)
            case let int as UInt: text += String(int)
            case let int as UInt8: text += String(int)
            case let int as UInt16: text += String(int)
            case let int as UInt32: text += String(int)
            case let int as UInt64: text += String(int)
            case let double as Double: try writeDouble(double)
            case let float as Float: try writeDouble(Double(float))
            case is NSNull: text += "null"
            case let array as [Any]: try writeArray(array)
            case let object as [String: Any]: try writeObject(object.map { ($0.key, $0.value) })
            case let object as [AnyHashable: Any]:
                var pairs: [(String, Any)] = []
                for (key, value) in object {
                    guard let key = key.base as? String else { throw CocoaError(.propertyListWriteInvalid) }
                    pairs.append((key, value))
                }
                try writeObject(pairs)
            default:
                // An Optional's nil (`name as Any`, a nil String?: a cast
                // above unwraps one that holds a value), or anything else
                // JSON has no word for.
                let mirror = Mirror(reflecting: value)
                if mirror.displayStyle == .optional, mirror.children.isEmpty { text += "null"; return }
                throw CocoaError(.propertyListWriteInvalid)
            }
        }

        mutating func writeNumber(_ number: NSNumber) throws {
            guard let json = number.jsonText else { throw CocoaError(.propertyListWriteInvalid) }
            text += json
        }

        mutating func writeDouble(_ double: Double) throws {
            guard let json = NSNumber.jsonText(of: double) else { throw CocoaError(.propertyListWriteInvalid) }
            text += json
        }

        mutating func writeString(_ string: String) {
            text += "\""
            for scalar in string.unicodeScalars {
                switch scalar {
                case "\"": text += "\\\""
                case "\\": text += "\\\\"
                case "/": text += options.contains(.withoutEscapingSlashes) ? "/" : "\\/"
                case "\n": text += "\\n"
                case "\r": text += "\\r"
                case "\t": text += "\\t"
                case "\u{08}": text += "\\b"
                case "\u{0C}": text += "\\f"
                default:
                    if scalar.value < 0x20 {
                        let hex = String(scalar.value, radix: 16)
                        text += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    } else {
                        text.unicodeScalars.append(scalar)
                    }
                }
            }
            text += "\""
        }

        mutating func writeArray(_ array: [Any]) throws {
            text += "["
            depth += 1
            for (index, element) in array.enumerated() {
                if index > 0 { text += "," }
                newline()
                try write(element)
            }
            depth -= 1
            if !array.isEmpty { newline() }
            text += "]"
        }

        mutating func writeObject(_ pairs: [(String, Any)]) throws {
            let ordered = options.contains(.sortedKeys) ? pairs.sorted { $0.0 < $1.0 } : pairs
            text += "{"
            depth += 1
            for (index, pair) in ordered.enumerated() {
                if index > 0 { text += "," }
                newline()
                writeString(pair.0)
                text += options.contains(.prettyPrinted) ? " : " : ":"
                try write(pair.1)
            }
            depth -= 1
            if !ordered.isEmpty { newline() }
            text += "}"
        }

        mutating func newline() {
            guard options.contains(.prettyPrinted) else { return }
            text += "\n" + String(repeating: "  ", count: depth)
        }
    }

    // MARK: Reading

    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var line = 1

        init(bytes: [UInt8]) { self.bytes = bytes }

        var atEnd: Bool { index >= bytes.count }

        static func corrupt(_ reason: String) -> CocoaError {
            CocoaError(.propertyListReadCorrupt, userInfo: [NSDebugDescriptionErrorKey: reason])
        }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0D: index += 1
                case 0x0A: index += 1; line += 1
                default: return
                }
            }
        }

        mutating func value() throws -> Any {
            guard index < bytes.count else { throw Self.corrupt("Unexpected end of file during JSON parse.") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return try string()
            case UInt8(ascii: "t"): try literal("true"); return NSNumber(value: true)
            case UInt8(ascii: "f"): try literal("false"); return NSNumber(value: false)
            case UInt8(ascii: "n"): try literal("null"); return NSNull()
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            for byte in word.utf8 {
                guard index < bytes.count, bytes[index] == byte else { throw Self.corrupt("Invalid value around line \(line).") }
                index += 1
            }
        }

        mutating func object() throws -> [String: Any] {
            index += 1
            var object: [String: Any] = [:]
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return object }
            while true {
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                    throw Self.corrupt("No string key for value in object around line \(line).")
                }
                let key = try string()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                    throw Self.corrupt("No value for key in object around line \(line).")
                }
                index += 1
                skipWhitespace()
                object[key] = try value()
                skipWhitespace()
                guard index < bytes.count else { throw Self.corrupt("Unexpected end of file during JSON parse.") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return object }
                throw Self.corrupt("Badly formed object around line \(line).")
            }
        }

        mutating func array() throws -> [Any] {
            index += 1
            var array: [Any] = []
            skipWhitespace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return array }
            while true {
                skipWhitespace()
                array.append(try value())
                skipWhitespace()
                guard index < bytes.count else { throw Self.corrupt("Unexpected end of file during JSON parse.") }
                if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return array }
                throw Self.corrupt("Badly formed array around line \(line).")
            }
        }

        mutating func string() throws -> String {
            index += 1
            var scalars = String.UnicodeScalarView()
            var run = index
            func flush(_ end: Int, into scalars: inout String.UnicodeScalarView) {
                if end > run { scalars.append(contentsOf: String(decoding: bytes[run..<end], as: UTF8.self).unicodeScalars) }
            }
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    flush(index, into: &scalars)
                    index += 1
                    return String(scalars)
                }
                if byte == UInt8(ascii: "\\") {
                    flush(index, into: &scalars)
                    index += 1
                    guard index < bytes.count else { break }
                    switch bytes[index] {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        // A UTF-16 surrogate pair, as 😀.
                        if (0xD800...0xDBFF).contains(code), index + 2 < bytes.count,
                           bytes[index + 1] == UInt8(ascii: "\\"), bytes[index + 2] == UInt8(ascii: "u") {
                            index += 2
                            let low = try hex4()
                            guard (0xDC00...0xDFFF).contains(low) else {
                                throw Self.corrupt("Invalid unicode escape (no low surrogate) around line \(line).")
                            }
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        guard let scalar = Unicode.Scalar(code) else { throw Self.corrupt("Invalid unicode escape around line \(line).") }
                        scalars.append(scalar)
                    default:
                        throw Self.corrupt("Invalid escape sequence around line \(line).")
                    }
                    index += 1
                    run = index
                    continue
                }
                if byte < 0x20 { throw Self.corrupt("Unescaped control character around line \(line).") }
                index += 1
            }
            throw Self.corrupt("Unterminated string around line \(line).")
        }

        /// The four hex digits after `\u`, leaving `index` on the last.
        mutating func hex4() throws -> UInt32 {
            guard index + 4 < bytes.count else { throw Self.corrupt("Invalid unicode escape around line \(line).") }
            var code: UInt32 = 0
            for offset in 1...4 {
                guard let digit = Character(Unicode.Scalar(bytes[index + offset])).hexDigitValue else {
                    throw Self.corrupt("Invalid unicode escape around line \(line).")
                }
                code = code * 16 + UInt32(digit)
            }
            index += 4
            return code
        }

        mutating func number() throws -> NSNumber {
            let start = index
            var integral = true
            while index < bytes.count, Self.numberBytes.contains(bytes[index]) {
                switch bytes[index] {
                case UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"): integral = false
                default: break
                }
                index += 1
            }
            let text = String(decoding: bytes[start..<index], as: UTF8.self)
            if integral, let value = Int64(text) { return NSNumber(value: value) }
            if integral, let value = UInt64(text) { return NSNumber(value: value) }
            guard !text.isEmpty, let value = Double(text), value.isFinite else {
                throw Self.corrupt("Invalid value around line \(line).")
            }
            return NSNumber(value: value)
        }

        static let numberBytes: Set<UInt8> = Set("0123456789.eE+-".utf8)
    }
}

extension NSNumber {
    /// How JSONSerialization writes this number: a boolean as true or
    /// false, an integer as its digits, a double as short as reads back the
    /// same (nil for one JSON can't hold: not finite).
    var jsonText: String? {
        if let flag = boolStorage { return flag ? "true" : "false" }
        if isFloatingStorage { return Self.jsonText(of: doubleValue) }
        return isUnsignedStorage ? String(uint64Value) : String(int64Value)
    }

    static func jsonText(of double: Double) -> String? {
        guard double.isFinite else { return nil }
        if double == double.rounded(), abs(double) < 1e15 { return String(Int64(double)) }
        return "\(double)"
    }
}
