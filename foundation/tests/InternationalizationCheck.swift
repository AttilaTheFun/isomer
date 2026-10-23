// Isomer's Foundation with FoundationInternationalization (built with
// --@isomer//foundation:internationalization): formatting, locales,
// calendars and time zones through ICU, run under WasmKit. Prints "FAIL …" for
// a wrong answer and "ok" at the end.

import Foundation

@main
enum InternationalizationCheck {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !condition {
            failures += 1
            print("FAIL \(name) \(detail())")
        }
    }

    static func main() {
        let number = 1234567.891
        let us = number.formatted(.number.locale(Locale(identifier: "en_US")))
        check(us == "1,234,567.891", "number en_US", us)
        let fr = number.formatted(.number.locale(Locale(identifier: "fr_FR")))
        check(fr.hasPrefix("1") && fr.contains(",891"), "number fr_FR", fr)
        let de = number.formatted(.number.locale(Locale(identifier: "de_DE")))
        check(de == "1.234.567,891", "number de_DE", de)

        let percent = 0.256.formatted(.percent.locale(Locale(identifier: "en_US")))
        check(percent == "25.6%", "percent", percent)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 9, minute: 30))!
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: "en_US"),
                                     calendar: calendar, timeZone: calendar.timeZone)
        let formatted = date.formatted(style)
        check(formatted.contains("Oct 12, 2026") && formatted.contains("9:30"), "date en_US", formatted)
        let french = date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: Locale(identifier: "fr_FR"),
                                                     calendar: calendar, timeZone: calendar.timeZone))
        check(french == "12 octobre 2026", "date fr_FR", french)

        let tokyo = TimeZone(identifier: "Asia/Tokyo")
        check(tokyo?.secondsFromGMT(for: date) == 9 * 3600, "Asia/Tokyo offset", "\(String(describing: tokyo?.secondsFromGMT(for: date)))")
        #if TRIMMED_TO_EN_FR_DE
        // Japanese's data is left out: its names fall back to root's.
        check(Locale(identifier: "ja_JP").localizedString(forLanguageCode: "en") != "英語", "trimmed: no Japanese names",
              Locale(identifier: "ja_JP").localizedString(forLanguageCode: "en") ?? "nil")
        check(Locale(identifier: "fr_FR").localizedString(forLanguageCode: "en") == "anglais", "localized language name",
              Locale(identifier: "fr_FR").localizedString(forLanguageCode: "en") ?? "nil")
        #else
        check(Locale(identifier: "ja_JP").localizedString(forLanguageCode: "en") == "英語", "localized language name",
              Locale(identifier: "ja_JP").localizedString(forLanguageCode: "en") ?? "nil")
        #endif

        let measurement = (12.5).formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
        check(measurement == "12.50", "precision", measurement)

        if failures == 0 { print("ok") }
    }
}
