import Foundation

extension FoundationCheck {
    /// RelativeDateTimeFormatter, against a fixed reference date.
    static func checkRelativeDates() {
        let reference = Date(timeIntervalSince1970: 1_000_000_000)
        let formatter = RelativeDateTimeFormatter()
        func relative(_ seconds: TimeInterval) -> String {
            formatter.localizedString(for: reference.addingTimeInterval(seconds), relativeTo: reference)
        }
        check("relative past", relative(-7200), "2 hours ago")
        check("relative future", relative(3 * 86_400), "in 3 days")
        check("relative zero", relative(0), "in 0 seconds")
        formatter.dateTimeStyle = .named
        check("relative named", relative(-86_400), "yesterday")
        check("relative now", relative(0), "now")
        check("relative named hours", relative(-3600), "1 hour ago")
        formatter.dateTimeStyle = .numeric
        formatter.unitsStyle = .short
        check("relative short", relative(-7200), "2 hr. ago")
        formatter.unitsStyle = .abbreviated
        check("relative abbreviated", relative(120), "in 2m")
        formatter.unitsStyle = .spellOut
        check("relative spelled", relative(-21 * 60), "twenty-one minutes ago")
        var components = DateComponents()
        components.weekOfMonth = -2
        formatter.unitsStyle = .full
        check("relative components", formatter.localizedString(from: components), "2 weeks ago")
    }
}
