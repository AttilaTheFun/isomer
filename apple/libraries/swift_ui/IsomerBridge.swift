// Native bridging API for Apple platforms — the same surface as the wasm and
// Android implementations, backed here by Foundation/AppKit/UIKit directly.

import Foundation
import SwiftUI
import WebKit
import AVKit

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public extension View {
    /// A horizontal swipe gesture (row swipe-to-action), mirroring the wasm /
    /// Android reimplementation's `swipeGesture`. Reports the running and final
    /// horizontal translation; vertical drags still scroll the enclosing list.
    func swipeGesture(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping (CGFloat) -> Void
    ) -> some View {
        gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { onChanged($0.translation.width) }
                .onEnded { onEnded($0.translation.width) }
        )
    }
}

public extension Color {
    /// A scheme-adaptive color from two concrete colors, mirroring the
    /// reimplementation platforms' `Color.dynamic(light:dark:)` so shared app
    /// code can define its own semantic palette (brand colors that adapt
    /// like `.primary`). Backed by a native dynamic provider, so it follows
    /// the trait environment exactly as system colors do.
    static func dynamic(light: Color, dark: Color) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(dark)
                : NSColor(light)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #endif
    }
}

public enum Bridge {
    public static var platformName: String {
        #if os(macOS)
        return "macOS (native SwiftUI)"
        #elseif os(iOS)
        return "iOS (native SwiftUI)"
        #else
        return "Apple (native SwiftUI)"
        #endif
    }

    public static var rendererName: String {
        #if os(macOS)
        return "AppKit + Core Animation"
        #else
        return "UIKit + Core Animation"
        #endif
    }

    public static func log(_ message: String) {
        print("[bridge] \(message)")
    }

    public static func epochMilliseconds() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    public static func openURL(_ url: String) {
        guard let parsed = URL(string: url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(parsed)
        #elseif os(iOS)
        UIApplication.shared.open(parsed)
        #endif
    }
}


// MARK: - Calendar helpers (mirror shared/swift_ui_core/CalendarSupport.swift)
//
// Backed by a UTC `Foundation.Calendar` so day/time labels match the
// reimplementation's UTC epoch math exactly across platforms. Sample apps use
// these instead of touching `Calendar`/`DateFormatter` directly, keeping their
// source identical everywhere.

public struct DateParts: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let hour: Int
    public let minute: Int
    public let weekday: Int // 0 = Sunday ... 6 = Saturday
}

private var utcCalendar: Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
}

public func dateParts(_ date: Date) -> DateParts {
    let c = utcCalendar.dateComponents(
        [.year, .month, .day, .hour, .minute, .weekday], from: date)
    return DateParts(
        year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1,
        hour: c.hour ?? 0, minute: c.minute ?? 0,
        weekday: (c.weekday ?? 1) - 1) // Foundation weekday is 1-based (Sun = 1)
}

public func makeDate(
    year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0
) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return utcCalendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
}

public func startOfDay(_ date: Date) -> Date {
    let p = dateParts(date)
    return makeDate(year: p.year, month: p.month, day: p.day)
}

private let _monthNames = [
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
]
private let _weekdayNames = [
    "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday",
]

public func dayHeadline(_ date: Date) -> String {
    let p = dateParts(date)
    return "\(_weekdayNames[p.weekday]), \(_monthNames[p.month - 1]) \(p.day)"
}

public func shortDate(_ date: Date) -> String {
    let p = dateParts(date)
    return "\(_monthNames[p.month - 1].prefix(3)) \(p.day), \(p.year)"
}

public func timeOfDay(_ date: Date) -> String {
    let p = dateParts(date)
    let isPM = p.hour >= 12
    var h = p.hour % 12
    if h == 0 { h = 12 }
    let mm = p.minute < 10 ? "0\(p.minute)" : "\(p.minute)"
    return "\(h):\(mm) \(isPM ? "PM" : "AM")"
}

/// Mirrors the reimplementation's `VideoPlayer` (shared/swift_ui_core/
/// VideoPlayer.swift), backed by AVKit: `AVKit.VideoPlayer` + `AVPlayer` on
/// iOS, AppKit's `AVPlayerView` on the Mac. Constructed from a URL here; the
/// reimplementation passes the URL to a `<video>` / Android `VideoView`.
public struct VideoPlayer: View {
    let url: URL?
    public init(url: URL?) { self.url = url }

    public var body: some View {
        if let url {
            #if os(macOS)
            // Not AVKit's SwiftUI VideoPlayer: on macOS 27 its overlay
            // (_AVKit_SwiftUI) aborts while initializing its class metadata
            // ("superclass not found") the moment one is shown.
            MacPlayerView(url: url)
            #else
            AVKit.VideoPlayer(player: AVPlayer(url: url))
            #endif
        } else {
            Color.black
        }
    }
}

#if os(macOS)
/// AppKit's player view, with its inline controls.
private struct MacPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if (view.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            view.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
    }
}
#endif

