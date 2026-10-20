// Thread (Apple's Foundation and corelibs have it; swift-foundation does
// not), over pthreads: a block run on a thread of its own, the current
// thread with its name and dictionary, the main thread, sleeping. In
// WebAssembly without threads there is one thread, the main one, and
// starting another stops the program. No `threadDictionary`: Apple's is
// an NSMutableDictionary (Objective-C), which Isomer leaves out.

import FoundationEssentials
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(WASILibc)
import WASILibc
#if _runtime(_multithreaded)
import wasi_pthread
import CWasiThreadIdentity
#endif
#endif

public enum QualityOfService: Int, Sendable {
    case userInteractive = 0x21
    case userInitiated = 0x19
    case utility = 0x11
    case background = 0x09
    case `default` = -1
}

open class Thread: @unchecked Sendable {
    private var block: (() -> Void)?
    open var name: String?
    open var qualityOfService: QualityOfService = .default
    open var stackSize = 0
    public private(set) var isExecuting = false
    public private(set) var isFinished = false
    public private(set) var isCancelled = false
    private let isMain: Bool

    public init() {
        isMain = false
    }

    public convenience init(block: @escaping @Sendable () -> Void) {
        self.init()
        self.block = block
    }

    private init(main: Bool) {
        isMain = main
    }

    /// What a subclass's thread runs: the block it was made with.
    open func main() {
        block?()
    }

    open func cancel() {
        isCancelled = true
    }

    open var isMainThread: Bool { isMain }

    open func start() {
        #if os(WASI) && !_runtime(_multithreaded)
        fatalError("Thread.start(): this WebAssembly program has no threads")
        #else
        isExecuting = true
        let context = Unmanaged.passRetained(self).toOpaque()
        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        if stackSize > 0 { pthread_attr_setstacksize(&attributes, stackSize) }
        pthread_attr_setdetachstate(&attributes, Int32(PTHREAD_CREATE_DETACHED))
        #if os(WASI)
        var thread: pthread_t? = nil
        #else
        var thread = pthread_t()
        #endif
        let result = pthread_create(&thread, &attributes, { context in
            let thread = Unmanaged<Thread>.fromOpaque(_pointer(context)).takeRetainedValue()
            pthread_setspecific(_threadKey, Unmanaged.passUnretained(thread).toOpaque())
            #if !os(WASI)
            if let name = thread.name {
                _ = name.withCString { pthread_setname_np(pthread_self(), $0) }
            }
            #endif
            thread.main()
            thread.isExecuting = false
            thread.isFinished = true
            pthread_setspecific(_threadKey, nil)
            // A detached thread's result goes unread (Bionic's start routine
            // returns a non-optional pointer).
            return context
        }, context)
        pthread_attr_destroy(&attributes)
        if result != 0 {
            Unmanaged<Thread>.fromOpaque(context).release()
            isExecuting = false
        }
        #endif
    }

    // MARK: The current thread

    public static let main = Thread(main: true)

    public static var isMainThread: Bool {
        #if os(WASI) && !_runtime(_multithreaded)
        return true
        #else
        #if os(WASI)
        return iso_wasi_is_main_thread() != 0
        #else
        return gettid() == getpid()
        #endif
        #endif
    }

    public static var current: Thread {
        #if os(WASI) && !_runtime(_multithreaded)
        return main
        #else
        if let pointer = pthread_getspecific(_threadKey) {
            return Unmanaged<Thread>.fromOpaque(pointer).takeUnretainedValue()
        }
        if isMainThread { return main }
        // A thread Foundation did not start: a Thread of its own, kept for
        // the thread's life.
        let thread = Thread(main: false)
        pthread_setspecific(_threadKey, Unmanaged.passRetained(thread).toOpaque())
        return thread
        #endif
    }

    public class func isMultiThreaded() -> Bool {
        #if os(WASI) && !_runtime(_multithreaded)
        return false
        #else
        return true
        #endif
    }

    public class func detachNewThread(_ block: @escaping @Sendable () -> Void) {
        Thread(block: block).start()
    }

    public class func sleep(forTimeInterval interval: TimeInterval) {
        guard interval > 0 else { return }
        var request = timespec()
        request.tv_sec = time_t(interval)
        request.tv_nsec = Int((interval - Double(Int(interval))) * 1_000_000_000)
        var remaining = timespec()
        while nanosleep(&request, &remaining) != 0 && errno == EINTR {
            request = remaining
        }
    }

    public class func sleep(until date: Date) {
        sleep(forTimeInterval: date.timeIntervalSinceNow)
    }

    public class func exit() {
        #if os(WASI) && !_runtime(_multithreaded)
        Foundation_exit(0)
        #else
        #if os(WASI)
        fatalError("Thread.exit is unavailable in wasi-libc; return from the thread entry instead")
        #else
        pthread_exit(nil)
        #endif
        #endif
    }
}

#if !(os(WASI) && !_runtime(_multithreaded))
// A thread's start argument: optional in Glibc's pthread_create, not in
// Bionic's.
private func _pointer(_ pointer: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer { pointer! }
private func _pointer(_ pointer: UnsafeMutableRawPointer) -> UnsafeMutableRawPointer { pointer }

nonisolated(unsafe) private let _threadKey: pthread_key_t = {
    var key = pthread_key_t()
    pthread_key_create(&key, nil)
    return key
}()
#else
private func Foundation_exit(_ code: Int32) -> Never {
    exit(code)
}
#endif
