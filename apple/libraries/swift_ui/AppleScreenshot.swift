// The Isomer module's `IsomerScreenshot` on Apple's platforms: the key
// window drawn into an image (UIGraphicsImageRenderer on iOS, the content
// view's cached display on a Mac), as a PNG. (Off Apple:
// shared/swift_ui_extensions/Screenshot.swift.)

import Foundation
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// A picture of the app's window as it is on screen, a PNG: what an app
/// attaches to a bug report.
public enum IsomerScreenshot {
    /// The window's PNG, or nil when there is no window to take.
    @MainActor
    public static func capture() async -> Data? {
        #if os(iOS)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
        return image.pngData()
        #elseif os(macOS)
        guard let view = (NSApp.keyWindow ?? NSApp.mainWindow)?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
        #else
        return nil
        #endif
    }
}
