// breakpoint and breakpointOnError: stop in the debugger when a closure
// says so. A SIGTRAP where the C library raises signals (a debugger
// stops there; without one the process ends, as on Apple platforms); a
// WebAssembly guest has no signals, so it traps.

#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

extension Publisher {
    public func breakpoint(receiveSubscription: ((any Subscription) -> Bool)? = nil,
                           receiveOutput: ((Self.Output) -> Bool)? = nil,
                           receiveCompletion: ((Subscribers.Completion<Self.Failure>) -> Bool)? = nil)
        -> Publishers.Breakpoint<Self> {
        Publishers.Breakpoint(upstream: self, receiveSubscription: receiveSubscription, receiveOutput: receiveOutput,
                              receiveCompletion: receiveCompletion)
    }

    public func breakpointOnError() -> Publishers.Breakpoint<Self> {
        Publishers.Breakpoint(upstream: self, receiveCompletion: { completion in
            if case .failure = completion { return true }
            return false
        })
    }
}

extension Publishers {
    public struct Breakpoint<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let receiveSubscription: ((any Subscription) -> Bool)?
        public let receiveOutput: ((Upstream.Output) -> Bool)?
        public let receiveCompletion: ((Subscribers.Completion<Publishers.Breakpoint<Upstream>.Failure>) -> Bool)?

        public init(upstream: Upstream, receiveSubscription: ((any Subscription) -> Bool)? = nil,
                    receiveOutput: ((Upstream.Output) -> Bool)? = nil,
                    receiveCompletion: ((Subscribers.Completion<Publishers.Breakpoint<Upstream>.Failure>) -> Bool)? = nil) {
            self.upstream = upstream
            self.receiveSubscription = receiveSubscription
            self.receiveOutput = receiveOutput
            self.receiveCompletion = receiveCompletion
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let (onSubscription, onOutput, onCompletion) = (receiveSubscription, receiveOutput, receiveCompletion)
            upstream.subscribe(EventsInner(downstream: subscriber, events: Events(
                subscription: { if onSubscription?($0) == true { stopInDebugger() } },
                output: { if onOutput?($0) == true { stopInDebugger() } },
                completion: { if onCompletion?($0) == true { stopInDebugger() } })))
        }
    }
}

func stopInDebugger() {
    #if os(WASI)
    fatalError("Combine breakpoint")
    #elseif canImport(Android) || canImport(Glibc) || canImport(Musl)
    raise(SIGTRAP)
    #else
    fatalError("Combine breakpoint")
    #endif
}
