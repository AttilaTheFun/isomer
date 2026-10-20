// A minimal mutual-exclusion primitive for the runtime's few shared tables
// (Foundation-free: the SwiftFFI module only imports SwiftABI). Single-threaded
// wasm needs no locking; threaded wasm and native platforms use the C
// library's mutex.

#if os(WASI) && _runtime(_multithreaded)
import WASILibc
import wasi_pthread

final class SwiftFFILock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
}
#elseif os(WASI)
final class SwiftFFILock: @unchecked Sendable {
    init() {}
    func lock() {}
    func unlock() {}
}
#elseif os(Windows)
import WinSDK

final class SwiftFFILock: @unchecked Sendable {
    private var srw = SRWLOCK()
    init() { InitializeSRWLock(&srw) }
    func lock() { AcquireSRWLockExclusive(&srw) }
    func unlock() { ReleaseSRWLockExclusive(&srw) }
}
#else
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

final class SwiftFFILock: @unchecked Sendable {
    private var mutex = pthread_mutex_t()
    init() { pthread_mutex_init(&mutex, nil) }
    deinit { pthread_mutex_destroy(&mutex) }
    func lock() { pthread_mutex_lock(&mutex) }
    func unlock() { pthread_mutex_unlock(&mutex) }
}
#endif
