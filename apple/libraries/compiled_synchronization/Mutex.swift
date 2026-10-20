// Synchronization's `Mutex` for a feature compiled against Isomer's
// frameworks (apple/compiled), on Apple OSes older than Apple's needs (iOS
// 18, macOS 15): the value and an os_unfair_lock in a box of their own. The
// toolchain's lays them out inline (`@_rawLayout`, the standard library's
// own features); a box costs an allocation per mutex, made once, and
// nothing per lock. What the feature's libraries use of Synchronization is
// `Mutex` alone; `Atomic` is not here yet.

#if canImport(Darwin)
import Darwin
#endif

public struct Mutex<Value: ~Copyable>: ~Copyable {
    @usableFromInline
    let box: _MutexBox<Value>

    /// A mutex guarding `initialValue`.
    public init(_ initialValue: consuming sending Value) {
        box = _MutexBox(initialValue)
    }
}

extension Mutex where Value: ~Copyable {
    /// Runs `body` with the value while holding the lock.
    public borrowing func withLock<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result {
        box.acquire()
        defer { box.release() }
        return try body(&box.value)
    }

    /// Runs `body` with the value if the lock is free, else nil.
    public borrowing func withLockIfAvailable<Result: ~Copyable, E: Error>(
        _ body: (inout sending Value) throws(E) -> sending Result
    ) throws(E) -> sending Result? {
        guard box.tryAcquire() else { return nil }
        defer { box.release() }
        return try body(&box.value)
    }
}

extension Mutex: @unchecked Sendable where Value: ~Copyable {}

@usableFromInline
final class _MutexBox<Value: ~Copyable> {
    @usableFromInline
    var value: Value
    private let handle: UnsafeMutablePointer<os_unfair_lock>

    init(_ value: consuming Value) {
        self.value = value
        handle = .allocate(capacity: 1)
        handle.initialize(to: os_unfair_lock())
    }

    deinit {
        handle.deinitialize(count: 1)
        handle.deallocate()
    }

    @usableFromInline
    func acquire() { os_unfair_lock_lock(handle) }

    @usableFromInline
    func tryAcquire() -> Bool { os_unfair_lock_trylock(handle) }

    @usableFromInline
    func release() { os_unfair_lock_unlock(handle) }
}
