// A small implicit-animation system: `withAnimation`, `.animation(_:value:)`,
// and animatable `.opacity` / `.offset`. Animatable values are interpolated per
// view path between their previous and current targets, driving the existing
// continuous-render loop until they settle. Real SwiftUI is used on Apple.

import Foundation

public struct Animation: Equatable, Sendable {
    enum Curve: Equatable, Sendable {
        case linear, easeIn, easeOut, easeInOut
    }

    var duration: Double
    var curve: Curve
    /// `.repeatCount` / `.repeatForever`: 1 = once, n = n cycles, -1 = forever.
    var repeats: Int = 1
    /// Odd cycles run backwards when set (`autoreverses`).
    var autoreverses = false
    /// `.delay`: seconds before the first cycle starts.
    var delay: Double = 0

    public static let `default` = Animation(duration: 0.3, curve: .easeInOut)

    /// Loops the animation until the property is retargeted.
    public func repeatForever(autoreverses: Bool = true) -> Animation {
        var copy = self
        copy.repeats = -1
        copy.autoreverses = autoreverses
        return copy
    }

    public func repeatCount(_ count: Int, autoreverses: Bool = true) -> Animation {
        var copy = self
        copy.repeats = max(1, count)
        copy.autoreverses = autoreverses
        return copy
    }

    public func delay(_ seconds: Double) -> Animation {
        var copy = self
        copy.delay += max(0, seconds)
        return copy
    }

    public func speed(_ factor: Double) -> Animation {
        var copy = self
        copy.duration = duration / max(0.0001, factor)
        return copy
    }

    /// Whether the animation is still running `elapsed` seconds in, and the
    /// eased progress to show (cycle-aware for repeats; reversed on odd
    /// cycles when autoreversing).
    func progress(elapsed: Double) -> (running: Bool, value: Double) {
        let local = elapsed - delay
        if local < 0 { return (true, 0) }
        let cycleLength = max(0.0001, duration)
        let cycles = local / cycleLength
        if repeats > 0, cycles >= Double(repeats) {
            // Finished: end at the target, or back at the start when an even
            // number of reversing cycles ran.
            let endsReversed = autoreverses && repeats % 2 == 0
            return (false, endsReversed ? 0 : 1)
        }
        let whole = cycles.rounded(.down)
        var fraction = cycles - whole
        if autoreverses, Int(whole) % 2 == 1 { fraction = 1 - fraction }
        return (true, eased(fraction))
    }

    public static func linear(duration: Double = 0.3) -> Animation {
        Animation(duration: duration, curve: .linear)
    }
    public static func easeIn(duration: Double = 0.3) -> Animation {
        Animation(duration: duration, curve: .easeIn)
    }
    public static func easeOut(duration: Double = 0.3) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }
    public static func easeInOut(duration: Double = 0.3) -> Animation {
        Animation(duration: duration, curve: .easeInOut)
    }
    /// Approximated as a slightly longer ease-out (no spring solver here).
    public static func spring(response: Double = 0.5, dampingFraction: Double = 0.825, blendDuration: TimeInterval = 0) -> Animation {
        Animation(duration: response, curve: .easeOut)
    }

    /// The duration-and-bounce spring (iOS 17): an ease-out of that length.
    public static func spring(duration: Double = 0.5, bounce: Double = 0, blendDuration: Double = 0) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }
    /// iOS 17's named springs, as ease-outs of their settling time.
    public static var spring: Animation { Animation(duration: 0.5, curve: .easeOut) }
    public static var smooth: Animation { .smooth() }
    public static func smooth(duration: Double = 0.5, extraBounce: Double = 0) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }
    public static var snappy: Animation { .snappy() }
    public static func snappy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation {
        Animation(duration: duration * 0.8, curve: .easeOut)
    }
    public static var bouncy: Animation { .bouncy() }
    public static func bouncy(duration: Double = 0.5, extraBounce: Double = 0) -> Animation {
        Animation(duration: duration, curve: .easeOut)
    }

    /// Eased progress for `t` in 0...1 (polynomial curves; no `pow`).
    func eased(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        switch curve {
        case .linear: return x
        case .easeIn: return x * x
        case .easeOut: return x * (2 - x)
        case .easeInOut: return x < 0.5 ? 2 * x * x : 1 - 2 * (1 - x) * (1 - x)
        }
    }
}

/// Runs `body` (a state mutation) with an active transaction animation, so the
/// resulting changes to animatable properties interpolate instead of snapping.
public func withAnimation<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    Runtime.shared.transactionAnimation = animation
    let result = try body()
    Runtime.shared.requestFrame()
    // Cleared by `renderFrame` after the resulting build consumes it.
    return result
}

/// Per-path value interpolation. Each animatable property consults this with its
/// current target and the animation in scope; it returns the value to display.
final class Animator {
    private struct Entry {
        var from: Double
        var to: Double
        var start: Double
        var animation: Animation
    }

    private var entries: [String: Entry] = [:]
    private var displayed: [String: Double] = [:]

    var isAnimating: Bool { !entries.isEmpty }

    /// Whether a value of the view at `path` (keyed "<path>#<property>") is
    /// animating.
    func isAnimating(at path: String) -> Bool {
        guard !entries.isEmpty else { return false }
        let prefix = path + "#"
        return entries.keys.contains { $0.hasPrefix(prefix) }
    }

    /// The keys of the values animating now.
    var animatingKeys: [String] { Array(entries.keys) }

    func value(key: String, target: Double, animation: Animation?, now: Double) -> Double {
        // First time we've seen this property: snap, no animation.
        guard let current = displayed[key] else {
            displayed[key] = target
            return target
        }

        if var entry = entries[key] {
            // Retarget mid-flight if the destination changed.
            if entry.to != target {
                let v = displayed[key] ?? current
                if let animation {
                    entries[key] = Entry(from: v, to: target, start: now, animation: animation)
                } else {
                    entries[key] = nil
                    displayed[key] = target
                    return target
                }
                entry = entries[key]!
            }
            let (running, progress) = entry.animation.progress(elapsed: now - entry.start)
            let v = entry.from + (entry.to - entry.from) * progress
            if !running {
                entries[key] = nil
                displayed[key] = v
                return v
            }
            displayed[key] = v
            return v
        }

        // No interpolation in flight: start one if the target changed under an
        // active animation, else snap.
        if current != target {
            if let animation {
                entries[key] = Entry(from: current, to: target, start: now, animation: animation)
                return current
            }
            displayed[key] = target
        }
        return target
    }
}

// MARK: - Modifiers

extension View {
    /// Animates changes to animatable properties in this subtree. (The classic,
    /// always-on form.)
    nonisolated public func animation(_ animation: Animation?) -> some View {
        _EnvironmentModifier(child: self, descend: "anim") { env in
            env.animation = animation
            env.animationChosen = true
        }
    }

    /// Adjusts the transaction this subtree's changes are made under — most
    /// often `{ $0.animation = nil }`, so the subtree changes without
    /// animating while the rest of the page animates.
    nonisolated public func transaction(_ transform: @escaping (inout Transaction) -> Void) -> some View {
        _EnvironmentModifier(child: self, descend: "transaction") { env in
            var transaction = Transaction(animation: env.animation)
            transform(&transaction)
            env.animation = transaction.disablesAnimations ? nil : transaction.animation
            env.animationChosen = true
        }
    }

    /// Animates this subtree only when `value` changes (matches SwiftUI's
    /// value-scoped `.animation`).
    nonisolated public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        _AnimationValueModifier(child: self, animation: animation, value: value)
    }

    /// Places the view's CENTER at (x, y) in its parent's coordinate space;
    /// like SwiftUI, the positioned view then claims the whole proposed
    /// area. Animates when an animation is in scope.
    nonisolated public func position(x: CGFloat, y: CGFloat) -> some View {
        _AnimatableBoxModifier(child: self, descend: "position") { box, env, path, now in
            box.positionX = Runtime.shared.animator.value(
                key: path + "#posx", target: x, animation: env.animation, now: now)
            box.positionY = Runtime.shared.animator.value(
                key: path + "#posy", target: y, animation: env.animation, now: now)
            box.expandsWidth = true
            box.expandsHeight = true
        }
    }

    nonisolated public func position(_ point: CGPoint) -> some View {
        position(x: point.x, y: point.y)
    }

    /// Offsets the view (and animates the offset when an animation is in scope).
    nonisolated public func offset(x: CGFloat = 0, y: CGFloat = 0) -> some View {
        _AnimatableBoxModifier(child: self, descend: "offset") { box, env, path, now in
            box.offsetX = Runtime.shared.animator.value(
                key: path + "#offx", target: x, animation: env.animation, now: now)
            box.offsetY = Runtime.shared.animator.value(
                key: path + "#offy", target: y, animation: env.animation, now: now)
        }
    }
}

/// Whether two values of `.animation(_:value:)` are the same (Equatable,
/// as Apple's asks: not Hashable).
func _sameValue<V: Equatable>(_ value: V, _ other: any Equatable) -> Bool {
    (other as? V) == value
}

struct _AnimationValueModifier {
    let child: any View
    let animation: Animation?
    let value: any Equatable

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _AnimationValueModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let key = ctx.path + "#animvalue"
        let changed = !(Runtime.shared.animationValues[key].map { _sameValue(value, $0) } ?? false)
        Runtime.shared.animationValues[key] = value
        var sub = ctx.descend("animvalue")
        // Arm the animation only on the build where `value` changed; in-flight
        // interpolations continue on their own afterwards.
        sub.env.animation = changed ? animation : nil
        sub.env.animationChosen = true
        return buildNode(view: child, ctx: &sub)
    }
}

/// Env modifier whose transform can read the view's path + current time (for
/// animatable environment values like opacity).
struct _AnimatableEnvModifier {
    let child: any View
    let descend: String
    let apply: (inout EnvironmentValues, String, Double) -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _AnimatableEnvModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend(descend)
        apply(&sub.env, ctx.path, Runtime.shared.animationTime)
        return buildNode(view: child, ctx: &sub)
    }
}

/// Box modifier whose configuration can read the view's path + current time.
struct _AnimatableBoxModifier {
    let child: any View
    let descend: String
    let configure: (RenderNode, EnvironmentValues, String, Double) -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _AnimatableBoxModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend(descend)
        let inner = buildNode(view: child, ctx: &sub)
        let box = RenderNode.box(child: inner)
        configure(box, ctx.env, ctx.path, Runtime.shared.animationTime)
        return box
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _AnimationValueModifier: View {}
extension _AnimatableEnvModifier: View {}
extension _AnimatableBoxModifier: View {}
