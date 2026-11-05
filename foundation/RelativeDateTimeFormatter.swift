// RelativeDateTimeFormatter: a date relative to another as words ("2 hours
// ago", "in 3 days", "yesterday"), by the largest unit that differs. A
// Swift class, as Isomer's other formatters are (Apple's is a Formatter),
// and English whatever the locale: Isomer's Foundation formats without ICU
// unless an app asks for it (docs/parity/Foundation.md).

import FoundationEssentials

open class RelativeDateTimeFormatter: @unchecked Sendable {
    /// Numbers ("1 day ago"), or the names a language has for some of them
    /// ("yesterday", "last week", "now").
    public enum DateTimeStyle: Int, Sendable {
        case numeric = 0
        case named = 1
    }

    /// "2 hours", "two hours", "2 hr.", "2h".
    public enum UnitsStyle: Int, Sendable {
        case full = 0
        case spellOut = 1
        case short = 2
        case abbreviated = 3
    }

    open var dateTimeStyle: DateTimeStyle = .numeric
    open var unitsStyle: UnitsStyle = .full
    open var calendar: Calendar! = .current
    open var locale: Locale! = .current

    public init() {}

    /// The largest of the components' year, month, week, day, hour, minute
    /// and second that isn't zero, as a time from now ("in 2 days") or
    /// before it ("2 days ago"); none: "in 0 seconds", or "now".
    open func localizedString(from dateComponents: DateComponents) -> String {
        let units: [(Unit, Int?)] = [
            (.year, dateComponents.year), (.month, dateComponents.month),
            (.week, dateComponents.weekOfMonth ?? dateComponents.weekOfYear), (.day, dateComponents.day),
            (.hour, dateComponents.hour), (.minute, dateComponents.minute), (.second, dateComponents.second),
        ]
        for (unit, value) in units {
            if let value, value != 0 { return phrase(value, unit) }
        }
        return phrase(0, .second)
    }

    open func localizedString(fromTimeInterval timeInterval: TimeInterval) -> String {
        let now = Date()
        return localizedString(for: now.addingTimeInterval(timeInterval), relativeTo: now)
    }

    open func localizedString(for date: Date, relativeTo referenceDate: Date) -> String {
        let calendar: Calendar = self.calendar ?? .current
        let components = calendar.dateComponents([.year, .month, .weekOfMonth, .day, .hour, .minute, .second],
                                                 from: referenceDate, to: date)
        return localizedString(from: components)
    }

    /// A date relative to now; nil for anything else.
    open func string(for obj: Any?) -> String? {
        guard let date = obj as? Date else { return nil }
        return localizedString(for: date, relativeTo: Date())
    }

    // MARK: English

    enum Unit {
        case year, month, week, day, hour, minute, second
    }

    func phrase(_ value: Int, _ unit: Unit) -> String {
        if dateTimeStyle == .named, let named = named(value, unit) { return named }
        let amount = quantity(abs(value), unit)
        return value < 0 ? "\(amount) ago" : "in \(amount)"
    }

    func named(_ value: Int, _ unit: Unit) -> String? {
        switch (unit, value) {
        case (.second, 0): return "now"
        case (.day, -1): return "yesterday"
        case (.day, 1): return "tomorrow"
        case (.week, -1): return "last week"
        case (.week, 1): return "next week"
        case (.month, -1): return "last month"
        case (.month, 1): return "next month"
        case (.year, -1): return "last year"
        case (.year, 1): return "next year"
        default: return nil
        }
    }

    func quantity(_ count: Int, _ unit: Unit) -> String {
        let (word, short, letter): (String, String, String)
        switch unit {
        case .year: (word, short, letter) = ("year", "yr.", "y")
        case .month: (word, short, letter) = ("month", "mo.", "mo")
        case .week: (word, short, letter) = ("week", "wk.", "w")
        case .day: (word, short, letter) = ("day", count == 1 ? "day" : "days", "d")
        case .hour: (word, short, letter) = ("hour", "hr.", "h")
        case .minute: (word, short, letter) = ("minute", "min.", "m")
        case .second: (word, short, letter) = ("second", "sec.", "s")
        }
        let plural = count == 1 ? word : word + "s"
        switch unitsStyle {
        case .full: return "\(count) \(plural)"
        case .spellOut: return "\(spelledOut(count)) \(plural)"
        case .short: return "\(count) \(short)"
        case .abbreviated: return "\(count)\(letter)"
        }
    }

    /// English words for a count ("twenty-one"); digits from a million up.
    func spelledOut(_ number: Int) -> String {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        switch number {
        case 0..<20: return ones[number]
        case 20..<100: return tens[number / 10] + (number % 10 == 0 ? "" : "-" + ones[number % 10])
        case 100..<1000:
            return ones[number / 100] + " hundred" + (number % 100 == 0 ? "" : " " + spelledOut(number % 100))
        case 1000..<1_000_000:
            return spelledOut(number / 1000) + " thousand" + (number % 1000 == 0 ? "" : " " + spelledOut(number % 1000))
        default: return String(number)
        }
    }
}
