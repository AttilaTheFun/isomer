import OSLog

// OSLog's Logger under WASI: messages to standard error, formats applied
// (run_foundation_check.sh reads the output for "FAIL" and "ok").

/// A plain error: written as `String(describing:)` writes it.
enum PlainError: Error { case missing(String) }

/// An error that describes itself: the CustomStringConvertible overload.
struct DescribedError: Error, CustomStringConvertible {
    var description: String { "described" }
}

@main
struct OSLogCheck {
    static func main() {
        let logger = Logger(subsystem: "dev.isomer.check", category: "oslog")
        let count = 42, ratio = 0.5, name = "app"
        logger.info("count \(count, privacy: .public) hex \(255, format: .hex(includePrefix: true)) ratio \(ratio, format: .fixed(precision: 2))")
        logger.error("name \(name, align: .right(columns: 5), privacy: .private(mask: .hash)) flag \(true, format: .answer) type \(Int.self)")
        Logger(.disabled).fault("never shown")
        let plain: any Error = PlainError.missing("key"), noError: (any Error)? = nil
        logger.error("plain \(plain, privacy: .public) concrete \(PlainError.missing("x")) described \(DescribedError()) none \(noError)")
        OSCheck.log()
        print("ok")
    }
}
