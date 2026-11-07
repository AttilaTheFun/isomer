// The operators of the Optional, Result and Sequence publishers: as with
// Just's, their values are known up front, so each answers at once with
// another such publisher (Apple's overloads, so code gets Apple's types).
// An Optional publisher's reductions answer nothing when it is empty (its
// count of nothing is no value, not 0), as Apple's do.

// MARK: - Optional.Publisher

extension Optional.Publisher where Wrapped: Equatable {
    public func contains(_ output: Optional<Wrapped>.Publisher.Output) -> Optional<Bool>.Publisher {
        Optional<Bool>.Publisher(self.output.map { $0 == output })
    }

    public func removeDuplicates() -> Optional<Wrapped>.Publisher { self }
}

extension Optional.Publisher where Wrapped: Comparable {
    public func min() -> Optional<Wrapped>.Publisher { self }
    public func max() -> Optional<Wrapped>.Publisher { self }
}

extension Optional.Publisher {
    public func allSatisfy(_ predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Bool>.Publisher {
        Optional<Bool>.Publisher(output.map(predicate))
    }

    public func collect() -> Optional<[Optional<Wrapped>.Publisher.Output]>.Publisher {
        Optional<[Wrapped]>.Publisher(output.map { [$0] })
    }

    public func compactMap<T>(_ transform: (Optional<Wrapped>.Publisher.Output) -> T?) -> Optional<T>.Publisher {
        Optional<T>.Publisher(output.flatMap(transform))
    }

    public func min(by areInIncreasingOrder: (Optional<Wrapped>.Publisher.Output, Optional<Wrapped>.Publisher.Output) -> Bool)
        -> Optional<Wrapped>.Publisher { self }

    public func max(by areInIncreasingOrder: (Optional<Wrapped>.Publisher.Output, Optional<Wrapped>.Publisher.Output) -> Bool)
        -> Optional<Wrapped>.Publisher { self }

    public func contains(where predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Bool>.Publisher {
        Optional<Bool>.Publisher(output.map(predicate))
    }

    public func count() -> Optional<Int>.Publisher {
        Optional<Int>.Publisher(output.map { _ in 1 })
    }

    public func dropFirst(_ count: Int = 1) -> Optional<Wrapped>.Publisher {
        precondition(count >= 0, "dropFirst's count can't be negative")
        return Optional<Wrapped>.Publisher(count > 0 ? nil : output)
    }

    public func drop(while predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Wrapped>.Publisher {
        Optional<Wrapped>.Publisher(output.flatMap { predicate($0) ? nil : $0 })
    }

    public func first() -> Optional<Wrapped>.Publisher { self }

    public func first(where predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Wrapped>.Publisher {
        filter(predicate)
    }

    public func last() -> Optional<Wrapped>.Publisher { self }

    public func last(where predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Wrapped>.Publisher {
        filter(predicate)
    }

    public func filter(_ isIncluded: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Wrapped>.Publisher {
        Optional<Wrapped>.Publisher(output.flatMap { isIncluded($0) ? $0 : nil })
    }

    public func ignoreOutput() -> Empty<Optional<Wrapped>.Publisher.Output, Optional<Wrapped>.Publisher.Failure> {
        Empty()
    }

    public func map<T>(_ transform: (Optional<Wrapped>.Publisher.Output) -> T) -> Optional<T>.Publisher {
        Optional<T>.Publisher(output.map(transform))
    }

    public func output(at index: Int) -> Optional<Wrapped>.Publisher {
        precondition(index >= 0, "An index can't be negative")
        return Optional<Wrapped>.Publisher(index == 0 ? output : nil)
    }

    public func output<R>(in range: R) -> Optional<Wrapped>.Publisher where R: RangeExpression, R.Bound == Int {
        Optional<Wrapped>.Publisher(range.contains(0) ? output : nil)
    }

    public func prefix(_ maxLength: Int) -> Optional<Wrapped>.Publisher {
        precondition(maxLength >= 0, "prefix's length can't be negative")
        return Optional<Wrapped>.Publisher(maxLength > 0 ? output : nil)
    }

    public func prefix(while predicate: (Optional<Wrapped>.Publisher.Output) -> Bool) -> Optional<Wrapped>.Publisher {
        filter(predicate)
    }

    public func reduce<T>(_ initialResult: T, _ nextPartialResult: (T, Optional<Wrapped>.Publisher.Output) -> T)
        -> Optional<T>.Publisher {
        Optional<T>.Publisher(output.map { nextPartialResult(initialResult, $0) })
    }

    public func removeDuplicates(by predicate: (Optional<Wrapped>.Publisher.Output, Optional<Wrapped>.Publisher.Output) -> Bool)
        -> Optional<Wrapped>.Publisher { self }

    public func replaceError(with output: Optional<Wrapped>.Publisher.Output)
        -> Optional<Optional<Wrapped>.Publisher.Output>.Publisher { self }

    public func replaceEmpty(with output: Optional<Wrapped>.Publisher.Output) -> Just<Wrapped> {
        Just(self.output ?? output)
    }

    public func retry(_ times: Int) -> Optional<Wrapped>.Publisher { self }

    public func scan<T>(_ initialResult: T, _ nextPartialResult: (T, Optional<Wrapped>.Publisher.Output) -> T)
        -> Optional<T>.Publisher {
        Optional<T>.Publisher(output.map { nextPartialResult(initialResult, $0) })
    }
}

// MARK: - Result.Publisher

extension Result.Publisher where Success: Equatable {
    public func contains(_ output: Result<Success, Failure>.Publisher.Output) -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(result.map { $0 == output })
    }

    public func removeDuplicates() -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }
}

extension Result.Publisher where Success: Comparable {
    public func min() -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }
    public func max() -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }
}

extension Result.Publisher {
    /// The success through a throwing closure, its error and the
    /// publisher's both as any Error.
    private func trying<T>(_ body: (Success) throws -> T) -> Result<T, any Error>.Publisher {
        Result<T, any Error>.Publisher(result.mapError { $0 as any Error }.flatMap { value in
            Result<T, any Error> { try body(value) }
        })
    }

    public func allSatisfy(_ predicate: (Result<Success, Failure>.Publisher.Output) -> Bool) -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(result.map(predicate))
    }

    public func tryAllSatisfy(_ predicate: (Result<Success, Failure>.Publisher.Output) throws -> Bool)
        -> Result<Bool, any Error>.Publisher {
        trying(predicate)
    }

    public func collect() -> Result<[Result<Success, Failure>.Publisher.Output], Failure>.Publisher {
        Result<[Success], Failure>.Publisher(result.map { [$0] })
    }

    public func min(by areInIncreasingOrder: (Result<Success, Failure>.Publisher.Output,
                                              Result<Success, Failure>.Publisher.Output) -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func tryMin(by areInIncreasingOrder: (Result<Success, Failure>.Publisher.Output,
                                                 Result<Success, Failure>.Publisher.Output) throws -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, any Error>.Publisher {
        trying { $0 }
    }

    public func max(by areInIncreasingOrder: (Result<Success, Failure>.Publisher.Output,
                                              Result<Success, Failure>.Publisher.Output) -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func tryMax(by areInIncreasingOrder: (Result<Success, Failure>.Publisher.Output,
                                                 Result<Success, Failure>.Publisher.Output) throws -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, any Error>.Publisher {
        trying { $0 }
    }

    public func contains(where predicate: (Result<Success, Failure>.Publisher.Output) -> Bool) -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(result.map(predicate))
    }

    public func tryContains(where predicate: (Result<Success, Failure>.Publisher.Output) throws -> Bool)
        -> Result<Bool, any Error>.Publisher {
        trying(predicate)
    }

    public func count() -> Result<Int, Failure>.Publisher {
        Result<Int, Failure>.Publisher(result.map { _ in 1 })
    }

    public func first() -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }
    public func last() -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func ignoreOutput() -> Empty<Result<Success, Failure>.Publisher.Output, Failure> {
        Empty()
    }

    public func map<T>(_ transform: (Result<Success, Failure>.Publisher.Output) -> T) -> Result<T, Failure>.Publisher {
        Result<T, Failure>.Publisher(result.map(transform))
    }

    public func tryMap<T>(_ transform: (Result<Success, Failure>.Publisher.Output) throws -> T) -> Result<T, any Error>.Publisher {
        trying(transform)
    }

    public func mapError<E>(_ transform: (Failure) -> E) -> Result<Result<Success, Failure>.Publisher.Output, E>.Publisher
    where E: Error {
        Result<Success, E>.Publisher(result.mapError(transform))
    }

    public func reduce<T>(_ initialResult: T, _ nextPartialResult: (T, Result<Success, Failure>.Publisher.Output) -> T)
        -> Result<T, Failure>.Publisher {
        Result<T, Failure>.Publisher(result.map { nextPartialResult(initialResult, $0) })
    }

    public func tryReduce<T>(_ initialResult: T, _ nextPartialResult: (T, Result<Success, Failure>.Publisher.Output) throws -> T)
        -> Result<T, any Error>.Publisher {
        trying { try nextPartialResult(initialResult, $0) }
    }

    public func removeDuplicates(by predicate: (Result<Success, Failure>.Publisher.Output,
                                                Result<Success, Failure>.Publisher.Output) -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func tryRemoveDuplicates(by predicate: (Result<Success, Failure>.Publisher.Output,
                                                   Result<Success, Failure>.Publisher.Output) throws -> Bool)
        -> Result<Result<Success, Failure>.Publisher.Output, any Error>.Publisher {
        trying { $0 }
    }

    public func replaceError(with output: Result<Success, Failure>.Publisher.Output)
        -> Result<Result<Success, Failure>.Publisher.Output, Never>.Publisher {
        switch result {
        case .success(let value): return Result<Success, Never>.Publisher(.success(value))
        case .failure: return Result<Success, Never>.Publisher(.success(output))
        }
    }

    public func replaceEmpty(with output: Result<Success, Failure>.Publisher.Output)
        -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func retry(_ times: Int) -> Result<Result<Success, Failure>.Publisher.Output, Failure>.Publisher { self }

    public func scan<T>(_ initialResult: T, _ nextPartialResult: (T, Result<Success, Failure>.Publisher.Output) -> T)
        -> Result<T, Failure>.Publisher {
        Result<T, Failure>.Publisher(result.map { nextPartialResult(initialResult, $0) })
    }

    public func tryScan<T>(_ initialResult: T, _ nextPartialResult: (T, Result<Success, Failure>.Publisher.Output) throws -> T)
        -> Result<T, any Error>.Publisher {
        trying { try nextPartialResult(initialResult, $0) }
    }
}

extension Result.Publisher where Failure == Never {
    public func setFailureType<E>(to failureType: E.Type) -> Result<Result<Success, Failure>.Publisher.Output, E>.Publisher
    where E: Error {
        switch result {
        case .success(let value): return Result<Success, E>.Publisher(.success(value))
        }
    }
}

// MARK: - Publishers.Sequence

extension Publishers.Sequence where Failure == Never {
    public func min(by areInIncreasingOrder: (Publishers.Sequence<Elements, Failure>.Output,
                                              Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.min(by: areInIncreasingOrder))
    }

    public func max(by areInIncreasingOrder: (Publishers.Sequence<Elements, Failure>.Output,
                                              Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.max(by: areInIncreasingOrder))
    }

    public func first(where predicate: (Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.first(where: predicate))
    }
}

extension Publishers.Sequence {
    public func allSatisfy(_ predicate: (Publishers.Sequence<Elements, Failure>.Output) -> Bool) -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(.success(sequence.allSatisfy(predicate)))
    }

    public func tryAllSatisfy(_ predicate: (Publishers.Sequence<Elements, Failure>.Output) throws -> Bool)
        -> Result<Bool, any Error>.Publisher {
        Result<Bool, any Error>.Publisher(Result<Bool, any Error> { try sequence.allSatisfy(predicate) })
    }

    public func collect() -> Result<[Publishers.Sequence<Elements, Failure>.Output], Failure>.Publisher {
        Result<[Output], Failure>.Publisher(.success(Array(sequence)))
    }

    public func compactMap<T>(_ transform: (Publishers.Sequence<Elements, Failure>.Output) -> T?)
        -> Publishers.Sequence<[T], Failure> {
        Publishers.Sequence<[T], Failure>(sequence: sequence.compactMap(transform))
    }

    public func contains(where predicate: (Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(.success(sequence.contains(where: predicate)))
    }

    public func tryContains(where predicate: (Publishers.Sequence<Elements, Failure>.Output) throws -> Bool)
        -> Result<Bool, any Error>.Publisher {
        Result<Bool, any Error>.Publisher(Result<Bool, any Error> { try sequence.contains(where: predicate) })
    }

    public func drop(while predicate: (Elements.Element) -> Bool) -> Publishers.Sequence<DropWhileSequence<Elements>, Failure> {
        Publishers.Sequence<DropWhileSequence<Elements>, Failure>(sequence: sequence.drop(while: predicate))
    }

    public func dropFirst(_ count: Int = 1) -> Publishers.Sequence<DropFirstSequence<Elements>, Failure> {
        Publishers.Sequence<DropFirstSequence<Elements>, Failure>(sequence: sequence.dropFirst(count))
    }

    public func filter(_ isIncluded: (Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Publishers.Sequence<[Publishers.Sequence<Elements, Failure>.Output], Failure> {
        Publishers.Sequence<[Output], Failure>(sequence: sequence.filter(isIncluded))
    }

    public func ignoreOutput() -> Empty<Publishers.Sequence<Elements, Failure>.Output, Failure> {
        Empty()
    }

    public func map<T>(_ transform: (Elements.Element) -> T) -> Publishers.Sequence<[T], Failure> {
        Publishers.Sequence<[T], Failure>(sequence: sequence.map(transform))
    }

    public func prefix(_ maxLength: Int) -> Publishers.Sequence<PrefixSequence<Elements>, Failure> {
        Publishers.Sequence<PrefixSequence<Elements>, Failure>(sequence: sequence.prefix(maxLength))
    }

    public func prefix(while predicate: (Elements.Element) -> Bool) -> Publishers.Sequence<[Elements.Element], Failure> {
        Publishers.Sequence<[Elements.Element], Failure>(sequence: sequence.prefix(while: predicate))
    }

    public func reduce<T>(_ initialResult: T,
                          _ nextPartialResult: @escaping (T, Publishers.Sequence<Elements, Failure>.Output) -> T)
        -> Result<T, Failure>.Publisher {
        Result<T, Failure>.Publisher(.success(sequence.reduce(initialResult, nextPartialResult)))
    }

    public func tryReduce<T>(_ initialResult: T,
                             _ nextPartialResult: @escaping (T, Publishers.Sequence<Elements, Failure>.Output) throws -> T)
        -> Result<T, any Error>.Publisher {
        Result<T, any Error>.Publisher(Result<T, any Error> { try sequence.reduce(initialResult, nextPartialResult) })
    }

    public func replaceNil<T>(with output: T) -> Publishers.Sequence<[Publishers.Sequence<Elements, Failure>.Output], Failure>
    where Elements.Element == T? {
        Publishers.Sequence<[Output], Failure>(sequence: sequence.map { $0 ?? output })
    }

    public func scan<T>(_ initialResult: T,
                        _ nextPartialResult: @escaping (T, Publishers.Sequence<Elements, Failure>.Output) -> T)
        -> Publishers.Sequence<[T], Failure> {
        var accumulated = initialResult
        return Publishers.Sequence<[T], Failure>(sequence: sequence.map { value in
            accumulated = nextPartialResult(accumulated, value)
            return accumulated
        })
    }

    public func setFailureType<E>(to error: E.Type) -> Publishers.Sequence<Elements, E> where E: Error {
        Publishers.Sequence<Elements, E>(sequence: sequence)
    }
}

extension Publishers.Sequence where Elements.Element: Equatable {
    public func removeDuplicates() -> Publishers.Sequence<[Publishers.Sequence<Elements, Failure>.Output], Failure> {
        var kept: [Output] = []
        for value in sequence where kept.last != value {
            kept.append(value)
        }
        return Publishers.Sequence<[Output], Failure>(sequence: kept)
    }

    public func contains(_ output: Elements.Element) -> Result<Bool, Failure>.Publisher {
        Result<Bool, Failure>.Publisher(.success(sequence.contains(output)))
    }
}

extension Publishers.Sequence where Failure == Never, Elements.Element: Comparable {
    public func min() -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.min())
    }

    public func max() -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.max())
    }
}

extension Publishers.Sequence where Elements: Collection, Failure == Never {
    public func first() -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.first)
    }

    public func output(at index: Elements.Index) -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.indices.contains(index) ? sequence[index] : nil)
    }
}

extension Publishers.Sequence where Elements: Collection {
    public func count() -> Result<Int, Failure>.Publisher {
        Result<Int, Failure>.Publisher(.success(sequence.count))
    }

    public func output(in range: Range<Elements.Index>) -> Publishers.Sequence<[Publishers.Sequence<Elements, Failure>.Output], Failure> {
        Publishers.Sequence<[Output], Failure>(
            sequence: Array(sequence[range.clamped(to: sequence.startIndex ..< sequence.endIndex)]))
    }
}

extension Publishers.Sequence where Elements: BidirectionalCollection, Failure == Never {
    public func last() -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.last)
    }

    public func last(where predicate: (Publishers.Sequence<Elements, Failure>.Output) -> Bool)
        -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.last(where: predicate))
    }
}

extension Publishers.Sequence where Elements: RandomAccessCollection, Failure == Never {
    public func output(at index: Elements.Index) -> Optional<Publishers.Sequence<Elements, Failure>.Output>.Publisher {
        Optional.Publisher(sequence.indices.contains(index) ? sequence[index] : nil)
    }

    public func count() -> Just<Int> {
        Just(sequence.count)
    }
}

extension Publishers.Sequence where Elements: RandomAccessCollection {
    public func output(in range: Range<Elements.Index>) -> Publishers.Sequence<[Publishers.Sequence<Elements, Failure>.Output], Failure> {
        Publishers.Sequence<[Output], Failure>(
            sequence: Array(sequence[range.clamped(to: sequence.startIndex ..< sequence.endIndex)]))
    }

    public func count() -> Result<Int, Failure>.Publisher {
        Result<Int, Failure>.Publisher(.success(sequence.count))
    }
}

extension Publishers.Sequence where Elements: RangeReplaceableCollection {
    public func prepend(_ elements: Publishers.Sequence<Elements, Failure>.Output...) -> Publishers.Sequence<Elements, Failure> {
        prepend(elements)
    }

    public func prepend<S>(_ elements: S) -> Publishers.Sequence<Elements, Failure>
    where S: Swift.Sequence, Elements.Element == S.Element {
        var joined = Elements(elements)
        joined.append(contentsOf: sequence)
        return Publishers.Sequence(sequence: joined)
    }

    public func prepend(_ publisher: Publishers.Sequence<Elements, Failure>) -> Publishers.Sequence<Elements, Failure> {
        prepend(publisher.sequence)
    }

    public func append(_ elements: Publishers.Sequence<Elements, Failure>.Output...) -> Publishers.Sequence<Elements, Failure> {
        append(elements)
    }

    public func append<S>(_ elements: S) -> Publishers.Sequence<Elements, Failure>
    where S: Swift.Sequence, Elements.Element == S.Element {
        var joined = sequence
        joined.append(contentsOf: elements)
        return Publishers.Sequence(sequence: joined)
    }

    public func append(_ publisher: Publishers.Sequence<Elements, Failure>) -> Publishers.Sequence<Elements, Failure> {
        append(publisher.sequence)
    }
}
