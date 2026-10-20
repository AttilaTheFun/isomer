// Small public calendar helpers used by sample apps (Date Planner). The core
// links no Foundation, so day/time math is computed directly from the epoch in
// UTC via Howard Hinnant's civil-from-days algorithm. Apple's IsomerBridge
// provides the same-signature helpers backed by a UTC `Foundation.Calendar`, so
// app source using them compiles unchanged on every platform.

import Foundation

public struct DateParts: Equatable, Sendable {
    public let year: Int
    public let month: Int   // 1...12
    public let day: Int     // 1...31
    public let hour: Int    // 0...23
    public let minute: Int  // 0...59
    public let weekday: Int // 0 = Sunday ... 6 = Saturday
}

private func floorDiv(_ a: Int, _ b: Int) -> Int {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

private func floorMod(_ a: Int, _ b: Int) -> Int {
    let r = a % b
    return r < 0 ? r + b : r
}

private let monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]
private let weekdayNames = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
]

/// Decompose a date into UTC calendar fields.
public func dateParts(_ date: Date) -> DateParts {
    let seconds = Int(date.timeIntervalSince1970.rounded(.down))
    let days = floorDiv(seconds, 86400)
    let secOfDay = floorMod(seconds, 86400)

    let z = days + 719468
    let era = (z >= 0 ? z : z - 146096) / 146097
    let doe = z - era * 146097
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    let y = yoe + era * 400
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
    let mp = (5 * doy + 2) / 153
    let d = doy - (153 * mp + 2) / 5 + 1
    let m = mp < 10 ? mp + 3 : mp - 9
    let year = m <= 2 ? y + 1 : y

    // 1970-01-01 was a Thursday (weekday index 4 with Sunday = 0).
    let weekday = floorMod(days + 4, 7)
    return DateParts(
        year: year, month: m, day: d,
        hour: secOfDay / 3600, minute: (secOfDay % 3600) / 60, weekday: weekday)
}

/// Build a UTC date from calendar fields.
public func makeDate(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
) -> Date {
    let y = month <= 2 ? year - 1 : year
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let mp = month > 2 ? month - 3 : month + 9
    let doy = (153 * mp + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468
    let seconds = days * 86400 + hour * 3600 + minute * 60
    return Date(timeIntervalSince1970: Double(seconds))
}

/// Midnight (UTC) of the date's day — the grouping key for a day's events.
public func startOfDay(_ date: Date) -> Date {
    let p = dateParts(date)
    return makeDate(year: p.year, month: p.month, day: p.day)
}

/// "Wednesday, January 1" — a section header for a day.
public func dayHeadline(_ date: Date) -> String {
    let p = dateParts(date)
    return "\(weekdayNames[p.weekday]), \(monthNames[p.month - 1]) \(p.day)"
}

/// "Jan 1, 2024" — a compact date label.
public func shortDate(_ date: Date) -> String {
    let p = dateParts(date)
    return "\(monthNames[p.month - 1].prefix(3)) \(p.day), \(p.year)"
}

/// "2:30 PM" — a 12-hour clock label.
public func timeOfDay(_ date: Date) -> String {
    let p = dateParts(date)
    let isPM = p.hour >= 12
    var h = p.hour % 12
    if h == 0 { h = 12 }
    let mm = p.minute < 10 ? "0\(p.minute)" : "\(p.minute)"
    return "\(h):\(mm) \(isPM ? "PM" : "AM")"
}
