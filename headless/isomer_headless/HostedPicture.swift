// The picture a test hosted in its app takes (HeadlessApp.picture, hosted):
// the app's own key window drawn to a PNG in its process, as the launchers'
// pictures are of the screen outside it. UIKit's window with its status bar
// left out (the proof holds nothing but the app); AppKit's window, its title
// bar included, as the Mac's window crop is.

import Foundation
#if canImport(UIKit) && !os(watchOS)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's key window as a PNG, or nil where there is no window to draw
/// (a headless or a Linux build).
@MainActor
func hostedWindowPNG() -> Data? {
    #if canImport(UIKit) && !os(watchOS)
    let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).filter { !$0.isHidden }
    guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return nil }
    let format = UIGraphicsImageRendererFormat(for: window.traitCollection)
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
    return renderer.pngData { _ in
        _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
    }
    #elseif canImport(AppKit)
    guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible),
          let view = window.contentView?.superview ?? window.contentView,
          let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return nil }
    view.cacheDisplay(in: view.bounds, to: representation)
    return representation.representation(using: .png, properties: [:])
    #else
    return nil
    #endif
}
