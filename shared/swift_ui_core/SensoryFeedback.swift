// Haptics, as SwiftUI spells them: `.sensoryFeedback(_:trigger:)` plays a
// feedback each time a value changes. The host plays it (the platform
// command "haptic", with the feedback's name): Android's haptic constants,
// the browser's vibration where it has one, UIKit's feedback generators on
// an iPhone; a host without haptics ignores it.

/// A haptic the platform plays.
public struct SensoryFeedback: Equatable, Sendable {
    /// What hosts are told: "success", "impact:heavy:0.7", "impact:soft:1.0"…
    let name: String

    public static let success = SensoryFeedback(name: "success")
    public static let warning = SensoryFeedback(name: "warning")
    public static let error = SensoryFeedback(name: "error")
    public static let selection = SensoryFeedback(name: "selection")
    public static let increase = SensoryFeedback(name: "increase")
    public static let decrease = SensoryFeedback(name: "decrease")
    public static let start = SensoryFeedback(name: "start")
    public static let stop = SensoryFeedback(name: "stop")
    public static let alignment = SensoryFeedback(name: "alignment")
    public static let levelChange = SensoryFeedback(name: "levelChange")
    public static let pathComplete = SensoryFeedback(name: "pathComplete")
    public static let impact = SensoryFeedback.impact()

    /// An impact of a weight: light, medium or heavy.
    public static func impact(weight: Weight = .medium, intensity: Double = 1.0) -> SensoryFeedback {
        SensoryFeedback(name: "impact:\(weight.name):\(min(max(intensity, 0), 1))")
    }

    /// An impact of a flexibility: rigid, solid or soft.
    public static func impact(flexibility: Flexibility, intensity: Double = 1.0) -> SensoryFeedback {
        SensoryFeedback(name: "impact:\(flexibility.name):\(min(max(intensity, 0), 1))")
    }

    public struct Weight: Equatable, Sendable {
        let name: String
        public static let light = Weight(name: "light")
        public static let medium = Weight(name: "medium")
        public static let heavy = Weight(name: "heavy")
    }

    public struct Flexibility: Equatable, Sendable {
        let name: String
        public static let rigid = Flexibility(name: "rigid")
        public static let solid = Flexibility(name: "solid")
        public static let soft = Flexibility(name: "soft")
    }

    /// Plays it, once: not deduplicated as other platform commands are, a
    /// feedback repeats. Called from a change's action, on the main actor.
    func play() {
        let name = name
        MainActor.assumeIsolated { Runtime.shared.host?.platformCommand("haptic", name) }
    }
}

extension View {
    /// Plays `feedback` whenever `trigger` changes.
    nonisolated public func sensoryFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        onChange(of: trigger) { _, _ in feedback.play() }
    }

    /// Plays `feedback` whenever `trigger` changes and `condition` says so.
    nonisolated public func sensoryFeedback<T: Equatable>(
        _ feedback: SensoryFeedback, trigger: T, condition: @escaping (_ oldValue: T, _ newValue: T) -> Bool
    ) -> some View {
        onChange(of: trigger) { old, new in
            if condition(old, new) { feedback.play() }
        }
    }

    /// Plays the feedback `feedback` chooses for a change of `trigger`
    /// (none for nil).
    nonisolated public func sensoryFeedback<T: Equatable>(
        trigger: T, _ feedback: @escaping (_ oldValue: T, _ newValue: T) -> SensoryFeedback?
    ) -> some View {
        onChange(of: trigger) { old, new in feedback(old, new)?.play() }
    }

    /// Plays the feedback `feedback` chooses whenever `trigger` changes.
    nonisolated public func sensoryFeedback<T: Equatable>(
        trigger: T, _ feedback: @escaping () -> SensoryFeedback?
    ) -> some View {
        onChange(of: trigger) { _, _ in feedback()?.play() }
    }
}
