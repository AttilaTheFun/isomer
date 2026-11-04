import os

// `import os` alone gives Logger, as on Apple platforms (this file imports
// nothing else).

enum OSCheck {
    static func log() {
        Logger(subsystem: "dev.isomer.check", category: "os").notice("from import os")
    }
}
