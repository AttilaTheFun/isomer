// Taps and long presses as gestures (`TapGesture`, `LongPressGesture`,
// `onLongPressGesture`), and `@GestureState` with `updating(_:body:)`: state
// a gesture sets while it runs, back to its initial value when it ends.

/// A tap (or `count` taps): its value is nothing; `onEnded` runs on the tap.
public struct TapGesture {
    public var count: Int

    nonisolated public init(count: Int = 1) {
        self.count = count
    }

    public typealias Value = Void
}

extension TapGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }

    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        var parts = GestureParts()
        parts.tap = (count, { onEnded?(()) })
        return parts
    }
}

/// A press held for `minimumDuration` within `maximumDistance`: its value
/// is true while it is pressed (`onChanged`, `updating`), and `onEnded`
/// runs once it has been held long enough.
public struct LongPressGesture {
    public var minimumDuration: Double
    public var maximumDistance: CGFloat

    nonisolated public init(minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10) {
        self.minimumDuration = minimumDuration
        self.maximumDistance = maximumDistance
    }

    public typealias Value = Bool
}

extension LongPressGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }

    func parts(onChanged: ((Bool) -> Void)?, onEnded: ((Bool) -> Void)?) -> GestureParts {
        var parts = GestureParts()
        parts.longPress = LongPressSpec(
            minimumDuration: minimumDuration, maximumDistance: maximumDistance,
            pressing: { down in if down { onChanged?(true) } },
            perform: { onEnded?(true) })
        return parts
    }
}

extension View {
    /// `action` once the view has been pressed for `minimumDuration`;
    /// `onPressingChanged` as the press goes down and comes up.
    nonisolated public func onLongPressGesture(
        minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10,
        perform action: @escaping () -> Void, onPressingChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        _ModifiedView(child: self, descend: "longpress", pure: true) { inner, ctx in
            let box = RenderNode.box(child: inner)
            if ctx.env.isEnabled {
                box.longPress = LongPressSpec(
                    minimumDuration: minimumDuration, maximumDistance: maximumDistance,
                    pressing: onPressingChanged, perform: action)
            }
            return box
        }
    }

    nonisolated public func onLongPressGesture(
        minimumDuration: Double = 0.5,
        perform action: @escaping () -> Void, onPressingChanged: ((Bool) -> Void)? = nil
    ) -> some View {
        onLongPressGesture(minimumDuration: minimumDuration, maximumDistance: 10,
                           perform: action, onPressingChanged: onPressingChanged)
    }

    /// The older spelling, `pressing:` before `perform:`.
    @_disfavoredOverload
    nonisolated public func onLongPressGesture(
        minimumDuration: Double = 0.5, maximumDistance: CGFloat = 10,
        pressing: ((Bool) -> Void)? = nil, perform action: @escaping () -> Void
    ) -> some View {
        onLongPressGesture(minimumDuration: minimumDuration, maximumDistance: maximumDistance,
                           perform: action, onPressingChanged: pressing)
    }

    @_disfavoredOverload
    nonisolated public func onLongPressGesture(
        minimumDuration: Double = 0.5,
        pressing: ((Bool) -> Void)? = nil, perform action: @escaping () -> Void
    ) -> some View {
        onLongPressGesture(minimumDuration: minimumDuration, maximumDistance: 10,
                           perform: action, onPressingChanged: pressing)
    }
}

// MARK: - GestureState

/// `@GestureState`: a value a gesture sets as it runs (`updating(_:body:)`),
/// read like `@State`, and set back to its initial value when the gesture
/// ends, whether it completed or not.
@propertyWrapper
public struct GestureState<Value>: _DynamicProperty {
    let state: State<Value>
    let initial: Value
    let reset: (Value, inout Transaction) -> Void

    public init(wrappedValue: Value) {
        self.init(wrappedValue: wrappedValue, reset: { _, _ in })
    }

    public init(initialValue: Value) {
        self.init(wrappedValue: initialValue)
    }

    public init(wrappedValue: Value, resetTransaction: Transaction) {
        self.init(wrappedValue: wrappedValue, reset: { _, transaction in transaction = resetTransaction })
    }

    public init(initialValue: Value, resetTransaction: Transaction) {
        self.init(wrappedValue: initialValue, resetTransaction: resetTransaction)
    }

    public init(wrappedValue: Value, reset: @escaping (Value, inout Transaction) -> Void) {
        state = State(wrappedValue: wrappedValue)
        initial = wrappedValue
        self.reset = reset
    }

    public init(initialValue: Value, reset: @escaping (Value, inout Transaction) -> Void) {
        self.init(wrappedValue: initialValue, reset: reset)
    }

    public var wrappedValue: Value { state.wrappedValue }

    public var projectedValue: GestureState<Value> { self }

    func _connect(storage: StateStorage, key: String, env: EnvironmentValues) {
        state._connect(storage: storage, key: key, env: env)
    }

    /// The value as a gesture sets it.
    func _set(_ value: Value) {
        state.wrappedValue = value
    }

    /// Back to the initial value (the gesture ended).
    func _reset() {
        var transaction = Transaction()
        reset(state.wrappedValue, &transaction)
        state.wrappedValue = initial
    }
}

extension GestureState where Value: ExpressibleByNilLiteral {
    public init(resetTransaction: Transaction = Transaction()) {
        self.init(wrappedValue: nil, resetTransaction: resetTransaction)
    }

    public init(reset: @escaping (Value, inout Transaction) -> Void) {
        self.init(wrappedValue: nil, reset: reset)
    }
}

extension Gesture {
    /// Sets `state` from the gesture's value as it changes (`body` gets the
    /// value, the state to change and a transaction); the state goes back to
    /// its initial value when the gesture ends.
    nonisolated public func updating<State>(
        _ state: GestureState<State>,
        body: @escaping (Value, inout State, inout Transaction) -> Void
    ) -> GestureStateGesture<Self, State> {
        GestureStateGesture(base: self, state: state, body: body)
    }
}

/// A gesture that sets a `@GestureState` (`updating(_:body:)`).
public struct GestureStateGesture<Base, State> where Base: Gesture {
    public typealias Value = Base.Value
    public var base: Base
    public var state: GestureState<State>
    /// What `updating`'s closure does (Apple's names it `body`, which here is
    /// the gesture's own, `Never`, as every primitive gesture's).
    var update: (Value, inout State, inout Transaction) -> Void

    nonisolated public init(base: Base, state: GestureState<State>,
                            body: @escaping (Value, inout State, inout Transaction) -> Void) {
        self.base = base
        self.state = state
        self.update = body
    }
}

extension GestureStateGesture: Gesture, PrimitiveGesture {
    public typealias Body = Never
    public var body: Never { fatalError("primitive gesture") }

    func parts(onChanged: ((Value) -> Void)?, onEnded: ((Value) -> Void)?) -> GestureParts {
        let state = state, update = update
        let changed: (Value) -> Void = { value in
            var current = state.wrappedValue
            var transaction = Transaction()
            update(value, &current, &transaction)
            state._set(current)
            onChanged?(value)
        }
        var parts = gestureParts(base, onChanged: changed, onEnded: onEnded)
        parts.finished = { [parts] in
            parts.finished?()
            state._reset()
        }
        return parts
    }
}
