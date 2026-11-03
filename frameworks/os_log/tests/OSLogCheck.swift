import OSLog

// OSLog's Logger under WASI: messages to standard error, formats applied
// (run_foundation_check.sh reads the output for "FAIL" and "ok").

@main
struct OSLogCheck {
    static func main() {
        let logger = Logger(subsystem: "dev.isomer.check", category: "oslog")
        let count = 42, ratio = 0.5, name = "app"
        logger.info("count \(count, privacy: .public) hex \(255, format: .hex(includePrefix: true)) ratio \(ratio, format: .fixed(precision: 2))")
        logger.error("name \(name, align: .right(columns: 5), privacy: .private(mask: .hash)) flag \(true, format: .answer) type \(Int.self)")
        Logger(.disabled).fault("never shown")
        print("ok")
    }
}
