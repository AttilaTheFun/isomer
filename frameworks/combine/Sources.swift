// The publishers that start a stream: Just, Empty, Fail, Deferred, Future,
// Record, and the publishers of a sequence, an optional and a result.

/// One value, delivered when asked for, then finished.
final class SingleValueSubscription<Downstream: Subscriber>: Subscription, CustomStringConvertible {
    private let lock = Lock()
    private var downstream: Downstream?
    private let value: Downstream.Input
    let description: String

    init(_ name: String, value: Downstream.Input, downstream: Downstream) {
        description = name
        self.value = value
        self.downstream = downstream
    }

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        let downstream = lock.withLock { () -> Downstream? in
            defer { self.downstream = nil }
            return self.downstream
        }
        guard let downstream else { return }
        _ = downstream.receive(value)
        downstream.receive(completion: .finished)
    }

    func cancel() {
        lock.withLock { downstream = nil }
    }
}

/// A sequence's elements as asked for, then a completion. The next element
/// is read ahead, so the completion follows the last element at once.
final class SequenceSubscription<Elements: Sequence, Downstream: Subscriber>: Subscription, CustomStringConvertible
where Downstream.Input == Elements.Element {
    private let lock = Lock()
    private var downstream: Downstream?
    private var iterator: Elements.Iterator
    private var upcoming: Elements.Element?
    private var demand = Subscribers.Demand.none
    private var emitting = false
    private let completion: Subscribers.Completion<Downstream.Failure>
    let description: String

    /// Nil when the sequence is empty: the caller completes at once.
    init?(_ name: String, elements: Elements, completion: Subscribers.Completion<Downstream.Failure>,
          downstream: Downstream) {
        description = name
        iterator = elements.makeIterator()
        upcoming = iterator.next()
        guard upcoming != nil else { return nil }
        self.completion = completion
        self.downstream = downstream
    }

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        lock.lock()
        self.demand += demand
        // A request from inside a delivery adds to the loop below.
        guard !emitting else {
            lock.unlock()
            return
        }
        emitting = true
        while self.demand > 0, let downstream, let element = upcoming {
            self.demand.consumeOne()
            upcoming = iterator.next()
            let last = upcoming == nil
            if last { self.downstream = nil }
            lock.unlock()
            let more = downstream.receive(element)
            if last {
                downstream.receive(completion: completion)
                return
            }
            lock.lock()
            self.demand += more
        }
        emitting = false
        lock.unlock()
    }

    func cancel() {
        lock.withLock { downstream = nil }
    }
}

public struct Just<Output>: Publisher {
    public typealias Failure = Never

    public let output: Output

    public init(_ output: Output) {
        self.output = output
    }

    public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == Never {
        subscriber.receive(subscription: SingleValueSubscription("Just", value: output, downstream: subscriber))
    }
}

extension Just: Equatable where Output: Equatable {
    public static func == (lhs: Just<Output>, rhs: Just<Output>) -> Bool {
        lhs.output == rhs.output
    }
}

public struct Empty<Output, Failure>: Publisher, Equatable where Failure: Error {
    public init(completeImmediately: Bool = true) {
        self.completeImmediately = completeImmediately
    }

    public init(completeImmediately: Bool = true, outputType: Output.Type, failureType: Failure.Type) {
        self.completeImmediately = completeImmediately
    }

    public let completeImmediately: Bool

    public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        subscriber.receive(subscription: Subscriptions.empty)
        if completeImmediately { subscriber.receive(completion: .finished) }
    }

    public static func == (lhs: Empty<Output, Failure>, rhs: Empty<Output, Failure>) -> Bool {
        lhs.completeImmediately == rhs.completeImmediately
    }
}

public struct Fail<Output, Failure>: Publisher where Failure: Error {
    public init(error: Failure) {
        self.error = error
    }

    public init(outputType: Output.Type, failure: Failure) {
        error = failure
    }

    public let error: Failure

    public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        subscriber.receive(subscription: Subscriptions.empty)
        subscriber.receive(completion: .failure(error))
    }
}

extension Fail: Equatable where Failure: Equatable {
    public static func == (lhs: Fail<Output, Failure>, rhs: Fail<Output, Failure>) -> Bool {
        lhs.error == rhs.error
    }
}

/// Makes its publisher for each subscriber, when it subscribes.
public struct Deferred<DeferredPublisher>: Publisher where DeferredPublisher: Publisher {
    public typealias Output = DeferredPublisher.Output
    public typealias Failure = DeferredPublisher.Failure

    public let createPublisher: () -> DeferredPublisher

    public init(createPublisher: @escaping () -> DeferredPublisher) {
        self.createPublisher = createPublisher
    }

    public func receive<S>(subscriber: S) where S: Subscriber, DeferredPublisher.Failure == S.Failure,
        DeferredPublisher.Output == S.Input {
        createPublisher().subscribe(subscriber)
    }
}

/// One result, made once: the closure runs when the future is made, and
/// every subscriber gets what its promise was given.
final public class Future<Output, Failure>: Publisher where Failure: Error {
    public typealias Promise = (Result<Output, Failure>) -> Void

    private let lock = Lock()
    private var result: Result<Output, Failure>?
    private var waiting: [FutureConduit<Output, Failure>] = []

    public init(_ attemptToFulfill: @escaping (@escaping Future<Output, Failure>.Promise) -> Void) {
        attemptToFulfill { [weak self] result in self?.fulfill(result) }
    }

    private func fulfill(_ result: Result<Output, Failure>) {
        let conduits = lock.withLock { () -> [FutureConduit<Output, Failure>] in
            guard self.result == nil else { return [] }
            self.result = result
            defer { waiting = [] }
            return waiting
        }
        for conduit in conduits { conduit.fulfill(result) }
    }

    final public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        let conduit = FutureConduit<Output, Failure>(AnySubscriber(subscriber))
        let known = lock.withLock { () -> Result<Output, Failure>? in
            if result == nil { waiting.append(conduit) }
            return result
        }
        subscriber.receive(subscription: conduit)
        if let known { conduit.fulfill(known) }
    }

    func forget(_ conduit: FutureConduit<Output, Failure>) {
        lock.withLock { waiting.removeAll { $0 === conduit } }
    }
}

/// A subscriber of a future: the value goes once asked for, a failure at once.
final class FutureConduit<Output, Failure: Error>: Subscription, CustomStringConvertible {
    private let lock = Lock()
    private var downstream: AnySubscriber<Output, Failure>?
    private var result: Result<Output, Failure>?
    private var requested = false

    init(_ downstream: AnySubscriber<Output, Failure>) {
        self.downstream = downstream
    }

    var description: String { "Future" }

    func fulfill(_ result: Result<Output, Failure>) {
        lock.lock()
        self.result = result
        let ready: Bool
        if case .failure = result { ready = true } else { ready = requested }
        lock.unlock()
        if ready { deliver() }
    }

    func request(_ demand: Subscribers.Demand) {
        precondition(demand > 0, "A request must be for at least one value")
        let ready = lock.withLock { () -> Bool in
            requested = true
            return result != nil
        }
        if ready { deliver() }
    }

    private func deliver() {
        let (downstream, result) = lock.withLock { () -> (AnySubscriber<Output, Failure>?, Result<Output, Failure>?) in
            defer { self.downstream = nil }
            return (self.downstream, self.result)
        }
        guard let downstream, let result else { return }
        switch result {
        case .success(let value):
            _ = downstream.receive(value)
            downstream.receive(completion: .finished)
        case .failure(let error):
            downstream.receive(completion: .failure(error))
        }
    }

    func cancel() {
        lock.withLock { downstream = nil }
    }
}

extension Future where Failure == Never {
    /// The value, awaited.
    final public var value: Output {
        get async {
            await withCheckedContinuation { continuation in
                let box = TokenBox()
                box.token = sink { value in
                    withExtendedLifetime(box) { continuation.resume(returning: value) }
                }
            }
        }
    }
}

extension Future {
    /// The value, awaited; its failure thrown.
    final public var value: Output {
        get async throws {
            try await withCheckedThrowingContinuation { continuation in
                let box = TokenBox()
                box.token = sink(receiveCompletion: { completion in
                    _ = box
                    if case .failure(let error) = completion { continuation.resume(throwing: error) }
                }, receiveValue: { continuation.resume(returning: $0) })
            }
        }
    }
}

/// Keeps a sink's token alive until its subscription completes: the sink's
/// closures hold the box, and the sink lets go of them then.
final class TokenBox: @unchecked Sendable {
    var token: AnyCancellable?
}

/// Values and a completion recorded ahead, played back to each subscriber.
public struct Record<Output, Failure>: Publisher where Failure: Error {
    public let recording: Record<Output, Failure>.Recording

    public init(record: (inout Record<Output, Failure>.Recording) -> Void) {
        var recording = Recording()
        record(&recording)
        self.recording = recording
    }

    public init(recording: Record<Output, Failure>.Recording) {
        self.recording = recording
    }

    public init(output: [Output], completion: Subscribers.Completion<Failure>) {
        recording = Recording(output: output, completion: completion)
    }

    public func receive<S>(subscriber: S) where Output == S.Input, Failure == S.Failure, S: Subscriber {
        if let subscription = SequenceSubscription("Record", elements: recording.output, completion: recording.completion,
                                                   downstream: subscriber) {
            subscriber.receive(subscription: subscription)
        } else {
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: recording.completion)
        }
    }

    public struct Recording {
        public typealias Input = Output

        public private(set) var output: [Output]
        public private(set) var completion: Subscribers.Completion<Failure>
        private var finished = false

        public init() {
            output = []
            completion = .finished
        }

        public init(output: [Output], completion: Subscribers.Completion<Failure> = .finished) {
            self.output = output
            self.completion = completion
            finished = true
        }

        public mutating func receive(_ input: Record<Output, Failure>.Recording.Input) {
            precondition(!finished, "A recording can't take values after its completion")
            output.append(input)
        }

        public mutating func receive(completion: Subscribers.Completion<Failure>) {
            precondition(!finished, "A recording can't take two completions")
            self.completion = completion
            finished = true
        }
    }
}

// Coded as Apple's: a recording's `output` and `completion`; a record's `recording`.
private enum RecordingCodingKeys: String, CodingKey {
    case output
    case completion
}

private enum RecordCodingKeys: String, CodingKey {
    case recording
}

extension Record.Recording: Codable where Output: Decodable, Output: Encodable, Failure: Decodable, Failure: Encodable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RecordingCodingKeys.self)
        self.init(output: try container.decode([Output].self, forKey: .output),
                  completion: try container.decode(Subscribers.Completion<Failure>.self, forKey: .completion))
    }

    public func encode(into encoder: any Encoder) throws {
        try encode(to: encoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RecordingCodingKeys.self)
        try container.encode(output, forKey: .output)
        try container.encode(completion, forKey: .completion)
    }
}

extension Record: Codable where Output: Decodable, Output: Encodable, Failure: Decodable, Failure: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: RecordCodingKeys.self)
        try container.encode(recording, forKey: .recording)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: RecordCodingKeys.self)
        self.init(recording: try container.decode(Recording.self, forKey: .recording))
    }
}

extension Publishers {
    public struct Sequence<Elements, Failure>: Publisher where Elements: Swift.Sequence, Failure: Error {
        public typealias Output = Elements.Element

        public let sequence: Elements

        public init(sequence: Elements) {
            self.sequence = sequence
        }

        public func receive<S>(subscriber: S) where Failure == S.Failure, S: Subscriber, Elements.Element == S.Input {
            if let subscription = SequenceSubscription("Sequence", elements: sequence, completion: .finished,
                                                       downstream: subscriber) {
                subscriber.receive(subscription: subscription)
            } else {
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .finished)
            }
        }
    }
}

extension Publishers.Sequence: Equatable where Elements: Equatable {
    public static func == (lhs: Publishers.Sequence<Elements, Failure>, rhs: Publishers.Sequence<Elements, Failure>) -> Bool {
        lhs.sequence == rhs.sequence
    }
}

extension Sequence {
    public var publisher: Publishers.Sequence<Self, Never> {
        Publishers.Sequence(sequence: self)
    }
}

extension Optional {
    public var publisher: Optional<Wrapped>.Publisher {
        Publisher(self)
    }

    /// The value if there is one, then finished.
    public struct Publisher: Combine.Publisher {
        public typealias Output = Wrapped
        public typealias Failure = Never

        public let output: Optional<Wrapped>.Publisher.Output?

        public init(_ output: Optional<Wrapped>.Publisher.Output?) {
            self.output = output
        }

        public func receive<S>(subscriber: S) where Wrapped == S.Input, S: Subscriber, S.Failure == Never {
            if let output {
                subscriber.receive(subscription: SingleValueSubscription("Optional", value: output, downstream: subscriber))
            } else {
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .finished)
            }
        }
    }
}

extension Optional.Publisher: Equatable where Wrapped: Equatable {
    public static func == (lhs: Optional<Wrapped>.Publisher, rhs: Optional<Wrapped>.Publisher) -> Bool {
        lhs.output == rhs.output
    }
}

extension Result {
    public var publisher: Result<Success, Failure>.Publisher {
        Publisher(self)
    }

    /// The success, then finished; or the failure.
    public struct Publisher: Combine.Publisher {
        public typealias Output = Success

        public let result: Result<Result<Success, Failure>.Publisher.Output, Failure>

        public init(_ result: Result<Result<Success, Failure>.Publisher.Output, Failure>) {
            self.result = result
        }

        public init(_ output: Result<Success, Failure>.Publisher.Output) {
            result = .success(output)
        }

        public init(_ failure: Failure) {
            result = .failure(failure)
        }

        public func receive<S>(subscriber: S) where Success == S.Input, Failure == S.Failure, S: Subscriber {
            switch result {
            case .success(let value):
                subscriber.receive(subscription: SingleValueSubscription("Once", value: value, downstream: subscriber))
            case .failure(let error):
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .failure(error))
            }
        }
    }
}

extension Result.Publisher: Equatable where Success: Equatable, Failure: Equatable {
    public static func == (lhs: Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher,
                           rhs: Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher) -> Bool {
        lhs.result == rhs.result
    }
}
