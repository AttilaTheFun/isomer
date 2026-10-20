// Gestures, as SwiftUI spells them: a drag, a pinch (MagnifyGesture, and the
// older MagnificationGesture), and the two together (`.simultaneously`),
// attached with `.gesture(_:)`. The host tracks the pointers and reports
// the running values; the guest's closures run from those reports. Real
// SwiftUI is used on Apple.

/// A gesture a view can carry: what it reports, in the pieces a host tracks.
import Foundation

@MainActor @preconcurrency
public protocol Gesture<Value> {
    /// What the gesture reports as it changes and when it ends.
    associatedtype Value
    /// The gestures it is made of, as Apple's has it: an app's gesture is its
    /// `body`; Isomer's own are primitive (`Body == Never`).
    associatedtype Body: Gesture
    var body: Body { get }
}

extension Never: Gesture {
    public typealias Value = Never
}

/// A gesture the hosts track: its handlers, with `onChanged` and `onEnded`
/// run as well, in the pieces a host reports.
@MainActor
protocol PrimitiveGesture: Gesture {
    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts
}

/// What a gesture contributes: a primitive one's parts, an app's gesture's
/// body's (the actions run with the body's values that are the gesture's).
@MainActor
func gestureParts<G: Gesture>(
    _ gesture: G, onChanged: ((G.Value) -> Void)?, onEnded: ((G.Value) -> Void)?
) -> GestureParts {
    if let primitive = gesture as? any PrimitiveGesture {
        return primitiveParts(primitive, onChanged: onChanged, onEnded: onEnded)
    }
    if G.Body.self == Never.self { return GestureParts() }
    return gestureParts(
        gesture.body,
        onChanged: onChanged.map { action in { if let value = $0 as? G.Value { action(value) } } },
        onEnded: onEnded.map { action in { if let value = $0 as? G.Value { action(value) } } })
}

/// A primitive gesture's parts, asked for with actions on its own value
/// (`V` is `P.Value`: the gesture was asked for as itself).
@MainActor
private func primitiveParts<P: PrimitiveGesture, V>(
    _ gesture: P, onChanged: ((V) -> Void)?, onEnded: ((V) -> Void)?
) -> GestureParts {
    gesture.parts(
        onChanged: onChanged.map { action in { action($0 as! V) } },
        onEnded: onEnded.map { action in { action($0 as! V) } })
}

extension Gesture where Value: Equatable {
    /// `action` runs as the gesture's value changes.
    nonisolated public func onChanged(_ action: @escaping (Value) -> Void) -> _ChangedGesture<Self> {
        _ChangedGesture(_body: self, action: action)
    }
}

extension Gesture {
    /// `action` runs once, with the gesture's final value, when it ends.
    nonisolated public func onEnded(_ action: @escaping (Value) -> Void) -> _EndedGesture<Self> {
        _EndedGesture(_body: self, action: action)
    }
}

/// A gesture with an `onChanged` action.
public struct _ChangedGesture<Content: Gesture> {
    public typealias Value = Content.Value
    public var _body: Content
    let action: (Value) -> Void

}

extension _ChangedGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }

    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        gestureParts(_body, onChanged: _bothActions(action, onChanged), onEnded: onEnded)
    }
}

/// A gesture with an `onEnded` action.
public struct _EndedGesture<Content: Gesture> {
    public typealias Value = Content.Value
    public var _body: Content
    let action: (Value) -> Void

}

extension _EndedGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }

    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        gestureParts(_body, onChanged: onChanged, onEnded: _bothActions(action, onEnded))
    }
}

/// Two actions as one (either may be absent).
func _bothActions<V>(_ a: ((V) -> Void)?, _ b: ((V) -> Void)?) -> ((V) -> Void)? {
    guard let a else { return b }
    guard let b else { return a }
    return { a($0); b($0) }
}

/// The handlers a gesture contributes: a drag, and a pinch's running and
/// final magnification.
struct GestureParts {
    var drag: DragGesture?
    var magnifyChanged: ((CGFloat) -> Void)?
    var magnifyEnded: ((CGFloat) -> Void)?

    /// Both gestures' handlers; each kind runs every handler given for it.
    func merged(with other: GestureParts) -> GestureParts {
        var out = self
        if let theirs = other.drag {
            if let ours = drag {
                var both = ours
                both.onChangedAction = { value in ours.onChangedAction?(value); theirs.onChangedAction?(value) }
                both.onEndedAction = { value in ours.onEndedAction?(value); theirs.onEndedAction?(value) }
                out.drag = both
            } else {
                out.drag = theirs
            }
        }
        out.magnifyChanged = Self.both(magnifyChanged, other.magnifyChanged)
        out.magnifyEnded = Self.both(magnifyEnded, other.magnifyEnded)
        return out
    }

    private static func both(_ a: ((CGFloat) -> Void)?, _ b: ((CGFloat) -> Void)?) -> ((CGFloat) -> Void)? {
        guard let a else { return b }
        guard let b else { return a }
        return { a($0); b($0) }
    }
}

public struct DragGesture {
    public struct Value: Equatable {
        public var startLocation: CGPoint
        public var location: CGPoint
        public var translation: CGSize
        public var predictedEndLocation: CGPoint
    }

    let minimumDistance: CGFloat
    var onChangedAction: ((Value) -> Void)?
    var onEndedAction: ((Value) -> Void)?
    /// A horizontal swipe (see the Isomer module's `View.swipeGesture`): the
    /// runtime defers engaging it until the drag is clearly horizontal, so
    /// vertical drags scroll instead.
    package var isHorizontalSwipe = false

    public init(minimumDistance: CGFloat = 10, coordinateSpace: CoordinateSpace = .local) {
        self.minimumDistance = minimumDistance
    }

    @MainActor
    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        var copy = self
        copy.onChangedAction = _bothActions(onChangedAction, onChanged)
        copy.onEndedAction = _bothActions(onEndedAction, onEnded)
        return GestureParts(drag: copy)
    }
}

/// A pinch: `magnification` is the scale since it began (1 at the start).
public struct MagnifyGesture {
    public struct Value: Equatable {
        public var magnification: CGFloat
        public var startAnchor: UnitPoint
        public var startLocation: CGPoint
    }

    var onChangedAction: ((Value) -> Void)?
    var onEndedAction: ((Value) -> Void)?

    public init(minimumScaleDelta: CGFloat = 0.01) {}

    @MainActor
    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        let changed = _bothActions(onChangedAction, onChanged)
        let ended = _bothActions(onEndedAction, onEnded)
        let value = { (m: CGFloat) in Value(magnification: m, startAnchor: .center, startLocation: .zero) }
        return GestureParts(
            magnifyChanged: changed.map { action in { action(value($0)) } },
            magnifyEnded: ended.map { action in { action(value($0)) } })
    }
}

/// The pinch as SwiftUI spelled it before `MagnifyGesture`: the value is the
/// magnification itself.
public struct MagnificationGesture {
    var onChangedAction: ((CGFloat) -> Void)?
    var onEndedAction: ((CGFloat) -> Void)?

    public init(minimumScaleDelta: CGFloat = 0.01) {}

    public typealias Value = CGFloat

    @MainActor
    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        GestureParts(magnifyChanged: _bothActions(onChangedAction, onChanged),
                      magnifyEnded: _bothActions(onEndedAction, onEnded))
    }
}

/// Two gestures at once: a pinch and a drag each report as the pointers move.
public struct SimultaneousGesture<First: Gesture, Second: Gesture> {
    public var first: First
    public var second: Second

    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    /// The two gestures' values, each while it is under way.
    public struct Value {
        public var first: First.Value?
        public var second: Second.Value?
    }

    @MainActor
    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        gestureParts(
            first,
            onChanged: onChanged.map { action in { action(Value(first: $0, second: nil)) } },
            onEnded: onEnded.map { action in { action(Value(first: $0, second: nil)) } }
        ).merged(with: gestureParts(
            second,
            onChanged: onChanged.map { action in { action(Value(first: nil, second: $0)) } },
            onEnded: onEnded.map { action in { action(Value(first: nil, second: $0)) } }))
    }
}

extension SimultaneousGesture.Value: Equatable where First.Value: Equatable, Second.Value: Equatable {}

extension Gesture {
    nonisolated public func simultaneously<Other: Gesture>(with other: Other) -> SimultaneousGesture<Self, Other> {
        SimultaneousGesture(self, other)
    }
}

extension View {
    nonisolated public func gesture<G: Gesture>(_ gesture: G, including mask: GestureMask = .all) -> some View {
        _GestureModifier(child: self, gesture: gesture)
    }
}

/// Which gestures `.gesture(_:including:)` enables (accepted for source
/// compatibility: the view's own and its subviews' gestures both run).
public struct GestureMask: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let none = GestureMask([])
    public static let gesture = GestureMask(rawValue: 1)
    public static let subviews = GestureMask(rawValue: 2)
    public static let all: GestureMask = [.gesture, .subviews]
}

struct _GestureModifier<Child: View, G: Gesture> {
    let child: Child
    let gesture: G

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _GestureModifier: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        var sub = ctx.descend("gesture")
        let inner = buildNode(view: child, ctx: &sub)
        let box = RenderNode.box(child: inner)
        let parts = gestureParts(gesture, onChanged: nil, onEnded: nil)
        box.dragGesture = parts.drag
        box.magnifyChanged = parts.magnifyChanged
        box.magnifyEnded = parts.magnifyEnded
        return box
    }
}

/// A gesture's node is its handlers alone: rows holding one can be reused.
extension _GestureModifier: _ReusableBuild {}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _GestureModifier: View {}
extension DragGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }
}
extension MagnifyGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }
}
extension MagnificationGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }
}
extension SimultaneousGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }
}
