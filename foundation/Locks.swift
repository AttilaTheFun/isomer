// NSLock and NSRecursiveLock (Apple's Foundation and corelibs have them;
// swift-foundation does not), over a pthread mutex. A WebAssembly program
// without threads has nothing to exclude: there they only count.

import FoundationEssentials
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#if _runtime(_multithreaded)
import wasi_pthread
#endif
#endif

public protocol NSLocking {
    func lock()
    func unlock()
}

extension NSLocking {
    public func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock()
        defer { unlock() }
        return try body()
    }
}

#if os(WASI) && !_runtime(_multithreaded)
/// One thread: a lock is always free when asked for.
private final class _Mutex: @unchecked Sendable {
    private var depth = 0
    init(recursive: Bool) {}
    func lock() { depth += 1 }
    func unlock() { depth -= 1 }
    func tryLock() -> Bool {
        depth += 1
        return true
    }
}
#else
private final class _Mutex: @unchecked Sendable {
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)

    init(recursive: Bool) {
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
    func tryLock() -> Bool { pthread_mutex_trylock(mutex) == 0 }
}
#endif

open class NSLock: NSLocking, @unchecked Sendable {
    private let mutex = _Mutex(recursive: false)
    open var name: String?

    public init() {}

    open func lock() {
        mutex.lock()
    }

    open func unlock() {
        mutex.unlock()
    }

    open func `try`() -> Bool {
        mutex.tryLock()
    }

    /// Tries until `limit`, a few milliseconds apart.
    open func lock(before limit: Date) -> Bool {
        repeat {
            if mutex.tryLock() { return true }
            #if !os(WASI)
            usleep(1000)
            #endif
        } while Date() < limit
        return false
    }
}

open class NSRecursiveLock: NSLocking, @unchecked Sendable {
    private let mutex = _Mutex(recursive: true)
    open var name: String?

    public init() {}

    open func lock() {
        mutex.lock()
    }

    open func unlock() {
        mutex.unlock()
    }

    open func `try`() -> Bool {
        mutex.tryLock()
    }

    open func lock(before limit: Date) -> Bool {
        repeat {
            if mutex.tryLock() { return true }
            #if !os(WASI)
            usleep(1000)
            #endif
        } while Date() < limit
        return false
    }
}

/// A lock with a condition to wait on (pthread's mutex and condition
/// variable). Without threads, waiting returns at once: no other thread
/// could signal.
open class NSCondition: NSLocking, @unchecked Sendable {
    open var name: String?
    #if os(WASI) && !_runtime(_multithreaded)
    public init() {}
    open func lock() {}
    open func unlock() {}
    open func wait() {}
    open func wait(until limit: Date) -> Bool { false }
    open func signal() {}
    open func broadcast() {}
    #else
    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)

    public init() {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    open func lock() {
        pthread_mutex_lock(mutex)
    }

    open func unlock() {
        pthread_mutex_unlock(mutex)
    }

    open func wait() {
        pthread_cond_wait(condition, mutex)
    }

    /// False when `limit` passed first.
    open func wait(until limit: Date) -> Bool {
        let seconds = limit.timeIntervalSince1970
        var deadline = timespec()
        deadline.tv_sec = time_t(seconds)
        deadline.tv_nsec = Int((seconds - Double(Int(seconds))) * 1_000_000_000)
        return pthread_cond_timedwait(condition, mutex, &deadline) == 0
    }

    open func signal() {
        pthread_cond_signal(condition)
    }

    open func broadcast() {
        pthread_cond_broadcast(condition)
    }
    #endif
}
