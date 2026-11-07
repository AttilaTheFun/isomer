// Just's own operators: with one value known up front, each answers at
// once with another Just, an Optional or Result publisher, Empty, or a
// Sequence publisher (as Apple's overloads do, so the types code gets are
// Apple's).

extension Just where Output: Comparable {
    public func min() -> Just<Output> { self }
    public func max() -> Just<Output> { self }
}

extension Just where Output: Equatable {
    public func contains(_ output: Output) -> Just<Bool> {
        Just<Bool>(self.output == output)
    }

    public func removeDuplicates() -> Just<Output> { self }
}

extension Just {
    public func allSatisfy(_ predicate: (Output) -> Bool) -> Just<Bool> {
        Just<Bool>(predicate(output))
    }

    public func tryAllSatisfy(_ predicate: (Output) throws -> Bool) -> Result<Bool, any Error>.Publisher {
        Result<Bool, any Error>.Publisher(Result { try predicate(output) })
    }

    public func collect() -> Just<[Output]> {
        Just<[Output]>([output])
    }

    public func compactMap<T>(_ transform: (Output) -> T?) -> Optional<T>.Publisher {
        Optional<T>.Publisher(transform(output))
    }

    public func min(by areInIncreasingOrder: (Output, Output) -> Bool) -> Just<Output> { self }
    public func max(by areInIncreasingOrder: (Output, Output) -> Bool) -> Just<Output> { self }

    public func prepend(_ elements: Output...) -> Publishers.Sequence<[Output], Just<Output>.Failure> {
        prepend(elements)
    }

    public func prepend<S>(_ elements: S) -> Publishers.Sequence<[Output], Just<Output>.Failure>
    where Output == S.Element, S: Sequence {
        Publishers.Sequence(sequence: Array(elements) + [output])
    }

    public func append(_ elements: Output...) -> Publishers.Sequence<[Output], Just<Output>.Failure> {
        append(elements)
    }

    public func append<S>(_ elements: S) -> Publishers.Sequence<[Output], Just<Output>.Failure>
    where Output == S.Element, S: Sequence {
        Publishers.Sequence(sequence: [output] + Array(elements))
    }

    public func contains(where predicate: (Output) -> Bool) -> Just<Bool> {
        Just<Bool>(predicate(output))
    }

    public func tryContains(where predicate: (Output) throws -> Bool) -> Result<Bool, any Error>.Publisher {
        Result<Bool, any Error>.Publisher(Result { try predicate(output) })
    }

    public func count() -> Just<Int> {
        Just<Int>(1)
    }

    public func dropFirst(_ count: Int = 1) -> Optional<Output>.Publisher {
        precondition(count >= 0, "dropFirst's count can't be negative")
        return Optional<Output>.Publisher(count > 0 ? nil : output)
    }

    public func drop(while predicate: (Output) -> Bool) -> Optional<Output>.Publisher {
        Optional<Output>.Publisher(predicate(output) ? nil : output)
    }

    public func first() -> Just<Output> { self }

    public func first(where predicate: (Output) -> Bool) -> Optional<Output>.Publisher {
        Optional<Output>.Publisher(predicate(output) ? output : nil)
    }

    public func last() -> Just<Output> { self }

    public func last(where predicate: (Output) -> Bool) -> Optional<Output>.Publisher {
        Optional<Output>.Publisher(predicate(output) ? output : nil)
    }

    public func filter(_ isIncluded: (Output) -> Bool) -> Optional<Output>.Publisher {
        Optional<Output>.Publisher(isIncluded(output) ? output : nil)
    }

    public func ignoreOutput() -> Empty<Output, Just<Output>.Failure> {
        Empty()
    }

    public func map<T>(_ transform: (Output) -> T) -> Just<T> {
        Just<T>(transform(output))
    }

    public func tryMap<T>(_ transform: (Output) throws -> T) -> Result<T, any Error>.Publisher {
        Result<T, any Error>.Publisher(Result { try transform(output) })
    }

    public func mapError<E>(_ transform: (Just<Output>.Failure) -> E) -> Result<Output, E>.Publisher where E: Error {
        Result<Output, E>.Publisher(.success(output))
    }

    public func output(at index: Int) -> Optional<Output>.Publisher {
        precondition(index >= 0, "An index can't be negative")
        return Optional<Output>.Publisher(index == 0 ? output : nil)
    }

    public func output<R>(in range: R) -> Optional<Output>.Publisher where R: RangeExpression, R.Bound == Int {
        Optional<Output>.Publisher(range.contains(0) ? output : nil)
    }

    public func prefix(_ maxLength: Int) -> Optional<Output>.Publisher {
        precondition(maxLength >= 0, "prefix's length can't be negative")
        return Optional<Output>.Publisher(maxLength > 0 ? output : nil)
    }

    public func prefix(while predicate: (Output) -> Bool) -> Optional<Output>.Publisher {
        Optional<Output>.Publisher(predicate(output) ? output : nil)
    }

    public func reduce<T>(_ initialResult: T, _ nextPartialResult: (T, Output) -> T) -> Result<T, Just<Output>.Failure>.Publisher {
        Result<T, Never>.Publisher(.success(nextPartialResult(initialResult, output)))
    }

    public func tryReduce<T>(_ initialResult: T, _ nextPartialResult: (T, Output) throws -> T) -> Result<T, any Error>.Publisher {
        Result<T, any Error>.Publisher(Result { try nextPartialResult(initialResult, output) })
    }

    public func removeDuplicates(by predicate: (Output, Output) -> Bool) -> Just<Output> { self }

    public func tryRemoveDuplicates(by predicate: (Output, Output) throws -> Bool) -> Result<Output, any Error>.Publisher {
        Result<Output, any Error>.Publisher(.success(output))
    }

    public func replaceError(with output: Output) -> Just<Output> { self }
    public func replaceEmpty(with output: Output) -> Just<Output> { self }
    public func retry(_ times: Int) -> Just<Output> { self }

    public func scan<T>(_ initialResult: T, _ nextPartialResult: (T, Output) -> T) -> Result<T, Just<Output>.Failure>.Publisher {
        Result<T, Never>.Publisher(.success(nextPartialResult(initialResult, output)))
    }

    public func tryScan<T>(_ initialResult: T, _ nextPartialResult: (T, Output) throws -> T) -> Result<T, any Error>.Publisher {
        Result<T, any Error>.Publisher(Result { try nextPartialResult(initialResult, output) })
    }

    public func setFailureType<E>(to failureType: E.Type) -> Result<Output, E>.Publisher where E: Error {
        Result<Output, E>.Publisher(.success(output))
    }
}
