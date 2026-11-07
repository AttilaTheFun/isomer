// The operators that run on a Scheduler: receive(on:), subscribe(on:),
// debounce, throttle, delay, timeout and measureInterval.

// MARK: - receive(on:), subscribe(on:)

extension Publisher {
    public func receive<S>(on scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.ReceiveOn<Self, S>
    where S: Scheduler {
        Publishers.ReceiveOn(upstream: self, scheduler: scheduler, options: options)
    }

    public func subscribe<S>(on scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.SubscribeOn<Self, S>
    where S: Scheduler {
        Publishers.SubscribeOn(upstream: self, scheduler: scheduler, options: options)
    }
}

extension Publishers {
    /// Delivers values and the completion on the scheduler (the
    /// subscription comes at once, on the subscribing thread).
    public struct ReceiveOn<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let scheduler: Context
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, scheduler: Context, options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.scheduler = scheduler
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(ReceiveOnInner(downstream: subscriber, scheduler: scheduler, options: options))
        }
    }

    /// Subscribes, requests and cancels on the scheduler.
    public struct SubscribeOn<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let scheduler: Context
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, scheduler: Context, options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.scheduler = scheduler
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let inner = SubscribeOnInner(downstream: subscriber, scheduler: scheduler, options: options)
            let upstream = self.upstream
            scheduler.schedule(options: options) { upstream.subscribe(inner) }
        }
    }
}

final class ReceiveOnInner<Downstream: Subscriber, Context: Scheduler>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description = "ReceiveOn"
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private let scheduler: Context
    private let options: Context.SchedulerOptions?

    init(downstream: Downstream, scheduler: Context, options: Context.SchedulerOptions?) {
        self.downstream = downstream
        self.scheduler = scheduler
        self.options = options
    }

    private var upstream: (any Subscription)? {
        lock.withLock {
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
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
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard upstream != nil else { return .none }
        scheduler.schedule(options: options) { [self] in
            guard let upstream else { return }
            let more = downstream.receive(input)
            if more > 0 { upstream.request(more) }
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        guard upstream != nil else { return }
        scheduler.schedule(options: options) { [self] in
            let live = lock.withLock { () -> Bool in
                guard case .subscribed = status else { return false }
                status = .terminal
                return true
            }
            if live { downstream.receive(completion: completion) }
        }
    }

    func request(_ demand: Subscribers.Demand) {
        upstream?.request(demand)
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
    }
}

final class SubscribeOnInner<Downstream: Subscriber, Context: Scheduler>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description = "SubscribeOn"
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private let scheduler: Context
    private let options: Context.SchedulerOptions?

    init(downstream: Downstream, scheduler: Context, options: Context.SchedulerOptions?) {
        self.downstream = downstream
        self.scheduler = scheduler
        self.options = options
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
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        downstream.receive(input)
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        lock.withLock { status = .terminal }
        downstream.receive(completion: completion)
    }

    func request(_ demand: Subscribers.Demand) {
        let upstream = lock.withLock { () -> (any Subscription)? in
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        guard let upstream else { return }
        scheduler.schedule(options: options) { upstream.request(demand) }
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        guard let upstream else { return }
        scheduler.schedule(options: options) { upstream.cancel() }
    }
}

/// A subscription that asks upstream for everything and decides itself
/// what reaches downstream, and when (debounce, throttle, timeout): the
/// part they share.
class TimedInner<Downstream: Subscriber>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description: String
    let lock = Lock()
    let downstreamLock = RecursiveLock.recursive()
    var status = SubscriptionStatus.awaiting
    var demand = Subscribers.Demand.none
    var done = false
    let downstream: Downstream

    init(_ name: String, downstream: Downstream) {
        description = name
        self.downstream = downstream
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
        subscribed()
        subscription.request(.unlimited)
    }

    /// After downstream has the subscription (timeout starts its clock).
    func subscribed() {}

    func receive(_ input: Input) -> Subscribers.Demand { .none }
    func receive(completion: Subscribers.Completion<Failure>) {}

    /// Sends a value if downstream wants one (else it's dropped).
    func emit(_ value: Input) {
        let send = lock.withLock { () -> Bool in
            guard !done, demand > 0 else { return false }
            demand.consumeOne()
            return true
        }
        guard send else { return }
        let more = downstreamLock.withLock { downstream.receive(value) }
        lock.withLock { demand += more }
    }

    func end(_ completion: Subscribers.Completion<Failure>, cancellingUpstream: Bool = false) {
        let upstream = lock.withLock { () -> (any Subscription)?? in
            guard !done else { return nil }
            done = true
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return .some(upstream) }
            return .some(nil)
        }
        guard let upstream else { return }
        if cancellingUpstream { upstream?.cancel() }
        downstreamLock.withLock { downstream.receive(completion: completion) }
    }

    func request(_ demand: Subscribers.Demand) {
        lock.withLock { self.demand += demand }
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            done = true
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
    }
}

// MARK: - debounce

extension Publisher {
    public func debounce<S>(for dueTime: S.SchedulerTimeType.Stride, scheduler: S, options: S.SchedulerOptions? = nil)
        -> Publishers.Debounce<Self, S> where S: Scheduler {
        Publishers.Debounce(upstream: self, dueTime: dueTime, scheduler: scheduler, options: options)
    }
}

extension Publishers {
    /// A value once upstream has been quiet for `dueTime` after it. A newer
    /// value starts the wait again; one pending when upstream completes is
    /// dropped (as Apple's is).
    public struct Debounce<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let dueTime: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, dueTime: Context.SchedulerTimeType.Stride, scheduler: Context,
                    options: Context.SchedulerOptions?) {
            self.upstream = upstream
            self.dueTime = dueTime
            self.scheduler = scheduler
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(DebounceInner(downstream: subscriber, dueTime: dueTime, scheduler: scheduler, options: options))
        }
    }
}

final class DebounceInner<Downstream: Subscriber, Context: Scheduler>: TimedInner<Downstream> {
    private let dueTime: Context.SchedulerTimeType.Stride
    private let scheduler: Context
    private let options: Context.SchedulerOptions?
    private var generation = 0

    init(downstream: Downstream, dueTime: Context.SchedulerTimeType.Stride, scheduler: Context,
         options: Context.SchedulerOptions?) {
        self.dueTime = dueTime
        self.scheduler = scheduler
        self.options = options
        super.init("Debounce", downstream: downstream)
    }

    override func receive(_ input: Input) -> Subscribers.Demand {
        let current = lock.withLock { () -> Int? in
            guard !done else { return nil }
            generation += 1
            return generation
        }
        guard let current else { return .none }
        scheduler.schedule(after: scheduler.now.advanced(by: dueTime), tolerance: scheduler.minimumTolerance,
                           options: options) { [self] in
            guard lock.withLock({ generation == current }) else { return }
            emit(input)
        }
        return .none
    }

    override func receive(completion: Subscribers.Completion<Failure>) {
        lock.withLock { generation += 1 }
        scheduler.schedule(options: options) { [self] in end(completion) }
    }
}

// MARK: - throttle

extension Publisher {
    public func throttle<S>(for interval: S.SchedulerTimeType.Stride, scheduler: S, latest: Bool)
        -> Publishers.Throttle<Self, S> where S: Scheduler {
        Publishers.Throttle(upstream: self, interval: interval, scheduler: scheduler, latest: latest)
    }
}

extension Publishers {
    /// At most one value an interval: the first at once, then at each
    /// interval's end the latest (or the first) that came during it.
    public struct Throttle<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let latest: Bool

        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context, latest: Bool) {
            self.upstream = upstream
            self.interval = interval
            self.scheduler = scheduler
            self.latest = latest
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(ThrottleInner(downstream: subscriber, interval: interval, scheduler: scheduler, latest: latest))
        }
    }
}

final class ThrottleInner<Downstream: Subscriber, Context: Scheduler>: TimedInner<Downstream> {
    private let interval: Context.SchedulerTimeType.Stride
    private let scheduler: Context
    private let latest: Bool
    private var held: Input?
    private var scheduled = false
    private var lastEmission: Context.SchedulerTimeType?
    private var pendingCompletion: Subscribers.Completion<Failure>?

    init(downstream: Downstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context, latest: Bool) {
        self.interval = interval
        self.scheduler = scheduler
        self.latest = latest
        super.init("Throttle", downstream: downstream)
    }

    override func receive(_ input: Input) -> Subscribers.Demand {
        let now = scheduler.now
        let due = lock.withLock { () -> Context.SchedulerTimeType? in
            guard !done, demand > 0 || scheduled else { return nil }
            if scheduled {
                if latest { held = input }
                return nil
            }
            held = input
            scheduled = true
            guard let last = lastEmission else { return now }
            let next = last.advanced(by: interval)
            return next < now ? now : next
        }
        guard let due else { return .none }
        scheduler.schedule(after: due, tolerance: scheduler.minimumTolerance, options: nil) { [self] in fire() }
        return .none
    }

    private func fire() {
        let (value, completion) = lock.withLock { () -> (Input?, Subscribers.Completion<Failure>?) in
            defer {
                held = nil
                scheduled = false
                lastEmission = scheduler.now
                pendingCompletion = nil
            }
            return (held, pendingCompletion)
        }
        if let value { emit(value) }
        if let completion { end(completion) }
    }

    override func receive(completion: Subscribers.Completion<Failure>) {
        // A held value goes first, at its time, the completion with it.
        let waits = lock.withLock { () -> Bool in
            guard scheduled else { return false }
            pendingCompletion = completion
            return true
        }
        if !waits { scheduler.schedule(options: nil) { [self] in end(completion) } }
    }
}

// MARK: - delay

extension Publisher {
    public func delay<S>(for interval: S.SchedulerTimeType.Stride, tolerance: S.SchedulerTimeType.Stride? = nil,
                         scheduler: S, options: S.SchedulerOptions? = nil) -> Publishers.Delay<Self, S> where S: Scheduler {
        Publishers.Delay(upstream: self, interval: interval, tolerance: tolerance ?? scheduler.minimumTolerance,
                         scheduler: scheduler, options: options)
    }
}

extension Publishers {
    /// Every value and the completion, `interval` later, on the scheduler.
    public struct Delay<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let tolerance: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?

        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, tolerance: Context.SchedulerTimeType.Stride,
                    scheduler: Context, options: Context.SchedulerOptions? = nil) {
            self.upstream = upstream
            self.interval = interval
            self.tolerance = tolerance
            self.scheduler = scheduler
            self.options = options
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(DelayInner(downstream: subscriber, interval: interval, tolerance: tolerance,
                                          scheduler: scheduler, options: options))
        }
    }
}

/// Passes demand through; each event is scheduled `interval` on.
final class DelayInner<Downstream: Subscriber, Context: Scheduler>: Subscriber, Subscription, CustomStringConvertible {
    typealias Input = Downstream.Input
    typealias Failure = Downstream.Failure

    let description = "Delay"
    private let lock = Lock()
    private var status = SubscriptionStatus.awaiting
    private let downstream: Downstream
    private let interval: Context.SchedulerTimeType.Stride
    private let tolerance: Context.SchedulerTimeType.Stride
    private let scheduler: Context
    private let options: Context.SchedulerOptions?

    init(downstream: Downstream, interval: Context.SchedulerTimeType.Stride, tolerance: Context.SchedulerTimeType.Stride,
         scheduler: Context, options: Context.SchedulerOptions?) {
        self.downstream = downstream
        self.interval = interval
        self.tolerance = tolerance
        self.scheduler = scheduler
        self.options = options
    }

    private var upstream: (any Subscription)? {
        lock.withLock {
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
    }

    private func later(_ action: @escaping () -> Void) {
        scheduler.schedule(after: scheduler.now.advanced(by: interval), tolerance: tolerance, options: options, action)
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
    }

    func receive(_ input: Input) -> Subscribers.Demand {
        guard upstream != nil else { return .none }
        later { [self] in
            guard let upstream else { return }
            let more = downstream.receive(input)
            if more > 0 { upstream.request(more) }
        }
        return .none
    }

    func receive(completion: Subscribers.Completion<Failure>) {
        guard upstream != nil else { return }
        later { [self] in
            let live = lock.withLock { () -> Bool in
                guard case .subscribed = status else { return false }
                status = .terminal
                return true
            }
            if live { downstream.receive(completion: completion) }
        }
    }

    func request(_ demand: Subscribers.Demand) {
        upstream?.request(demand)
    }

    func cancel() {
        let upstream = lock.withLock { () -> (any Subscription)? in
            defer { status = .terminal }
            if case .subscribed(let upstream) = status { return upstream }
            return nil
        }
        upstream?.cancel()
    }
}

// MARK: - timeout

extension Publisher {
    public func timeout<S>(_ interval: S.SchedulerTimeType.Stride, scheduler: S, options: S.SchedulerOptions? = nil,
                           customError: (() -> Self.Failure)? = nil) -> Publishers.Timeout<Self, S> where S: Scheduler {
        Publishers.Timeout(upstream: self, interval: interval, scheduler: scheduler, options: options,
                           customError: customError)
    }
}

extension Publishers {
    /// Finishes (or fails with `customError`) when upstream sends nothing
    /// for `interval`, counted from the subscription and each value.
    public struct Timeout<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let interval: Context.SchedulerTimeType.Stride
        public let scheduler: Context
        public let options: Context.SchedulerOptions?
        public let customError: (() -> Publishers.Timeout<Upstream, Context>.Failure)?

        public init(upstream: Upstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context,
                    options: Context.SchedulerOptions?,
                    customError: (() -> Publishers.Timeout<Upstream, Context>.Failure)?) {
            self.upstream = upstream
            self.interval = interval
            self.scheduler = scheduler
            self.options = options
            self.customError = customError
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribe(TimeoutInner(downstream: subscriber, interval: interval, scheduler: scheduler,
                                            options: options, customError: customError))
        }
    }
}

final class TimeoutInner<Downstream: Subscriber, Context: Scheduler>: TimedInner<Downstream> {
    private let interval: Context.SchedulerTimeType.Stride
    private let scheduler: Context
    private let options: Context.SchedulerOptions?
    private let customError: (() -> Failure)?
    private var generation = 0

    init(downstream: Downstream, interval: Context.SchedulerTimeType.Stride, scheduler: Context,
         options: Context.SchedulerOptions?, customError: (() -> Failure)?) {
        self.interval = interval
        self.scheduler = scheduler
        self.options = options
        self.customError = customError
        super.init("Timeout", downstream: downstream)
    }

    private func restartClock() {
        let current = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        scheduler.schedule(after: scheduler.now.advanced(by: interval), tolerance: scheduler.minimumTolerance,
                           options: options) { [self] in
            guard lock.withLock({ generation == current }) else { return }
            end(customError.map { .failure($0()) } ?? .finished, cancellingUpstream: true)
        }
    }

    override func subscribed() {
        restartClock()
    }

    override func receive(_ input: Input) -> Subscribers.Demand {
        guard !lock.withLock({ done }) else { return .none }
        restartClock()
        scheduler.schedule(options: options) { [self] in emit(input) }
        return .none
    }

    override func receive(completion: Subscribers.Completion<Failure>) {
        lock.withLock { generation += 1 }
        scheduler.schedule(options: options) { [self] in end(completion) }
    }
}

// MARK: - measureInterval

extension Publisher {
    public func measureInterval<S>(using scheduler: S, options: S.SchedulerOptions? = nil)
        -> Publishers.MeasureInterval<Self, S> where S: Scheduler {
        Publishers.MeasureInterval(upstream: self, scheduler: scheduler)
    }
}

extension Publishers {
    /// The time between values (the first: since the subscription), by the
    /// scheduler's clock.
    public struct MeasureInterval<Upstream, Context>: Publisher where Upstream: Publisher, Context: Scheduler {
        public typealias Output = Context.SchedulerTimeType.Stride
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let scheduler: Context

        public init(upstream: Upstream, scheduler: Context) {
            self.upstream = upstream
            self.scheduler = scheduler
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            S.Input == Context.SchedulerTimeType.Stride {
            let scheduler = self.scheduler
            var last = scheduler.now
            upstream.subscribeInner("MeasureInterval", subscriber) { _ in
                let now = scheduler.now
                defer { last = now }
                return .send(last.distance(to: now))
            }
        }
    }
}
