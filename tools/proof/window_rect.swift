// The frontmost window of one of the named apps, as `x y width height` in
// the screen's pixels: what the proof crops a Mac's screenshot to, so the
// menu bar's clock, the desktop and where macOS put the window don't count.
// Bounds come from CoreGraphics' window list, which needs no Accessibility
// or Screen Recording permission. Run in the GUI session
// (`sudo launchctl asuser $(id -u runner) window_rect Storybook Playground`).

import CoreGraphics
import Foundation

let owners = Set(CommandLine.arguments.dropFirst())
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
guard let window = windows.first(where: { window in
          (window[kCGWindowLayer as String] as? Int) == 0 && owners.contains(window[kCGWindowOwnerName as String] as? String ?? "")
      }),
      let bounds = window[kCGWindowBounds as String] as? [String: Double] else {
    FileHandle.standardError.write(Data("no window of \(owners.sorted().joined(separator: ", "))\n".utf8))
    exit(1)
}
let display = CGMainDisplayID()
let scale = Double(CGDisplayPixelsWide(display)) / max(1, CGDisplayBounds(display).width)
let rect = [bounds["X"] ?? 0, bounds["Y"] ?? 0, bounds["Width"] ?? 0, bounds["Height"] ?? 0].map { Int(($0 * scale).rounded()) }
print(rect.map(String.init).joined(separator: " "))
