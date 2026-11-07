// The operators that take one value at a time and send at most one for it:
// map, filter, compactMap, removeDuplicates, first, dropFirst, drop(while:),
// prefix, output(at:), scan, mapError, setFailureType, replaceError,
// replaceEmpty, replaceNil, assertNoFailure, collect(_:). Each subscription
// is an OperatorInner (Inner.swift); what one subscription remembers (a
// count, the previous value, the running total) is a local its closure
// captures, made afresh for each subscriber.

extension Publisher {
    func subscribeInner<S: Subscriber>(_ name: String, _ subscriber: S,
                                       _ onValue: @escaping (Output) -> Step<S.Input, S.Failure>) where S.Failure == Failure {
        subscribe(OperatorInner<Output, Failure, S>(name, downstream: subscriber, onValue: onValue))
    }

    func subscribeTrying<S: Subscriber>(_ name: String, _ subscriber: S,
                                        _ onValue: @escaping (Output) throws -> Step<S.Input, any Error>)
    where S.Failure == any Error {
        subscribe(OperatorInner<Output, Failure, S>(trying: name, downstream: subscriber, onValue: onValue))
    }
}

// MARK: - map

extension Publisher {
    public func map<T>(_ transform: @escaping (Self.Output) -> T) -> Publishers.Map<Self, T> {
        Publishers.Map(upstream: self, transform: transform)
    }

    public func tryMap<T>(_ transform: @escaping (Self.Output) throws -> T) -> Publishers.TryMap<Self, T> {
        Publishers.TryMap(upstream: self, transform: transform)
    }

    public func replaceNil<T>(with output: T) -> Publishers.Map<Self, T> where Self.Output == T? {
        Publishers.Map(upstream: self) { $0 ?? output }
    }

    public func map<T>(_ keyPath: KeyPath<Self.Output, T>) -> Publishers.MapKeyPath<Self, T> {
        Publishers.MapKeyPath(upstream: self, keyPath: keyPath)
    }

    public func map<T0, T1>(_ keyPath0: KeyPath<Self.Output, T0>, _ keyPath1: KeyPath<Self.Output, T1>)
        -> Publishers.MapKeyPath2<Self, T0, T1> {
        Publishers.MapKeyPath2(upstream: self, keyPath0: keyPath0, keyPath1: keyPath1)
    }

    public func map<T0, T1, T2>(_ keyPath0: KeyPath<Self.Output, T0>, _ keyPath1: KeyPath<Self.Output, T1>,
                                _ keyPath2: KeyPath<Self.Output, T2>) -> Publishers.MapKeyPath3<Self, T0, T1, T2> {
        Publishers.MapKeyPath3(upstream: self, keyPath0: keyPath0, keyPath1: keyPath1, keyPath2: keyPath2)
    }
}

extension Publishers {
    public struct Map<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output

        public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output) {
            self.upstream = upstream
            self.transform = transform
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, Upstream.Failure == S.Failure {
            let transform = self.transform
            upstream.subscribeInner("Map", subscriber) { .send(transform($0)) }
        }
    }

    public struct TryMap<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Error

        public let upstream: Upstream
        public let transform: (Upstream.Output) throws -> Output

        public init(upstream: Upstream, transform: @escaping (Upstream.Output) throws -> Output) {
            self.upstream = upstream
            self.transform = transform
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == any Error {
            let transform = self.transform
            upstream.subscribeTrying("TryMap", subscriber) { .send(try transform($0)) }
        }
    }

    public struct MapKeyPath<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let keyPath: KeyPath<Upstream.Output, Output>

        init(upstream: Upstream, keyPath: KeyPath<Upstream.Output, Output>) {
            self.upstream = upstream
            self.keyPath = keyPath
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, Upstream.Failure == S.Failure {
            let keyPath = self.keyPath
            upstream.subscribeInner("ValueForKey", subscriber) { .send($0[keyPath: keyPath]) }
        }
    }

    public struct MapKeyPath2<Upstream, Output0, Output1>: Publisher where Upstream: Publisher {
        public typealias Output = (Output0, Output1)
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let keyPath0: KeyPath<Upstream.Output, Output0>
        public let keyPath1: KeyPath<Upstream.Output, Output1>

        init(upstream: Upstream, keyPath0: KeyPath<Upstream.Output, Output0>, keyPath1: KeyPath<Upstream.Output, Output1>) {
            self.upstream = upstream
            self.keyPath0 = keyPath0
            self.keyPath1 = keyPath1
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == (Output0, Output1) {
            let (keyPath0, keyPath1) = (self.keyPath0, self.keyPath1)
            upstream.subscribeInner("ValueForKeys", subscriber) { .send(($0[keyPath: keyPath0], $0[keyPath: keyPath1])) }
        }
    }

    public struct MapKeyPath3<Upstream, Output0, Output1, Output2>: Publisher where Upstream: Publisher {
        public typealias Output = (Output0, Output1, Output2)
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let keyPath0: KeyPath<Upstream.Output, Output0>
        public let keyPath1: KeyPath<Upstream.Output, Output1>
        public let keyPath2: KeyPath<Upstream.Output, Output2>

        init(upstream: Upstream, keyPath0: KeyPath<Upstream.Output, Output0>, keyPath1: KeyPath<Upstream.Output, Output1>,
             keyPath2: KeyPath<Upstream.Output, Output2>) {
            self.upstream = upstream
            self.keyPath0 = keyPath0
            self.keyPath1 = keyPath1
            self.keyPath2 = keyPath2
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            S.Input == (Output0, Output1, Output2) {
            let (keyPath0, keyPath1, keyPath2) = (self.keyPath0, self.keyPath1, self.keyPath2)
            upstream.subscribeInner("ValueForKeys", subscriber) {
                .send(($0[keyPath: keyPath0], $0[keyPath: keyPath1], $0[keyPath: keyPath2]))
            }
        }
    }
}

extension Publishers.Map {
    public func map<T>(_ transform: @escaping (Output) -> T) -> Publishers.Map<Upstream, T> {
        let first = self.transform
        return Publishers.Map(upstream: upstream) { transform(first($0)) }
    }

    public func tryMap<T>(_ transform: @escaping (Output) throws -> T) -> Publishers.TryMap<Upstream, T> {
        let first = self.transform
        return Publishers.TryMap(upstream: upstream) { try transform(first($0)) }
    }
}

extension Publishers.TryMap {
    public func map<T>(_ transform: @escaping (Output) -> T) -> Publishers.TryMap<Upstream, T> {
        let first = self.transform
        return Publishers.TryMap(upstream: upstream) { transform(try first($0)) }
    }

    public func tryMap<T>(_ transform: @escaping (Output) throws -> T) -> Publishers.TryMap<Upstream, T> {
        let first = self.transform
        return Publishers.TryMap(upstream: upstream) { try transform(try first($0)) }
    }
}

// MARK: - compactMap

extension Publisher {
    public func compactMap<T>(_ transform: @escaping (Self.Output) -> T?) -> Publishers.CompactMap<Self, T> {
        Publishers.CompactMap(upstream: self, transform: transform)
    }

    public func tryCompactMap<T>(_ transform: @escaping (Self.Output) throws -> T?) -> Publishers.TryCompactMap<Self, T> {
        Publishers.TryCompactMap(upstream: self, transform: transform)
    }
}

extension Publishers {
    public struct CompactMap<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let transform: (Upstream.Output) -> Output?

        public init(upstream: Upstream, transform: @escaping (Upstream.Output) -> Output?) {
            self.upstream = upstream
            self.transform = transform
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, Upstream.Failure == S.Failure {
            let transform = self.transform
            upstream.subscribeInner("CompactMap", subscriber) { transform($0).map { .send($0) } ?? .skip }
        }
    }

    public struct TryCompactMap<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Error

        public let upstream: Upstream
        public let transform: (Upstream.Output) throws -> Output?

        public init(upstream: Upstream, transform: @escaping (Upstream.Output) throws -> Output?) {
            self.upstream = upstream
            self.transform = transform
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == any Error {
            let transform = self.transform
            upstream.subscribeTrying("TryCompactMap", subscriber) { try transform($0).map { .send($0) } ?? .skip }
        }
    }
}

extension Publishers.CompactMap {
    public func compactMap<T>(_ transform: @escaping (Output) -> T?) -> Publishers.CompactMap<Upstream, T> {
        let first = self.transform
        return Publishers.CompactMap(upstream: upstream) { first($0).flatMap(transform) }
    }

    public func map<T>(_ transform: @escaping (Output) -> T) -> Publishers.CompactMap<Upstream, T> {
        let first = self.transform
        return Publishers.CompactMap(upstream: upstream) { first($0).map(transform) }
    }
}

extension Publishers.TryCompactMap {
    public func compactMap<T>(_ transform: @escaping (Output) throws -> T?) -> Publishers.TryCompactMap<Upstream, T> {
        let first = self.transform
        return Publishers.TryCompactMap(upstream: upstream) { try first($0).flatMap(transform) }
    }
}

// MARK: - filter

extension Publisher {
    public func filter(_ isIncluded: @escaping (Self.Output) -> Bool) -> Publishers.Filter<Self> {
        Publishers.Filter(upstream: self, isIncluded: isIncluded)
    }

    public func tryFilter(_ isIncluded: @escaping (Self.Output) throws -> Bool) -> Publishers.TryFilter<Self> {
        Publishers.TryFilter(upstream: self, isIncluded: isIncluded)
    }
}

extension Publishers {
    public struct Filter<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let isIncluded: (Upstream.Output) -> Bool

        public init(upstream: Upstream, isIncluded: @escaping (Upstream.Output) -> Bool) {
            self.upstream = upstream
            self.isIncluded = isIncluded
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let isIncluded = self.isIncluded
            upstream.subscribeInner("Filter", subscriber) { isIncluded($0) ? .send($0) : .skip }
        }
    }

    public struct TryFilter<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let isIncluded: (Upstream.Output) throws -> Bool

        public init(upstream: Upstream, isIncluded: @escaping (Upstream.Output) throws -> Bool) {
            self.upstream = upstream
            self.isIncluded = isIncluded
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let isIncluded = self.isIncluded
            upstream.subscribeTrying("TryFilter", subscriber) { try isIncluded($0) ? .send($0) : .skip }
        }
    }
}

extension Publishers.Filter {
    public func filter(_ isIncluded: @escaping (Publishers.Filter<Upstream>.Output) -> Bool) -> Publishers.Filter<Upstream> {
        let first = self.isIncluded
        return Publishers.Filter(upstream: upstream) { first($0) && isIncluded($0) }
    }

    public func tryFilter(_ isIncluded: @escaping (Publishers.Filter<Upstream>.Output) throws -> Bool)
        -> Publishers.TryFilter<Upstream> {
        let first = self.isIncluded
        return Publishers.TryFilter(upstream: upstream) { try first($0) && isIncluded($0) }
    }
}

extension Publishers.TryFilter {
    public func filter(_ isIncluded: @escaping (Publishers.TryFilter<Upstream>.Output) -> Bool)
        -> Publishers.TryFilter<Upstream> {
        let first = self.isIncluded
        return Publishers.TryFilter(upstream: upstream) { try first($0) && isIncluded($0) }
    }

    public func tryFilter(_ isIncluded: @escaping (Publishers.TryFilter<Upstream>.Output) throws -> Bool)
        -> Publishers.TryFilter<Upstream> {
        let first = self.isIncluded
        return Publishers.TryFilter(upstream: upstream) { try first($0) && isIncluded($0) }
    }
}

// MARK: - removeDuplicates

extension Publisher where Self.Output: Equatable {
    public func removeDuplicates() -> Publishers.RemoveDuplicates<Self> {
        Publishers.RemoveDuplicates(upstream: self, predicate: ==)
    }
}

extension Publisher {
    public func removeDuplicates(by predicate: @escaping (Self.Output, Self.Output) -> Bool)
        -> Publishers.RemoveDuplicates<Self> {
        Publishers.RemoveDuplicates(upstream: self, predicate: predicate)
    }

    public func tryRemoveDuplicates(by predicate: @escaping (Self.Output, Self.Output) throws -> Bool)
        -> Publishers.TryRemoveDuplicates<Self> {
        Publishers.TryRemoveDuplicates(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    /// Drops a value its predicate finds the same as the last one sent.
    public struct RemoveDuplicates<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Publishers.RemoveDuplicates<Upstream>.Output, Publishers.RemoveDuplicates<Upstream>.Output) -> Bool

        public init(upstream: Upstream,
                    predicate: @escaping (Publishers.RemoveDuplicates<Upstream>.Output,
                                          Publishers.RemoveDuplicates<Upstream>.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let predicate = self.predicate
            var last: Output?
            upstream.subscribeInner("RemoveDuplicates", subscriber) { value in
                if let previous = last, predicate(previous, value) { return .skip }
                last = value
                return .send(value)
            }
        }
    }

    public struct TryRemoveDuplicates<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Publishers.TryRemoveDuplicates<Upstream>.Output,
                               Publishers.TryRemoveDuplicates<Upstream>.Output) throws -> Bool

        public init(upstream: Upstream,
                    predicate: @escaping (Publishers.TryRemoveDuplicates<Upstream>.Output,
                                          Publishers.TryRemoveDuplicates<Upstream>.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let predicate = self.predicate
            var last: Output?
            upstream.subscribeTrying("TryRemoveDuplicates", subscriber) { value in
                if let previous = last, try predicate(previous, value) { return .skip }
                last = value
                return .send(value)
            }
        }
    }
}

// MARK: - first

extension Publisher {
    public func first() -> Publishers.First<Self> {
        Publishers.First(upstream: self)
    }

    public func first(where predicate: @escaping (Self.Output) -> Bool) -> Publishers.FirstWhere<Self> {
        Publishers.FirstWhere(upstream: self, predicate: predicate)
    }

    public func tryFirst(where predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryFirstWhere<Self> {
        Publishers.TryFirstWhere(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    public struct First<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            upstream.subscribeInner("First", subscriber) { .sendAndFinish($0) }
        }
    }

    public struct FirstWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Publishers.FirstWhere<Upstream>.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.FirstWhere<Upstream>.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let predicate = self.predicate
            upstream.subscribeInner("TryFirst", subscriber) { predicate($0) ? .sendAndFinish($0) : .skip }
        }
    }

    public struct TryFirstWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Publishers.TryFirstWhere<Upstream>.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.TryFirstWhere<Upstream>.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let predicate = self.predicate
            upstream.subscribeTrying("TryFirstWhere", subscriber) { try predicate($0) ? .sendAndFinish($0) : .skip }
        }
    }
}

extension Publishers.First: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.First<Upstream>, rhs: Publishers.First<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}

// MARK: - dropFirst, drop(while:)

extension Publisher {
    public func dropFirst(_ count: Int = 1) -> Publishers.Drop<Self> {
        Publishers.Drop(upstream: self, count: count)
    }

    public func drop(while predicate: @escaping (Self.Output) -> Bool) -> Publishers.DropWhile<Self> {
        Publishers.DropWhile(upstream: self, predicate: predicate)
    }

    public func tryDrop(while predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryDropWhile<Self> {
        Publishers.TryDropWhile(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    public struct Drop<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let count: Int

        public init(upstream: Upstream, count: Int) {
            precondition(count >= 0, "dropFirst's count can't be negative")
            self.upstream = upstream
            self.count = count
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            var remaining = count
            upstream.subscribeInner("Drop", subscriber) { value in
                guard remaining > 0 else { return .send(value) }
                remaining -= 1
                return .skip
            }
        }
    }

    public struct DropWhile<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Publishers.DropWhile<Upstream>.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.DropWhile<Upstream>.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let predicate = self.predicate
            var dropping = true
            upstream.subscribeInner("DropWhile", subscriber) { value in
                if dropping && predicate(value) { return .skip }
                dropping = false
                return .send(value)
            }
        }
    }

    public struct TryDropWhile<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Publishers.TryDropWhile<Upstream>.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.TryDropWhile<Upstream>.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let predicate = self.predicate
            var dropping = true
            upstream.subscribeTrying("TryDropWhile", subscriber) { value in
                if dropping, try predicate(value) { return .skip }
                dropping = false
                return .send(value)
            }
        }
    }
}

extension Publishers.Drop: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Drop<Upstream>, rhs: Publishers.Drop<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.count == rhs.count
    }
}

// MARK: - prefix, output(at:), prefix(while:)

extension Publisher {
    public func prefix(_ maxLength: Int) -> Publishers.Output<Self> {
        precondition(maxLength >= 0, "prefix's length can't be negative")
        return Publishers.Output(upstream: self, range: 0 ..< maxLength)
    }

    public func output(at index: Int) -> Publishers.Output<Self> {
        Publishers.Output(upstream: self, range: index ..< index + 1)
    }

    public func output<R>(in range: R) -> Publishers.Output<Self> where R: RangeExpression, R.Bound == Int {
        Publishers.Output(upstream: self, range: range.relative(to: 0 ..< Int.max))
    }

    public func prefix(while predicate: @escaping (Self.Output) -> Bool) -> Publishers.PrefixWhile<Self> {
        Publishers.PrefixWhile(upstream: self, predicate: predicate)
    }

    public func tryPrefix(while predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryPrefixWhile<Self> {
        Publishers.TryPrefixWhile(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    /// The values at the positions in `range` (counted from 0), finishing
    /// after the last.
    public struct Output<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let range: CountableRange<Int>

        public init(upstream: Upstream, range: CountableRange<Int>) {
            precondition(range.lowerBound >= 0, "An output range can't start below 0")
            self.upstream = upstream
            self.range = range
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let range = self.range
            guard !range.isEmpty else {
                // Nothing to send: finished, upstream not subscribed.
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .finished)
                return
            }
            var index = 0
            upstream.subscribeInner("Output", subscriber) { value in
                defer { index += 1 }
                if index < range.lowerBound { return .skip }
                return index == range.upperBound - 1 ? .sendAndFinish(value) : .send(value)
            }
        }
    }

    public struct PrefixWhile<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Publishers.PrefixWhile<Upstream>.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.PrefixWhile<Upstream>.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let predicate = self.predicate
            upstream.subscribeInner("PrefixWhile", subscriber) { predicate($0) ? .send($0) : .finish }
        }
    }

    public struct TryPrefixWhile<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Publishers.TryPrefixWhile<Upstream>.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.TryPrefixWhile<Upstream>.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let predicate = self.predicate
            upstream.subscribeTrying("TryPrefixWhile", subscriber) { try predicate($0) ? .send($0) : .finish }
        }
    }
}

extension Publishers.Output: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Output<Upstream>, rhs: Publishers.Output<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.range == rhs.range
    }
}

// MARK: - scan

extension Publisher {
    public func scan<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Self.Output) -> T) -> Publishers.Scan<Self, T> {
        Publishers.Scan(upstream: self, initialResult: initialResult, nextPartialResult: nextPartialResult)
    }

    public func tryScan<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Self.Output) throws -> T)
        -> Publishers.TryScan<Self, T> {
        Publishers.TryScan(upstream: self, initialResult: initialResult, nextPartialResult: nextPartialResult)
    }
}

extension Publishers {
    public struct Scan<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let initialResult: Output
        public let nextPartialResult: (Output, Upstream.Output) -> Output

        public init(upstream: Upstream, initialResult: Output, nextPartialResult: @escaping (Output, Upstream.Output) -> Output) {
            self.upstream = upstream
            self.initialResult = initialResult
            self.nextPartialResult = nextPartialResult
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, Upstream.Failure == S.Failure {
            let next = nextPartialResult
            var accumulated = initialResult
            upstream.subscribeInner("Scan", subscriber) { value in
                accumulated = next(accumulated, value)
                return .send(accumulated)
            }
        }
    }

    public struct TryScan<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Error

        public let upstream: Upstream
        public let initialResult: Output
        public let nextPartialResult: (Output, Upstream.Output) throws -> Output

        public init(upstream: Upstream, initialResult: Output,
                    nextPartialResult: @escaping (Output, Upstream.Output) throws -> Output) {
            self.upstream = upstream
            self.initialResult = initialResult
            self.nextPartialResult = nextPartialResult
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == any Error {
            let next = nextPartialResult
            var accumulated = initialResult
            upstream.subscribeTrying("TryScan", subscriber) { value in
                accumulated = try next(accumulated, value)
                return .send(accumulated)
            }
        }
    }
}

// MARK: - errors

extension Publisher {
    public func mapError<E>(_ transform: @escaping (Self.Failure) -> E) -> Publishers.MapError<Self, E> where E: Error {
        Publishers.MapError(upstream: self, transform: transform)
    }

    public func replaceError(with output: Self.Output) -> Publishers.ReplaceError<Self> {
        Publishers.ReplaceError(upstream: self, output: output)
    }

    public func replaceEmpty(with output: Self.Output) -> Publishers.ReplaceEmpty<Self> {
        Publishers.ReplaceEmpty(upstream: self, output: output)
    }

    public func assertNoFailure(_ prefix: String = "", file: StaticString = #file, line: UInt = #line)
        -> Publishers.AssertNoFailure<Self> {
        Publishers.AssertNoFailure(upstream: self, prefix: prefix, file: file, line: line)
    }
}

extension Publisher where Self.Failure == Never {
    public func setFailureType<E>(to failureType: E.Type) -> Publishers.SetFailureType<Self, E> where E: Error {
        Publishers.SetFailureType(upstream: self)
    }
}

extension Publishers {
    public struct MapError<Upstream, Failure>: Publisher where Upstream: Publisher, Failure: Error {
        public typealias Output = Upstream.Output

        public let upstream: Upstream
        public let transform: (Upstream.Failure) -> Failure

        public init(upstream: Upstream, transform: @escaping (Upstream.Failure) -> Failure) {
            self.upstream = upstream
            self.transform = transform
        }

        public init(upstream: Upstream, _ map: @escaping (Upstream.Failure) -> Failure) {
            self.init(upstream: upstream, transform: map)
        }

        public func receive<S>(subscriber: S) where Failure == S.Failure, S: Subscriber, Upstream.Output == S.Input {
            let transform = self.transform
            upstream.subscribe(OperatorInner<Upstream.Output, Upstream.Failure, S>(
                "MapError", downstream: subscriber, onValue: { .send($0) },
                onCompletion: { (nil, $0.mapError(transform)) }))
        }
    }

    public struct SetFailureType<Upstream, Failure>: Publisher where Upstream: Publisher, Failure: Error,
        Upstream.Failure == Never {
        public typealias Output = Upstream.Output

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where Failure == S.Failure, S: Subscriber, Upstream.Output == S.Input {
            upstream.subscribe(OperatorInner<Upstream.Output, Never, S>(
                "SetFailureType", downstream: subscriber, onValue: { .send($0) },
                onCompletion: { _ in (nil, .finished) }))
        }

        public func setFailureType<E>(to failure: E.Type) -> Publishers.SetFailureType<Upstream, E> where E: Error {
            Publishers.SetFailureType<Upstream, E>(upstream: upstream)
        }
    }

    /// Finishes with `output` in place of a failure.
    public struct ReplaceError<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Never

        public let output: Publishers.ReplaceError<Upstream>.Output
        public let upstream: Upstream

        public init(upstream: Upstream, output: Publishers.ReplaceError<Upstream>.Output) {
            self.upstream = upstream
            self.output = output
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == Never {
            let output = self.output
            upstream.subscribe(OperatorInner<Upstream.Output, Upstream.Failure, S>(
                "ReplaceError", downstream: subscriber, onValue: { .send($0) },
                onCompletion: { completion in
                    if case .failure = completion { return (output, .finished) }
                    return (nil, .finished)
                }))
        }
    }

    /// Sends `output` if upstream finishes without a value.
    public struct ReplaceEmpty<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let output: Publishers.ReplaceEmpty<Upstream>.Output
        public let upstream: Upstream

        public init(upstream: Upstream, output: Publishers.ReplaceEmpty<Upstream>.Output) {
            self.upstream = upstream
            self.output = output
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let output = self.output
            var empty = true
            upstream.subscribe(OperatorInner<Upstream.Output, Upstream.Failure, S>(
                "ReplaceEmpty", downstream: subscriber,
                onValue: { value in
                    empty = false
                    return .send(value)
                },
                onCompletion: { completion in
                    if case .finished = completion, empty { return (output, .finished) }
                    return (nil, completion)
                }))
        }
    }

    /// Stops the program on a failure, as a check that none can come.
    public struct AssertNoFailure<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Never

        public let upstream: Upstream
        public let prefix: String
        public let file: StaticString
        public let line: UInt

        public init(upstream: Upstream, prefix: String, file: StaticString, line: UInt) {
            self.upstream = upstream
            self.prefix = prefix
            self.file = file
            self.line = line
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == Never {
            let (prefix, file, line) = (self.prefix, self.file, self.line)
            upstream.subscribe(OperatorInner<Upstream.Output, Upstream.Failure, S>(
                "AssertNoFailure", downstream: subscriber, onValue: { .send($0) },
                onCompletion: { completion in
                    if case .failure(let error) = completion {
                        fatalError("\(prefix.isEmpty ? "" : prefix + ": ")Unexpected failure: \(error)",
                                   file: file, line: line)
                    }
                    return (nil, .finished)
                }))
        }
    }
}

extension Publishers.SetFailureType: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.SetFailureType<Upstream, Failure>, rhs: Publishers.SetFailureType<Upstream, Failure>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}
extension Publishers.ReplaceError: Equatable where Upstream: Equatable, Upstream.Output: Equatable {
    public static func == (lhs: Publishers.ReplaceError<Upstream>, rhs: Publishers.ReplaceError<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.output == rhs.output
    }
}
extension Publishers.ReplaceEmpty: Equatable where Upstream: Equatable, Upstream.Output: Equatable {
    public static func == (lhs: Publishers.ReplaceEmpty<Upstream>, rhs: Publishers.ReplaceEmpty<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.output == rhs.output
    }
}

// MARK: - collect(_:)

extension Publisher {
    public func collect(_ count: Int) -> Publishers.CollectByCount<Self> {
        Publishers.CollectByCount(upstream: self, count: count)
    }
}

extension Publishers {
    /// Arrays of `count` values; a shorter last one when upstream finishes.
    public struct CollectByCount<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let count: Int

        public init(upstream: Upstream, count: Int) {
            precondition(count > 0, "collect's count must be at least 1")
            self.upstream = upstream
            self.count = count
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            S.Input == [Upstream.Output] {
            let count = self.count
            var batch: [Upstream.Output] = []
            upstream.subscribe(OperatorInner<Upstream.Output, Upstream.Failure, S>(
                "CollectByCount", downstream: subscriber,
                onValue: { value in
                    batch.append(value)
                    guard batch.count == count else { return .skip }
                    defer { batch = [] }
                    return .send(batch)
                },
                onCompletion: { completion in
                    if case .finished = completion, !batch.isEmpty { return (batch, .finished) }
                    return (nil, completion)
                }))
        }
    }
}

extension Publishers.CollectByCount: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.CollectByCount<Upstream>, rhs: Publishers.CollectByCount<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.count == rhs.count
    }
}
