// A model file the way a SwiftPM package writes one: Foundation only. Its
// URL/Date must be the SAME types the views' `import SwiftUI` sees.

import Foundation

struct Attachment: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let receivedAt: Date

    init(urlString: String) {
        id = UUID()
        url = URL(string: urlString)!
        receivedAt = Date()
    }

    var ageSeconds: Double { Date().timeIntervalSince(receivedAt) }

    /// The inbox's time column: today → "Mon 14:05", else the day.
    var timeLabel: String {
        let calendar = Calendar.current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: receivedAt)
        let weekday = calendar.shortWeekdaySymbols[(parts.weekday ?? 1) - 1]
        if calendar.isDate(receivedAt, inSameDayAs: Date()) {
            return "\(weekday) \(parts.hour ?? 0):\(String(format2: parts.minute ?? 0))"
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: Date())!
        return calendar.isDate(receivedAt, inSameDayAs: yesterday) ? "Yesterday" : "\(parts.month ?? 0)/\(parts.day ?? 0)"
    }
}

extension String {
    /// Two-digit minutes without Foundation's formatting.
    init(format2 value: Int) { self = value < 10 ? "0\(value)" : "\(value)" }
}
