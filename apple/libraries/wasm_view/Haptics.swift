// `.sensoryFeedback` in a guest: the platform command "haptic", with the
// feedback's name ("success", "impact:heavy:1.0"…), played as SwiftUI plays
// it: UIKit's feedback generators on an iPhone, the trackpad's haptics on a
// Mac.

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
enum GuestHaptics {
    static func play(_ name: String) {
        let parts = name.split(separator: ":").map(String.init)
        let kind = parts.first ?? ""
        #if os(iOS)
        switch kind {
        case "success": UINotificationFeedbackGenerator().notificationOccurred(.success)
        case "warning": UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case "error": UINotificationFeedbackGenerator().notificationOccurred(.error)
        case "selection", "increase", "decrease", "alignment": UISelectionFeedbackGenerator().selectionChanged()
        case "impact":
            let style: UIImpactFeedbackGenerator.FeedbackStyle = switch parts.count > 1 ? parts[1] : "" {
            case "light": .light
            case "heavy": .heavy
            case "soft": .soft
            case "rigid": .rigid
            default: .medium
            }
            let intensity = parts.count > 2 ? Double(parts[2]) ?? 1 : 1
            UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: CGFloat(intensity))
        default: UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        #elseif os(macOS)
        let pattern: NSHapticFeedbackManager.FeedbackPattern = switch kind {
        case "alignment": .alignment
        case "levelChange", "increase", "decrease", "selection": .levelChange
        default: .generic
        }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        #endif
    }
}
