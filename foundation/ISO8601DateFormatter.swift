// ISO8601DateFormatter (Apple's Foundation and corelibs have it;
// swift-foundation has the format style it is written over): a date as
// ISO 8601 text and back, its fields and separators chosen by `formatOptions`.
// A Swift class, as Isomer's other Foundation classes are (Apple's is a
// Formatter).

import FoundationEssentials

open class ISO8601DateFormatter: @unchecked Sendable {
    /// Which fields the text has, and how they are separated (Apple's raw
    /// values, CFISO8601DateFormatOptions).
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }

        public static var withYear: Options { Options(rawValue: 1 << 0) }
        public static var withMonth: Options { Options(rawValue: 1 << 1) }
        public static var withWeekOfYear: Options { Options(rawValue: 1 << 2) }
        public static var withDay: Options { Options(rawValue: 1 << 4) }
        public static var withTime: Options { Options(rawValue: 1 << 5) }
        public static var withTimeZone: Options { Options(rawValue: 1 << 6) }
        public static var withSpaceBetweenDateAndTime: Options { Options(rawValue: 1 << 7) }
        public static var withDashSeparatorInDate: Options { Options(rawValue: 1 << 8) }
        public static var withColonSeparatorInTime: Options { Options(rawValue: 1 << 9) }
        public static var withColonSeparatorInTimeZone: Options { Options(rawValue: 1 << 10) }
        public static var withFractionalSeconds: Options { Options(rawValue: 1 << 11) }
        public static var withFullDate: Options { [.withYear, .withMonth, .withDay, .withDashSeparatorInDate] }
        public static var withFullTime: Options { [.withTime, .withColonSeparatorInTime, .withTimeZone, .withColonSeparatorInTimeZone] }
        public static var withInternetDateTime: Options { [.withFullDate, .withFullTime] }
    }

    /// The time zone the text is in (GMT unless set).
    open var timeZone: TimeZone! = TimeZone(secondsFromGMT: 0)
    open var formatOptions: Options = .withInternetDateTime

    public init() {}

    open func string(from date: Date) -> String {
        Self.style(formatOptions, timeZone ?? TimeZone(secondsFromGMT: 0)!).format(date)
    }

    /// The date the text says, or nil when it isn't one in these options.
    open func date(from string: String) -> Date? {
        try? Self.style(formatOptions, timeZone ?? TimeZone(secondsFromGMT: 0)!).parse(string)
    }

    open class func string(from date: Date, timeZone: TimeZone, formatOptions: Options = []) -> String {
        style(formatOptions, timeZone).format(date)
    }

    /// The format style the options say: its separators, then its fields
    /// (a style given no field writes every one).
    private static func style(_ options: Options, _ timeZone: TimeZone) -> Date.ISO8601FormatStyle {
        var style = Date.ISO8601FormatStyle(
            dateSeparator: options.contains(.withDashSeparatorInDate) ? .dash : .omitted,
            dateTimeSeparator: options.contains(.withSpaceBetweenDateAndTime) ? .space : .standard,
            timeSeparator: options.contains(.withColonSeparatorInTime) ? .colon : .omitted,
            timeZoneSeparator: options.contains(.withColonSeparatorInTimeZone) ? .colon : .omitted,
            includingFractionalSeconds: options.contains(.withFractionalSeconds),
            timeZone: timeZone)
        if options.contains(.withYear) { style = style.year() }
        if options.contains(.withWeekOfYear) { style = style.weekOfYear() }
        if options.contains(.withMonth) { style = style.month() }
        if options.contains(.withDay) { style = style.day() }
        if options.contains(.withTime) { style = style.time(includingFractionalSeconds: options.contains(.withFractionalSeconds)) }
        if options.contains(.withTimeZone) {
            style = style.timeZone(separator: options.contains(.withColonSeparatorInTimeZone) ? .colon : .omitted)
        }
        return style
    }
}
