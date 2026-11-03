// OSLog's Logger for the platforms without Apple's (wasm, Android, Linux,
// Windows): `Logger(subsystem:category:)` and its levels, messages written
// with string interpolation as Apple's are, to logcat on Android (the
// category as the tag) and to standard error elsewhere (a browser's console
// on the web). The interpolation takes Apple's `privacy:`, `format:` and
// `align:` arguments; privacy is accepted and not acted on (nothing is
// redacted: the log stays on the device, as a debug build's does), and the
// formats are applied. No log store to read back (OSLogStore), signposts or
// `os_log`'s C-style formats.

#if canImport(Android)
import Android
#endif
import Foundation

/// A message's level.
public struct OSLogType: Equatable, RawRepresentable, Sendable {
    public let rawValue: UInt8
    public init(_ rawValue: UInt8) { self.rawValue = rawValue }
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let `default` = OSLogType(0x00)
    public static let info = OSLogType(0x01)
    public static let debug = OSLogType(0x02)
    public static let error = OSLogType(0x10)
    public static let fault = OSLogType(0x11)
}

/// Where a Logger writes: a subsystem and a category.
public final class OSLog: @unchecked Sendable {
    let subsystem: String
    let category: String
    let enabled: Bool

    public init(subsystem: String, category: String) {
        self.subsystem = subsystem
        self.category = category
        enabled = true
    }

    private init(disabled: Bool) {
        subsystem = ""
        category = ""
        enabled = !disabled
    }

    public static let `default` = OSLog(disabled: false)
    public static let disabled = OSLog(disabled: true)
}

/// Whether an interpolated value may be shown: accepted, not acted on.
public struct OSLogPrivacy: Equatable, Sendable {
    public enum Mask: Equatable, Sendable {
        case hash
        case none
    }

    let kind: UInt8
    let mask: Mask

    public static let auto = OSLogPrivacy(kind: 0, mask: .none)
    public static let `public` = OSLogPrivacy(kind: 1, mask: .none)
    public static let `private` = OSLogPrivacy(kind: 2, mask: .none)
    public static let sensitive = OSLogPrivacy(kind: 3, mask: .none)
    public static func auto(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 0, mask: mask) }
    public static func `private`(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 2, mask: mask) }
    public static func sensitive(mask: Mask) -> OSLogPrivacy { OSLogPrivacy(kind: 3, mask: mask) }
}

/// A string's alignment in a column of `columns` characters.
public struct OSLogStringAlignment: Sendable {
    let columns: Int
    let leftAligned: Bool

    public static let none = OSLogStringAlignment(columns: 0, leftAligned: false)
    public static func right(columns: @autoclosure @escaping () -> Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: columns(), leftAligned: false)
    }
    public static func left(columns: @autoclosure @escaping () -> Int) -> OSLogStringAlignment {
        OSLogStringAlignment(columns: columns(), leftAligned: true)
    }

    func apply(_ text: String) -> String {
        guard columns > text.count else { return text }
        let padding = String(repeating: " ", count: columns - text.count)
        return leftAligned ? text + padding : padding + text
    }
}

/// How an integer is written.
public struct OSLogIntegerFormatting: Sendable {
    let radix: Int
    let prefix: Bool
    let uppercase: Bool
    let sign: Bool
    let minDigits: Int

    public static let decimal = OSLogIntegerFormatting(radix: 10, prefix: false, uppercase: false, sign: false, minDigits: 0)
    public static let hex = OSLogIntegerFormatting(radix: 16, prefix: false, uppercase: false, sign: false, minDigits: 0)
    public static let octal = OSLogIntegerFormatting(radix: 8, prefix: false, uppercase: false, sign: false, minDigits: 0)

    public static func decimal(explicitPositiveSign: Bool = false, minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 10, prefix: false, uppercase: false, sign: explicitPositiveSign, minDigits: minDigits())
    }
    public static func decimal(explicitPositiveSign: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 10, prefix: false, uppercase: false, sign: explicitPositiveSign, minDigits: 0)
    }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false,
                           minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 16, prefix: includePrefix, uppercase: uppercase, sign: explicitPositiveSign, minDigits: minDigits())
    }
    public static func hex(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 16, prefix: includePrefix, uppercase: uppercase, sign: explicitPositiveSign, minDigits: 0)
    }
    public static func octal(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false,
                             minDigits: @autoclosure @escaping () -> Int) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 8, prefix: includePrefix, uppercase: uppercase, sign: explicitPositiveSign, minDigits: minDigits())
    }
    public static func octal(explicitPositiveSign: Bool = false, includePrefix: Bool = false, uppercase: Bool = false) -> OSLogIntegerFormatting {
        OSLogIntegerFormatting(radix: 8, prefix: includePrefix, uppercase: uppercase, sign: explicitPositiveSign, minDigits: 0)
    }

    func apply<T: BinaryInteger>(_ value: T) -> String {
        var digits = String(value.magnitude, radix: radix, uppercase: uppercase)
        if digits.count < minDigits { digits = String(repeating: "0", count: minDigits - digits.count) + digits }
        if prefix { digits = (radix == 16 ? "0x" : "0o") + digits }
        if value < 0 { return "-" + digits }
        return sign ? "+" + digits : digits
    }
}

/// How a floating-point number is written.
public struct OSLogFloatFormatting: Sendable {
    let style: UInt8
    let precision: Int?
    let sign: Bool

    public static let fixed = OSLogFloatFormatting(style: 0, precision: nil, sign: false)
    public static let hex = OSLogFloatFormatting(style: 1, precision: nil, sign: false)
    public static let exponential = OSLogFloatFormatting(style: 2, precision: nil, sign: false)
    public static let hybrid = OSLogFloatFormatting(style: 3, precision: nil, sign: false)

    public static func fixed(precision: @autoclosure @escaping () -> Int, explicitPositiveSign: Bool = false,
                             uppercase: Bool = false) -> OSLogFloatFormatting {
        OSLogFloatFormatting(style: 0, precision: precision(), sign: explicitPositiveSign)
    }
    public static func fixed(explicitPositiveSign: Bool = false, uppercase: Bool = false) -> OSLogFloatFormatting {
        OSLogFloatFormatting(style: 0, precision: nil, sign: explicitPositiveSign)
    }

    func apply(_ value: Double) -> String {
        let text: String
        switch style {
        case 0: text = String(format: "%.\(precision ?? 6)f", value)
        case 1: text = String(format: "%a", value)
        case 2: text = String(format: "%e", value)
        default: text = "\(value)"
        }
        return sign && value >= 0 ? "+" + text : text
    }
}

/// How a Bool is written: true/false, or YES/NO.
public enum OSLogBoolFormat: Sendable {
    case truth
    case answer
}

/// A message's text, built by string interpolation.
public struct OSLogInterpolation: StringInterpolationProtocol {
    var text = ""

    public init(literalCapacity: Int, interpolationCount: Int) {
        text.reserveCapacity(literalCapacity + interpolationCount * 8)
    }

    public mutating func appendLiteral(_ literal: String) { text += literal }

    public mutating func appendInterpolation(_ argumentString: @autoclosure @escaping () -> String, align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(argumentString())
    }

    public mutating func appendInterpolation<T>(_ value: @autoclosure @escaping () -> T, align: OSLogStringAlignment = .none,
                                                privacy: OSLogPrivacy = .auto) where T: CustomStringConvertible {
        text += align.apply(value().description)
    }

    public mutating func appendInterpolation<T>(_ number: @autoclosure @escaping () -> T, format: OSLogIntegerFormatting = .decimal,
                                                align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto)
        where T: FixedWidthInteger {
        text += align.apply(format.apply(number()))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Double, format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        text += align.apply(format.apply(number()))
    }

    public mutating func appendInterpolation(_ number: @autoclosure @escaping () -> Float, format: OSLogFloatFormatting = .fixed,
                                             align: OSLogStringAlignment = .none, privacy: OSLogPrivacy = .auto) {
        text += align.apply(format.apply(Double(number())))
    }

    public mutating func appendInterpolation(_ boolean: @autoclosure @escaping () -> Bool, format: OSLogBoolFormat = .truth,
                                             privacy: OSLogPrivacy = .auto) {
        let value = boolean()
        text += format == .answer ? (value ? "YES" : "NO") : (value ? "true" : "false")
    }

    public mutating func appendInterpolation(_ value: @autoclosure @escaping () -> Any.Type, align: OSLogStringAlignment = .none,
                                             privacy: OSLogPrivacy = .auto) {
        text += align.apply(String(describing: value()))
    }

    public mutating func appendInterpolation(_ argumentObject: @autoclosure @escaping () -> NSObject, privacy: OSLogPrivacy = .auto) {
        text += argumentObject().description
    }
}

/// A Logger's message: a string literal, interpolated.
public struct OSLogMessage: ExpressibleByStringInterpolation, ExpressibleByStringLiteral {
    let text: String

    public init(stringInterpolation: OSLogInterpolation) { text = stringInterpolation.text }
    public init(stringLiteral value: String) { text = value }
}

/// Writes messages for a subsystem and category, at a level each.
public struct Logger: @unchecked Sendable {
    let log: OSLog

    public init(subsystem: String, category: String) { log = OSLog(subsystem: subsystem, category: category) }
    public init(_ logObj: OSLog) { log = logObj }
    public init() { log = .default }

    public func log(_ message: OSLogMessage) { write(.default, message.text) }
    public func log(level: OSLogType, _ message: OSLogMessage) { write(level, message.text) }
    public func trace(_ message: OSLogMessage) { write(.debug, message.text) }
    public func debug(_ message: OSLogMessage) { write(.debug, message.text) }
    public func info(_ message: OSLogMessage) { write(.info, message.text) }
    public func notice(_ message: OSLogMessage) { write(.default, message.text) }
    public func warning(_ message: OSLogMessage) { write(.error, message.text) }
    public func error(_ message: OSLogMessage) { write(.error, message.text) }
    public func critical(_ message: OSLogMessage) { write(.fault, message.text) }
    public func fault(_ message: OSLogMessage) { write(.fault, message.text) }

    private func write(_ level: OSLogType, _ text: String) {
        guard log.enabled else { return }
        #if canImport(Android)
        // Android's priorities: DEBUG 3, INFO 4, WARN 5, ERROR 6, FATAL 7.
        let priority: Int32 = switch level {
        case .debug: 3
        case .info, .default: 4
        case .error: 6
        default: 7
        }
        let tag = log.category.isEmpty ? (log.subsystem.isEmpty ? "Logger" : log.subsystem) : log.category
        _ = __android_log_write(priority, tag, text)
        #else
        let label = switch level {
        case .debug: "debug"
        case .info: "info"
        case .error: "error"
        case .fault: "fault"
        default: "notice"
        }
        let place = log.subsystem.isEmpty ? "" : "[\(log.subsystem)\(log.category.isEmpty ? "" : ":\(log.category)")] "
        FileHandle.standardError.write(Data("\(place)\(label): \(text)\n".utf8))
        #endif
    }
}
