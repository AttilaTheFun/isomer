// The locks Combine's publishers and subscriptions keep their state under.
// Combine sits beneath Foundation (Foundation imports it), so NSLock isn't
// there to use: these are pthread mutexes, as Foundation's NSLock is
// (foundation/Locks.swift). A WebAssembly program without threads has
// nothing to exclude, and there they only count.
//
// The rule every type here keeps: state is read and written under its
// lock, and nothing outside (a subscriber, a subscription, a closure of the
// app's) is called with the lock held, so a subscriber that sends, requests
// or cancels from inside a callback finds the lock free. Where a type must
// call downstream in order from several sources (Merge, CombineLatest,
// Zip, FlatMap), it holds a RecursiveLock around the calls, so a
// subscriber's re-entrant request runs, and two sources' values can't
// interleave.

#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(WASILibc)
import WASILibc
#if _runtime(_multithreaded)
import wasi_pthread
#endif
#elseif canImport(ucrt)
import ucrt
import WinSDK
#endif

#if os(WASI) && !_runtime(_multithreaded)
/// One thread: a lock is always free when asked for.
final class Lock: @unchecked Sendable {
    init(recursive: Bool = false) {}
    @inline(__always) func lock() {}
    @inline(__always) func unlock() {}
}
#elseif os(Windows)
final class Lock: @unchecked Sendable {
    private let section = UnsafeMutablePointer<CRITICAL_SECTION>.allocate(capacity: 1)

    /// A critical section is always recursive.
    init(recursive: Bool = false) {
        InitializeCriticalSection(section)
    }

    deinit {
        DeleteCriticalSection(section)
        section.deallocate()
    }

    func lock() { EnterCriticalSection(section) }
    func unlock() { LeaveCriticalSection(section) }
}
#else
final class Lock: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init(recursive: Bool = false) {
        var attributes = pthread_mutexattr_t()
        pthread_mutexattr_init(&attributes)
        if recursive {
            pthread_mutexattr_settype(&attributes, Int32(PTHREAD_MUTEX_RECURSIVE))
        }
        pthread_mutex_init(mutex, &attributes)
        pthread_mutexattr_destroy(&attributes)
    }

    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deallocate()
    }

    func lock() { pthread_mutex_lock(mutex) }
    func unlock() { pthread_mutex_unlock(mutex) }
}
#endif

extension Lock {
    @inline(__always)
    func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

/// The lock a type holds while it calls downstream (see above).
typealias RecursiveLock = Lock

extension RecursiveLock {
    static func recursive() -> Lock { Lock(recursive: true) }
}
