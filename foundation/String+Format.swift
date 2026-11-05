// String(format:) for platforms without Apple's framework (upstream
// leaves it to swift-corelibs-foundation's CFString formatting). The format
// is read here: `%@` describes any value, `%s` takes a Swift string or a C
// string, positions (`%2$@`), widths and precisions (also `*`) and flags
// work; each numeric conversion is written by the C library's vsnprintf, so
// numbers come out as printf writes them. The locale is not applied.

import FoundationEssentials

#if canImport(Glibc)
@preconcurrency import Glibc
#elseif canImport(Musl)
@preconcurrency import Musl
#elseif canImport(Android)
@preconcurrency import Android
#elseif canImport(WASILibc)
@preconcurrency import WASILibc
#elseif canImport(ucrt)
import ucrt
#elseif canImport(Darwin)
import Darwin
#endif

/// A String passed to a C variadic function arrives as a C string (a copy
/// that lives as long as the program).
extension String: @retroactive CVarArg {
    public var _cVarArgEncoding: [Int] {
        let copy = withCString { strdup($0) }
        return copy!._cVarArgEncoding
    }
}

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension String {
    public init(format: __shared String, _ arguments: any CVarArg...) {
        self = _IsomerFormatter.format(format, arguments)
    }

    public init(format: __shared String, arguments: __shared [any CVarArg]) {
        self = _IsomerFormatter.format(format, arguments)
    }

    public init(format: __shared String, locale: Locale?, _ args: any CVarArg...) {
        self = _IsomerFormatter.format(format, args)
    }

    public init(format: __shared String, locale: Locale?, arguments: [any CVarArg]) {
        self = _IsomerFormatter.format(format, arguments)
    }

    public static func localizedStringWithFormat(_ format: String, _ arguments: any CVarArg...) -> String {
        _IsomerFormatter.format(format, arguments)
    }
}

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension StringProtocol {
    public func appendingFormat<T: StringProtocol>(_ format: T, _ arguments: any CVarArg...) -> String {
        String(self) + _IsomerFormatter.format(String(format), arguments)
    }
}

enum _IsomerFormatter {
    struct Spec {
        var flags = ""
        var width: Int?
        var precision: Int?
        var length = ""
        var conversion: Character = "@"
    }

    static func format(_ format: String, _ arguments: [any CVarArg]) -> String {
        var result = ""
        var nextArgument = 0
        let characters = Array(format)
        var index = 0

        func argument(_ position: Int?) -> (any CVarArg)? {
            let at: Int
            if let position {
                at = position - 1
            } else {
                at = nextArgument
                nextArgument += 1
            }
            return at >= 0 && at < arguments.count ? arguments[at] : nil
        }

        func number(_ start: inout Int) -> Int? {
            var value: Int?
            while start < characters.count, let digit = characters[start].wholeNumberValue, characters[start].isASCII {
                value = (value ?? 0) * 10 + digit
                start += 1
            }
            return value
        }

        while index < characters.count {
            let character = characters[index]
            guard character == "%" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else {
                result.append("%")
                break
            }
            if characters[index] == "%" {
                result.append("%")
                index += 1
                continue
            }

            var spec = Spec()
            // A position: digits then "$".
            var position: Int?
            var lookahead = index
            if let value = number(&lookahead), lookahead < characters.count, characters[lookahead] == "$" {
                position = value
                index = lookahead + 1
            }
            while index < characters.count, "-+ #0'".contains(characters[index]) {
                if characters[index] != "'" { spec.flags.append(characters[index]) }
                index += 1
            }
            if index < characters.count, characters[index] == "*" {
                index += 1
                spec.width = argument(nil).flatMap(Self.integer)?.value.map { Int($0) }
            } else {
                spec.width = number(&index)
            }
            if index < characters.count, characters[index] == "." {
                index += 1
                if index < characters.count, characters[index] == "*" {
                    index += 1
                    spec.precision = argument(nil).flatMap(Self.integer)?.value.map { Int($0) }
                } else {
                    spec.precision = number(&index) ?? 0
                }
            }
            while index < characters.count, "hlqLzjt".contains(characters[index]) {
                spec.length.append(characters[index])
                index += 1
            }
            guard index < characters.count else { break }
            spec.conversion = characters[index]
            index += 1

            if spec.conversion == "n" { continue }
            guard let value = argument(position) else { continue }
            result += render(value, spec)
        }
        return result
    }

    static func integer(_ value: any CVarArg) -> (value: Int64?, unsigned: UInt64?)? {
        if let bool = value as? Bool { return (bool ? 1 : 0, bool ? 1 : 0) }
        if let integer = value as? any BinaryInteger {
            return (Int64(truncatingIfNeeded: integer), UInt64(truncatingIfNeeded: integer))
        }
        if let floating = value as? any BinaryFloatingPoint {
            let double = Double(floating)
            return (Int64(exactly: double.rounded(.towardZero)) ?? 0, UInt64(exactly: double.rounded(.towardZero)) ?? 0)
        }
        return nil
    }

    static func padded(_ text: String, _ spec: Spec) -> String {
        var text = text
        if let precision = spec.precision, "@sS".contains(spec.conversion) {
            text = String(text.prefix(precision))
        }
        guard let width = spec.width, text.count < width else { return text }
        let padding = String(repeating: " ", count: width - text.count)
        return spec.flags.contains("-") ? text + padding : padding + text
    }

    static func render(_ value: any CVarArg, _ spec: Spec) -> String {
        switch spec.conversion {
        case "@":
            return padded(String(describing: value), spec)
        case "s", "S":
            if let string = value as? String { return padded(string, spec) }
            if let pointer = value as? UnsafePointer<CChar> { return padded(String(cString: pointer), spec) }
            if let pointer = value as? UnsafeMutablePointer<CChar> { return padded(String(cString: pointer), spec) }
            return padded(String(describing: value), spec)
        case "c", "C":
            if let integer = integer(value)?.unsigned, let scalar = Unicode.Scalar(UInt32(truncatingIfNeeded: integer)) {
                return padded(String(Character(scalar)), spec)
            }
            return padded(String(describing: value), spec)
        case "d", "i", "D":
            guard let number = integer(value)?.value else { return padded(String(describing: value), spec) }
            return printf(spec, "lld", number)
        case "u", "o", "x", "X", "U", "O":
            guard let number = integer(value)?.unsigned else { return padded(String(describing: value), spec) }
            let conversion = String(spec.conversion).lowercased() == "u" ? "u" : String(spec.conversion).lowercased() == "o" ? "o" : String(spec.conversion)
            return printf(spec, "ll" + conversion, number)
        case "f", "F", "e", "E", "g", "G", "a", "A":
            let double: Double
            if let floating = value as? any BinaryFloatingPoint {
                double = Double(floating)
            } else if let number = integer(value)?.value {
                double = Double(number)
            } else {
                return padded(String(describing: value), spec)
            }
            return printf(spec, String(spec.conversion), double)
        case "p":
            if let integer = integer(value)?.unsigned {
                return padded("0x" + String(integer, radix: 16), spec)
            }
            return padded(String(describing: value), spec)
        default:
            return padded(String(describing: value), spec)
        }
    }

    /// One conversion through the C library.
    static func printf(_ spec: Spec, _ conversion: String, _ value: any CVarArg) -> String {
        var format = "%" + spec.flags
        if let width = spec.width { format += String(width) }
        if let precision = spec.precision { format += "." + String(precision) }
        format += conversion
        var capacity = 128
        while true {
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: capacity)
            defer { buffer.deallocate() }
            let written = format.withCString { cFormat in
                withVaList([value]) { list in
                    vsnprintf(buffer, capacity, cFormat, list)
                }
            }
            if written < 0 { return "" }
            if Int(written) < capacity {
                return String(cString: buffer)
            }
            capacity = Int(written) + 1
        }
    }
}

