// The CLI host: raw-mode keyboard loop + host bridge for the
// TerminalRenderer. A CLI app is an `@main App`, as on every platform;
// `App.main()` runs `TerminalApp`, which owns the terminal until the user
// quits (Ctrl-C / q with no focused field):
//
//   Tab / ↓ / →     focus next tappable / text field
//   Shift-Tab / ↑ / ← focus previous
//   Return           activate the focused control
//   printable keys   edit the focused text field (Backspace deletes)
//
// One-shot mode (`ISO_TERM_ONESHOT=1`) renders a single frame to stdout and
// exits — the headless verification hook.

#if !canImport(WASILibc)

internal import IsomerSwiftUI
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The service half for a terminal: character-cell text metrics, no images.
final class TerminalHostBridge: HostBridge {
    func measureText(_ text: String, fontSize: Double, weight: Int, wrapWidth: Double?) -> CGSize {
        // One cell ≈ 8x16pt, matching the renderer's integer-cell layout.
        let columns = Double(text.count)
        if let wrapWidth, wrapWidth > 0, columns * 8 > wrapWidth {
            let perLine = max(1, Int(wrapWidth / 8))
            let lines = (text.count + perLine - 1) / perLine
            return CGSize(width: wrapWidth, height: Double(lines) * 16)
        }
        return CGSize(width: columns * 8, height: 16)
    }

    func imageInfo(_ source: String, isRemote: Bool) -> ImageStatus { .failed }
    func syncHostViews(_ viewsJSON: String) {}
    func beginTextInput(_ text: String, in rect: CGRect, fontSize: Double) {}
    func endTextInput() {}
    func scheduleRender() { TerminalApp.needsRender = true }
    func now() -> Double { Double(clockMillis()) / 1000 }
    func log(_ message: String) { FileHandle.standardErrorWrite("[iso] \(message)\n") }
}

enum FileHandle {
    static func standardErrorWrite(_ string: String) {
        string.utf8CString.withUnsafeBufferPointer { buffer in
            _ = write(2, buffer.baseAddress, buffer.count - 1)
        }
    }
}

private func clockMillis() -> Int64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
}

/// Not Apple's, so not public: `App.main()` calls it (ISOMER_CLI_HOST).
enum TerminalApp {
    static var needsRender = false

    /// Runs the installed app in the terminal until quit, or renders one
    /// frame to stdout and returns with `ISO_TERM_ONESHOT=1`.
    @MainActor
    static func run() {
        let renderer = TerminalRenderer()
        var window = winsize()
        if ioctl(1, TIOCGWINSZ, &window) == 0, window.ws_col > 0 {
            renderer.columns = Int(window.ws_col)
            renderer.rows = Int(window.ws_row) - 1
        }
        if getenv("ISO_DARK") != nil {
            Runtime.shared.setSystemColorScheme(dark: true)
        }
        Renderer.bind(renderer)
        let single = getenv("ISO_TERM_ONESHOT") != nil

        if single {
            Runtime.shared.start(
                host: TerminalHostBridge(),
                width: Double(renderer.columns * 8), height: Double(renderer.rows * 16))
            return
        }

        // Raw mode: keys arrive unbuffered and unechoed; restored on exit.
        var original = termios()
        tcgetattr(0, &original)
        var raw = original
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        tcsetattr(0, TCSANOW, &raw)
        defer { tcsetattr(0, TCSANOW, &original) }
        print("\u{1B}[2J", terminator: "") // clear once; frames repaint in place

        Runtime.shared.start(
            host: TerminalHostBridge(),
            width: Double(renderer.columns * 8), height: Double(renderer.rows * 16))

        var running = true
        while running {
            var byte: UInt8 = 0
            guard read(0, &byte, 1) == 1 else { break }
            switch byte {
            case 0x09: // Tab
                renderer.focusNext(1)
            case 0x0D, 0x0A: // Return
                renderer.activateFocused()
            case 0x7F, 0x08: // Backspace
                _ = renderer.type(" ", backspace: true)
            case 0x1B: // ESC sequences (arrows) or bare ESC
                var seq = [UInt8](repeating: 0, count: 2)
                if read(0, &seq, 2) == 2, seq[0] == 0x5B {
                    switch seq[1] {
                    case 0x41, 0x44: renderer.focusNext(-1) // Up / Left
                    case 0x42, 0x43: renderer.focusNext(1) // Down / Right
                    case 0x5A: renderer.focusNext(-1) // Shift-Tab
                    default: break
                    }
                }
            case 0x03: // Ctrl-C
                running = false
            default:
                let character = Character(UnicodeScalar(byte))
                let consumed = renderer.type(character, backspace: false)
                if !consumed, byte == UInt8(ascii: "q") {
                    running = false
                }
            }
            // Focus changes are host-side state; input may also have
            // triggered guest renders (setNeedsRender). Re-render either way.
            Runtime.shared.renderFrame()
        }
        print("\u{1B}[0m")
    }
}

#endif
