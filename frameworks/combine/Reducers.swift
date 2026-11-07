// The operators that send one value when upstream is done (or as soon as
// the answer is known): reduce, collect, count, last, min and max,
// contains, allSatisfy, ignoreOutput. Each subscription is a ReducerInner
// (Inner.swift), which asks upstream for everything.

extension Publisher {
    func subscribeReducer<S: Subscriber>(_ name: String, _ subscriber: S,
                                         onValue: @escaping (Output) -> ReduceStep<S.Failure>,
                                         result: @escaping () -> S.Input?) where S.Failure == Failure {
        subscribe(ReducerInner<Output, Failure, S>(name, downstream: subscriber, onValue: onValue, result: result))
    }

    func subscribeTryingReducer<S: Subscriber>(_ name: String, _ subscriber: S,
                                               onValue: @escaping (Output) throws -> ReduceStep<any Error>,
                                               result: @escaping () -> S.Input?) where S.Failure == any Error {
        subscribe(ReducerInner<Output, Failure, S>(name, downstream: subscriber, onValue: { value in
            do { return try onValue(value) } catch { return .fail(error) }
        }, result: result, mapFailure: { $0 }))
    }
}

// MARK: - reduce, collect, count

extension Publisher {
    public func reduce<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Self.Output) -> T)
        -> Publishers.Reduce<Self, T> {
        Publishers.Reduce(upstream: self, initial: initialResult, nextPartialResult: nextPartialResult)
    }

    public func tryReduce<T>(_ initialResult: T, _ nextPartialResult: @escaping (T, Self.Output) throws -> T)
        -> Publishers.TryReduce<Self, T> {
        Publishers.TryReduce(upstream: self, initial: initialResult, nextPartialResult: nextPartialResult)
    }

    public func collect() -> Publishers.Collect<Self> {
        Publishers.Collect(upstream: self)
    }

    public func count() -> Publishers.Count<Self> {
        Publishers.Count(upstream: self)
    }

    public func ignoreOutput() -> Publishers.IgnoreOutput<Self> {
        Publishers.IgnoreOutput(upstream: self)
    }
}

extension Publishers {
    public struct Reduce<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let initial: Output
        public let nextPartialResult: (Output, Upstream.Output) -> Output

        public init(upstream: Upstream, initial: Output, nextPartialResult: @escaping (Output, Upstream.Output) -> Output) {
            self.upstream = upstream
            self.initial = initial
            self.nextPartialResult = nextPartialResult
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, Upstream.Failure == S.Failure {
            let next = nextPartialResult
            var accumulated = initial
            upstream.subscribeReducer("Reduce", subscriber, onValue: { value in
                accumulated = next(accumulated, value)
                return .continue
            }, result: { accumulated })
        }
    }

    public struct TryReduce<Upstream, Output>: Publisher where Upstream: Publisher {
        public typealias Failure = Error

        public let upstream: Upstream
        public let initial: Output
        public let nextPartialResult: (Output, Upstream.Output) throws -> Output

        public init(upstream: Upstream, initial: Output,
                    nextPartialResult: @escaping (Output, Upstream.Output) throws -> Output) {
            self.upstream = upstream
            self.initial = initial
            self.nextPartialResult = nextPartialResult
        }

        public func receive<S>(subscriber: S) where Output == S.Input, S: Subscriber, S.Failure == any Error {
            let next = nextPartialResult
            var accumulated = initial
            upstream.subscribeTryingReducer("TryReduce", subscriber, onValue: { value in
                accumulated = try next(accumulated, value)
                return .continue
            }, result: { accumulated })
        }
    }

    public struct Collect<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = [Upstream.Output]
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure,
            S.Input == [Upstream.Output] {
            var values: [Upstream.Output] = []
            upstream.subscribeReducer("Collect", subscriber, onValue: { value in
                values.append(value)
                return .continue
            }, result: { values })
        }
    }

    public struct Count<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Int
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == Int {
            var count = 0
            upstream.subscribeReducer("Count", subscriber, onValue: { _ in
                count += 1
                return .continue
            }, result: { count })
        }
    }

    public struct IgnoreOutput<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Never
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == Never {
            upstream.subscribeReducer("IgnoreOutput", subscriber, onValue: { _ in .continue }, result: { nil })
        }
    }
}

extension Publishers.Collect: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Collect<Upstream>, rhs: Publishers.Collect<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}
extension Publishers.Count: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Count<Upstream>, rhs: Publishers.Count<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}
extension Publishers.IgnoreOutput: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.IgnoreOutput<Upstream>, rhs: Publishers.IgnoreOutput<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}

// MARK: - last

extension Publisher {
    public func last() -> Publishers.Last<Self> {
        Publishers.Last(upstream: self)
    }

    public func last(where predicate: @escaping (Self.Output) -> Bool) -> Publishers.LastWhere<Self> {
        Publishers.LastWhere(upstream: self, predicate: predicate)
    }

    public func tryLast(where predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryLastWhere<Self> {
        Publishers.TryLastWhere(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    public struct Last<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream

        public init(upstream: Upstream) {
            self.upstream = upstream
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            var last: Output?
            upstream.subscribeReducer("Last", subscriber, onValue: { value in
                last = value
                return .continue
            }, result: { last })
        }
    }

    public struct LastWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Publishers.LastWhere<Upstream>.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.LastWhere<Upstream>.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let predicate = self.predicate
            var last: Output?
            upstream.subscribeReducer("LastWhere", subscriber, onValue: { value in
                if predicate(value) { last = value }
                return .continue
            }, result: { last })
        }
    }

    public struct TryLastWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Publishers.TryLastWhere<Upstream>.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Publishers.TryLastWhere<Upstream>.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let predicate = self.predicate
            var last: Output?
            upstream.subscribeTryingReducer("TryLastWhere", subscriber, onValue: { value in
                if try predicate(value) { last = value }
                return .continue
            }, result: { last })
        }
    }
}

extension Publishers.Last: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Last<Upstream>, rhs: Publishers.Last<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream
    }
}

// MARK: - min, max

extension Publisher where Self.Output: Comparable {
    public func min() -> Publishers.Comparison<Self> {
        Publishers.Comparison(upstream: self, areInIncreasingOrder: >)
    }

    public func max() -> Publishers.Comparison<Self> {
        Publishers.Comparison(upstream: self, areInIncreasingOrder: <)
    }
}

extension Publisher {
    public func min(by areInIncreasingOrder: @escaping (Self.Output, Self.Output) -> Bool) -> Publishers.Comparison<Self> {
        Publishers.Comparison(upstream: self) { areInIncreasingOrder($1, $0) }
    }

    public func tryMin(by areInIncreasingOrder: @escaping (Self.Output, Self.Output) throws -> Bool)
        -> Publishers.TryComparison<Self> {
        Publishers.TryComparison(upstream: self) { try areInIncreasingOrder($1, $0) }
    }

    public func max(by areInIncreasingOrder: @escaping (Self.Output, Self.Output) -> Bool) -> Publishers.Comparison<Self> {
        Publishers.Comparison(upstream: self, areInIncreasingOrder: areInIncreasingOrder)
    }

    public func tryMax(by areInIncreasingOrder: @escaping (Self.Output, Self.Output) throws -> Bool)
        -> Publishers.TryComparison<Self> {
        Publishers.TryComparison(upstream: self, areInIncreasingOrder: areInIncreasingOrder)
    }
}

extension Publishers {
    /// The greatest value by `areInIncreasingOrder` (min passes it reversed):
    /// a value replaces the one kept when the kept one orders before it.
    public struct Comparison<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let areInIncreasingOrder: (Upstream.Output, Upstream.Output) -> Bool

        public init(upstream: Upstream, areInIncreasingOrder: @escaping (Upstream.Output, Upstream.Output) -> Bool) {
            self.upstream = upstream
            self.areInIncreasingOrder = areInIncreasingOrder
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, Upstream.Output == S.Input {
            let ordered = areInIncreasingOrder
            var best: Output?
            upstream.subscribeReducer("Comparison", subscriber, onValue: { value in
                if let current = best {
                    if ordered(current, value) { best = value }
                } else {
                    best = value
                }
                return .continue
            }, result: { best })
        }
    }

    public struct TryComparison<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Upstream.Output
        public typealias Failure = Error

        public let upstream: Upstream
        public let areInIncreasingOrder: (Upstream.Output, Upstream.Output) throws -> Bool

        public init(upstream: Upstream, areInIncreasingOrder: @escaping (Upstream.Output, Upstream.Output) throws -> Bool) {
            self.upstream = upstream
            self.areInIncreasingOrder = areInIncreasingOrder
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Output == S.Input, S.Failure == any Error {
            let ordered = areInIncreasingOrder
            var best: Output?
            upstream.subscribeTryingReducer("TryComparison", subscriber, onValue: { value in
                if let current = best {
                    if try ordered(current, value) { best = value }
                } else {
                    best = value
                }
                return .continue
            }, result: { best })
        }
    }
}

// MARK: - contains, allSatisfy

extension Publisher where Self.Output: Equatable {
    public func contains(_ output: Self.Output) -> Publishers.Contains<Self> {
        Publishers.Contains(upstream: self, output: output)
    }
}

extension Publisher {
    public func contains(where predicate: @escaping (Self.Output) -> Bool) -> Publishers.ContainsWhere<Self> {
        Publishers.ContainsWhere(upstream: self, predicate: predicate)
    }

    public func tryContains(where predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryContainsWhere<Self> {
        Publishers.TryContainsWhere(upstream: self, predicate: predicate)
    }

    public func allSatisfy(_ predicate: @escaping (Self.Output) -> Bool) -> Publishers.AllSatisfy<Self> {
        Publishers.AllSatisfy(upstream: self, predicate: predicate)
    }

    public func tryAllSatisfy(_ predicate: @escaping (Self.Output) throws -> Bool) -> Publishers.TryAllSatisfy<Self> {
        Publishers.TryAllSatisfy(upstream: self, predicate: predicate)
    }
}

extension Publishers {
    public struct Contains<Upstream>: Publisher where Upstream: Publisher, Upstream.Output: Equatable {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let output: Upstream.Output

        public init(upstream: Upstream, output: Upstream.Output) {
            self.upstream = upstream
            self.output = output
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == Bool {
            let wanted = output
            var found = false
            upstream.subscribeReducer("Contains", subscriber, onValue: { value in
                guard value == wanted else { return .continue }
                found = true
                return .finish
            }, result: { found })
        }
    }

    public struct ContainsWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Upstream.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == Bool {
            let predicate = self.predicate
            var found = false
            upstream.subscribeReducer("ContainsWhere", subscriber, onValue: { value in
                guard predicate(value) else { return .continue }
                found = true
                return .finish
            }, result: { found })
        }
    }

    public struct TryContainsWhere<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Bool
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Upstream.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == any Error, S.Input == Bool {
            let predicate = self.predicate
            var found = false
            upstream.subscribeTryingReducer("TryContainsWhere", subscriber, onValue: { value in
                guard try predicate(value) else { return .continue }
                found = true
                return .finish
            }, result: { found })
        }
    }

    public struct AllSatisfy<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Bool
        public typealias Failure = Upstream.Failure

        public let upstream: Upstream
        public let predicate: (Upstream.Output) -> Bool

        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, Upstream.Failure == S.Failure, S.Input == Bool {
            let predicate = self.predicate
            var satisfied = true
            upstream.subscribeReducer("AllSatisfy", subscriber, onValue: { value in
                guard !predicate(value) else { return .continue }
                satisfied = false
                return .finish
            }, result: { satisfied })
        }
    }

    public struct TryAllSatisfy<Upstream>: Publisher where Upstream: Publisher {
        public typealias Output = Bool
        public typealias Failure = Error

        public let upstream: Upstream
        public let predicate: (Upstream.Output) throws -> Bool

        public init(upstream: Upstream, predicate: @escaping (Upstream.Output) throws -> Bool) {
            self.upstream = upstream
            self.predicate = predicate
        }

        public func receive<S>(subscriber: S) where S: Subscriber, S.Failure == any Error, S.Input == Bool {
            let predicate = self.predicate
            var satisfied = true
            upstream.subscribeTryingReducer("TryAllSatisfy", subscriber, onValue: { value in
                guard try !predicate(value) else { return .continue }
                satisfied = false
                return .finish
            }, result: { satisfied })
        }
    }
}

extension Publishers.Contains: Equatable where Upstream: Equatable {
    public static func == (lhs: Publishers.Contains<Upstream>, rhs: Publishers.Contains<Upstream>) -> Bool {
        lhs.upstream == rhs.upstream && lhs.output == rhs.output
    }
}
