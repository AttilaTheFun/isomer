// Calendar's symbol lists without FoundationInternationalization: English,
// as the `en_US_POSIX` locale names them, whatever the calendar's locale.
// With `--@isomer//foundation:internationalization` the lists are ICU's,
// localized, and these are not compiled (docs/parity/Foundation.md).

#if !ISOMER_FOUNDATION_INTERNATIONALIZATION
import FoundationEssentials

extension Calendar {
    public var eraSymbols: [String] { ["BC", "AD"] }
    public var longEraSymbols: [String] { ["Before Christ", "Anno Domini"] }

    public var monthSymbols: [String] {
        ["January", "February", "March", "April", "May", "June", "July", "August", "September",
         "October", "November", "December"]
    }
    public var shortMonthSymbols: [String] {
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    }
    public var veryShortMonthSymbols: [String] {
        ["J", "F", "M", "A", "M", "J", "J", "A", "S", "O", "N", "D"]
    }
    public var standaloneMonthSymbols: [String] { monthSymbols }
    public var shortStandaloneMonthSymbols: [String] { shortMonthSymbols }
    public var veryShortStandaloneMonthSymbols: [String] { veryShortMonthSymbols }

    public var weekdaySymbols: [String] {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
    }
    public var shortWeekdaySymbols: [String] { ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"] }
    public var veryShortWeekdaySymbols: [String] { ["S", "M", "T", "W", "T", "F", "S"] }
    public var standaloneWeekdaySymbols: [String] { weekdaySymbols }
    public var shortStandaloneWeekdaySymbols: [String] { shortWeekdaySymbols }
    public var veryShortStandaloneWeekdaySymbols: [String] { veryShortWeekdaySymbols }

    public var quarterSymbols: [String] { ["1st quarter", "2nd quarter", "3rd quarter", "4th quarter"] }
    public var shortQuarterSymbols: [String] { ["Q1", "Q2", "Q3", "Q4"] }
    public var standaloneQuarterSymbols: [String] { quarterSymbols }
    public var shortStandaloneQuarterSymbols: [String] { shortQuarterSymbols }

    public var amSymbol: String { "AM" }
    public var pmSymbol: String { "PM" }
}
#endif
