// Lazy<T> — a bridgeable deferred value (want c in docs/bridge_v2.md).

/// A value whose initialization is deferred until first unwrap.
///
/// Returned from an exported function, a `Lazy` crosses the boundary as an
/// opaque handle; the consumer-side wrapper (`SwiftLazy<T>` in Kotlin,
/// `swiftffi::Lazy<T>` in C++, `Lazy<T>` in TypeScript) triggers the Swift
/// computation only when its value is first requested, caches the decoded
/// result, and releases the handle. `T` must be bridgeable.
///
///     @ExportedFunction
///     public func expensiveGreeting(for name: String) -> Lazy<String> {
///         Lazy { computeExpensively(name) }
///     }
///
/// Computes at most once. Not thread-safe: unwrap from one thread (or guard
/// externally) — the bridge itself calls it from the consumer's calling
/// thread.
public final class Lazy<T> {
    private enum State {
        case pending(() -> T)
        case computed(T)
    }

    private var state: State

    /// Defers `compute` until the value's first unwrap.
    public init(_ compute: @escaping () -> T) {
        self.state = .pending(compute)
    }

    /// Wraps an already-computed value (no deferral).
    public init(value: T) {
        self.state = .computed(value)
    }

    /// The value, computing (and caching) it on first access.
    public var value: T {
        switch state {
        case .computed(let value):
            return value
        case .pending(let compute):
            let value = compute()
            state = .computed(value)
            return value
        }
    }
}
