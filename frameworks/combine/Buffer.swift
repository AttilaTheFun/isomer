// buffer(size:prefetch:whenFull:) and collect(_:options:) by time: values
// held for downstream, by count or by the clock.

extension Publisher {
    public func buffer(size: Int, prefetch: Publishers.PrefetchStrategy,
                       whenFull: Publishers.BufferingStrategy<Self.Failure>) -> Publishers.Buffer<Self> {
        Publishers.Buffer(upstream: self, size: size, prefetch: prefetch, whenFull: whenFull)
    }

    public func collect<S>(_ strategy: Publishers.TimeGroupingStrategy<S>, options: S.SchedulerOptions? = nil)
        -> Publishers.CollectByTime<Self, S> where S: Scheduler {
        Publishers.CollectByTime(upstream: self, strategy: strategy, options: options)
    }
}

extension Publishers {
    /// When the buffer asks upstream for values: `keepFull` asks for its
    /// size at once and for one more as each leaves; `byRequest` asks for
    /// everything once downstream first asks.
    public enum PrefetchStrategy {
        case keepFull
        case byRequest

        public static func == (a: Publishers.PrefetchStrategy, b: Publishers.PrefetchStrategy) -> Bool {
            switch (a, b) {
            case (.keepFull, .keepFull), (.byRequest, .byRequest): return true
            default: return false
            }
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(self == .keepFull ? 0 : 1)
        }
    }

    /// What a full buffer does with one more value.
    public enum BufferingStrategy<Failure> where Failure: Error {
        case dropNewest
        case dropOldest
        case customError(() -> Failure)
    }

    public struct Buffer<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let size: Int
        public let prefetch: Publishers.PrefetchStrategy
        public let whenFull: Publishers.BufferingStrategy<Publishers.Buffer<Upstream>.Failure>

        public init(upstream: Upstream, size: Int, prefetch: Publishers.PrefetchStrategy,
                    whenFull: Publishers.BufferingStrategy<Publishers.Buffer<Upstream>.Failure>) {
            precondition(size > 0, "A buffer holds at least one value")
            self.upstream = upstream
            self.size = size
            self.prefetch = prefetch
            self.whenFull = whenFull
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(BufferInner(downstream: subscriber, size: size, prefetch: prefetch, whenFull: whenFull))
        }
    }

    /// Collect by time: every `interval` (and, by count, also whenever
    /// `count` have come), what came since, as an array.
    public enum TimeGroupingStrategy<Context> where Context: Scheduler {
        case byTime(Context, Context.SchedulerTimeType.Stride)
        case byTimeOrCount(Context, Context.SchedulerTimeType.Stride, Int)
    }

    public struct CollectByTime<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let strategy: Publishers.TimeGroupingStrategy<Context>
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, strategy: Publishers.TimeGroupingStrategy<Context>,
                    options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.strategy = strategy
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            S.Input == [Upstream.Output] {
            // The inner subscription takes arrays downstream; upstream's values reach it one by one.
            let inner = CollectByTimeInner(downstream: subscriber, strategy: strategy, options: options)
            upstream.subscribe(ClosureSubscriber<Upstream.Output, Upstream.Failure>(
                onSubscribe: { inner.receive(subscription: $0) },
                onValue: { value in
                    inner.append(value)
                    return .none
                },
                onCompletion: { inner.receive(completion: $0) }))
        }
    }
}

extension Publishers.PrefetchStrategy: Equatable {}
extension Publishers.PrefetchStrategy: Hashable {}

final class BufferInner<Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description = "Buffer"
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private let size: Int
    private let prefetch: Publishers.PrefetchStrategy
    private let whenFull: Publishers.BufferingStrategy<Failure>
    private var buffer: [Input] = []
    private var demand = Subscribers.Demand.none
    private var askedUpstream = false
    private var finished = false
    private var done = false
    private var draining = false

    init(downstream: Downstream, size: Int, prefetch: Publishers.PrefetchStrategy,
         whenFull: Publishers.BufferingStrategy<Failure>) {
        self.downstream = downstream
        self.size = size
        self.prefetch = prefetch
        self.whenFull = whenFull
    }

    func receive(subscription: any Subscription) {
        lock.lock()
        guard case .awaiting = status else {
            lock.unlock()
            subscription.cancel()
            return
        }
        status = .subscribed(subscription)
        lock.unlock()
        downstream.receive(subscription: self)
        if prefetch == .keepFull { subscription.request(.max(size)) }
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        lock.lock()
        guard !done, !finished else {
            lock.unlock()
            return .none
        }
        if buffer.count >= size {
            switch whenFull {
            case .dropNewest:
                lock.unlock()
                return .none
            case .dropOldest:
                buffer.removeFirst()
                buffer.append(input)
            case .customError(let makeError):
                lock.unlock()
                fail(makeError())
                return .none
            }
        } else {
            buffer.append(input)
        }
        lock.unlock()
        drain()
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        switch completion {
        case .finished:
            lock.withLock { finished = true }
            drain()
        case .failure(let error):
            fail(error)
        }
    }

    private func fail(_ error: Failure) {
        let upstream = lock.withLock { () -> (any Subscription)?? in
            guard !done else { return nil }
            done = true
            buffer = []
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return .some(upstream) }
            return .some(nil)
        }
        guard let upstream else { return }
        upstream?.cancel()
        downstream.receive(completion: .failure(error))
    }

    /// Sends what downstream wants; refills (keepFull); finishes once empty
    /// after upstream has.
    private func drain() {
        lock.lock()
        guard !draining else {
            lock.unlock()
            return
        }
        draining = true
        var sent = 0
        while !done, demand > 0, !buffer.isEmpty {
            let value = buffer.removeFirst()
            demand.consumeOne()
            sent += 1
            lock.unlock()
            let more = downstream.receive(value)
            lock.lock()
            demand += more
        }
        draining = false
        let finish = !done && finished && buffer.isEmpty
        if finish { done = true }
        var refill: (any Subscription)?
        if prefetch == .keepFull, sent > 0, !finish, case .subscribed(let upstream) = status { refill = upstream }
        if finish { status = .terminal }
        lock.unlock()
        if finish {
            downstream.receive(completion: .finished)
        } else if let refill {
            refill.request(.max(sent))
        }
    }

    func request(_ demand: Subscribers.Demand) {
        let upstream = lock.withLock { () -> (any Subscription)? in
            self.demand += demand
            guard prefetch == .byRequest, !askedUpstream, case .subscribed(let upstream) = status else { return nil }
            askedUpstream = true
            return upstream
        }
        upstream?.request(.unlimited)
        drain()
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            done = true
            buffer = []
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
    }
}

final class CollectByTimeInner<Downstream: Subscriber, Context: Scheduler>: TimedInner<Downstream>
where Downstream.Input: RangeReplaceableCollection {
    typealias Element = Downstream.Input.Element

    private let scheduler: Context
    private let interval: Context.SchedulerTimeType.Stride
    private let count: Int?
    private let options: Context.SchedulerOptions?
    private var batch = Downstream.Input()
    private var timer: (any Cancellable)?

    init(downstream: Downstream, strategy: Publishers.TimeGroupingStrategy<Context>, options: Context.SchedulerOptions?) {
        switch strategy {
        case .byTime(let scheduler, let interval):
            self.scheduler = scheduler
            self.interval = interval
            count = nil
        case .byTimeOrCount(let scheduler, let interval, let count):
            self.scheduler = scheduler
            self.interval = interval
            self.count = count
        }
        self.options = options
        super.init("CollectByTime", downstream: downstream)
    }

    override func subscribed() {
        let made = scheduler.schedule(after: scheduler.now.advanced(by: interval), interval: interval,
                                      tolerance: scheduler.minimumTolerance, options: options) { [weak self] in
            self?.flush()
        }
        let keep = lock.withLock { () -> Bool in
            guard !done else { return false }
            timer = made
            return true
        }
        if !keep { made.cancel() }
    }

    /// The batch so far, if any and downstream wants it.
    private func flush() {
        let ready = lock.withLock { () -> Downstream.Input? in
            guard !done, !batch.isEmpty, demand > 0 else { return nil }
            defer { batch = Downstream.Input() }
            return batch
        }
        if let ready { emit(ready) }
    }

    func append(_ element: Element) {
        let full = lock.withLock { () -> Bool in
            guard !done else { return false }
            batch.append(element)
            return count.map { batch.count >= $0 } ?? false
        }
        if full { flush() }
    }

    override func receive(completion: Subscribers.Completion<Failure>) {
        let (last, timer) = lock.withLock { () -> (Downstream.Input?, (any Cancellable)?) in
            defer {
                batch = Downstream.Input()
                self.timer = nil
            }
            if case .finished = completion, !batch.isEmpty { return (batch, self.timer) }
            return (nil, self.timer)
        }
        timer?.cancel()
        if let last { emit(last) }
        end(completion)
    }

    override func cancel() {
        let timer = lock.withLock { () -> (any Cancellable)? in
            defer { self.timer = nil }
            return self.timer
        }
        timer?.cancel()
        super.cancel()
    }
}
