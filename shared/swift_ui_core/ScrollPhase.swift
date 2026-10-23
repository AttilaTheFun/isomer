// `onScrollPhaseChange`: what is moving a scroll view, as its host reports
// it: nothing (idle), the reader's finger or trackpad (tracking, then
// interacting), the coast after they let go (decelerating), or a scroll
// the app asked for (animating). The action runs on each change with the
// phase before and after, as SwiftUI's does. A host that cannot tell
// reports nothing, and the phase stays idle.

import Foundation

/// What is moving a scroll view.
public enum ScrollPhase: Equatable {
    /// Nothing is moving it.
    case idle
    /// The reader has touched it and may start scrolling.
    case tracking
    /// The reader is scrolling it.
    case interacting
    /// It coasts on after the reader let go.
    case decelerating
    /// The app is scrolling it (`ScrollViewProxy.scrollTo` with animation).
    case animating

    /// Whether anything is moving the scroll view: every phase but idle.
    public var isScrolling: Bool { self != .idle }

    public static func == (a: ScrollPhase, b: ScrollPhase) -> Bool { a.rank == b.rank }

    public func hash(into hasher: inout Hasher) { hasher.combine(rank) }

    private var rank: Int {
        switch self {
        case .idle: 0
        case .tracking: 1
        case .interacting: 2
        case .decelerating: 3
        case .animating: 4
        }
    }
}

extension ScrollPhase: Hashable {}
extension ScrollPhase: Sendable {}

extension ScrollPhase: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case .idle: "idle"
        case .tracking: "tracking"
        case .interacting: "interacting"
        case .decelerating: "decelerating"
        case .animating: "animating"
        }
    }
}

extension ScrollPhase {
    /// A host's name for a phase (`debugDescription`'s).
    init?(hostName: some StringProtocol) {
        switch hostName {
        case "idle": self = .idle
        case "tracking": self = .tracking
        case "interacting": self = .interacting
        case "decelerating": self = .decelerating
        case "animating": self = .animating
        default: return nil
        }
    }
}

/// The scroll view's geometry and velocity when its phase changed.
public struct ScrollPhaseChangeContext {
    let _geometry: ScrollGeometry
    let _velocity: CGVector?

    /// The scroll view's geometry at the change.
    public var geometry: ScrollGeometry { _geometry }
    /// How fast it was moving, in points a second, when the host knows.
    public var velocity: CGVector? { _velocity }
}

/// A host's phase report: "phase", or "phase;geometry" (the ten values a
/// geometry report has), or "phase;geometry;dx,dy" with the velocity in
/// points a second (an empty geometry: the last one reported).
struct ScrollPhaseReport {
    let phase: ScrollPhase
    let geometry: ScrollGeometry?
    let velocity: CGVector?

    init?(hostValue: String) {
        let parts = hostValue.split(separator: ";", omittingEmptySubsequences: false)
        guard let first = parts.first, let phase = ScrollPhase(hostName: first) else { return nil }
        self.phase = phase
        geometry = parts.count > 1 ? ScrollGeometry(hostValue: String(parts[1])) : nil
        let speeds = parts.count > 2 ? parts[2].split(separator: ",").compactMap { Double($0) } : []
        velocity = speeds.count == 2 ? CGVector(dx: speeds[0], dy: speeds[1]) : nil
    }
}

extension View {
    /// Runs `action` with the old and new phase whenever what is moving the
    /// scroll view changes.
    nonisolated public func onScrollPhaseChange(
        _ action: @escaping (_ oldPhase: ScrollPhase, _ newPhase: ScrollPhase) -> Void
    ) -> some View {
        onScrollPhaseChange { oldPhase, newPhase, _ in action(oldPhase, newPhase) }
    }

    /// Runs `action` with the old and new phase, and the scroll view's
    /// geometry and velocity, whenever what is moving it changes.
    nonisolated public func onScrollPhaseChange(
        _ action: @escaping (_ oldPhase: ScrollPhase, _ newPhase: ScrollPhase, _ context: ScrollPhaseChangeContext) -> Void
    ) -> some View {
        _ModifiedView(child: self, descend: "scrollphase", pure: true) { inner, ctx in
            let key = ctx.path + "/scrollphase"
            var current: RenderNode? = inner
            while let n = current {
                if case .scroll = n.kind {
                    // The scroll's geometry, kept for the context of a phase
                    // its host reports alone.
                    n.scrollGeometryHandlers.removeAll { $0.key == key }
                    n.scrollGeometryHandlers.append((key, { geometry in
                        Runtime.shared.scrollPhaseGeometries[key] = geometry
                    }))
                    n.scrollPhaseHandlers.removeAll { $0.key == key }
                    n.scrollPhaseHandlers.append((key, { phase, geometry, velocity in
                        let runtime = Runtime.shared
                        if let geometry { runtime.scrollPhaseGeometries[key] = geometry }
                        let old = runtime.scrollPhases[key] ?? .idle
                        guard old != phase else { return }
                        runtime.scrollPhases[key] = phase
                        let known = runtime.scrollPhaseGeometries[key]
                            ?? ScrollGeometry(contentOffset: .zero, contentSize: .zero, contentInsets: EdgeInsets(), containerSize: .zero)
                        action(old, phase, ScrollPhaseChangeContext(_geometry: known, _velocity: velocity))
                    }))
                    break
                }
                if case .box = n.kind, n.children.count == 1 { current = n.children.first } else { break }
            }
            return inner
        }
    }
}
