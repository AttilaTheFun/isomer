// IndexSet, as Isomer's Foundation has it: a set of non-negative integers
// kept as sorted, non-overlapping ranges, with Apple's Swift API (a
// bidirectional collection of `Int`, set algebra, ranges, shifting).
// swift-foundation leaves IndexSet to swift-corelibs-foundation, where it
// wraps NSIndexSet; this one is Swift.

import FoundationEssentials

public struct IndexSet: Hashable, Sendable {
    public typealias Element = Int

    /// Sorted, non-overlapping, non-adjacent half-open ranges.
    var storage: [Range<Int>]

    public init() {
        storage = []
    }

    public init(integer: Int) {
        storage = [integer..<(integer + 1)]
    }

    public init(integersIn range: Range<Int>) {
        storage = range.isEmpty ? [] : [range]
    }

    public init<R: RangeExpression>(integersIn range: R) where R.Bound == Int {
        self.init(integersIn: range.relative(to: 0..<Int.max))
    }

    // MARK: Ranges

    /// The set's ranges, in order.
    public struct RangeView: BidirectionalCollection, Equatable, Sendable {
        public typealias Index = Int
        public typealias Element = Range<Int>
        let ranges: [Range<Int>]
        public var startIndex: Int { ranges.startIndex }
        public var endIndex: Int { ranges.endIndex }
        public subscript(position: Int) -> Range<Int> { ranges[position] }
        public func index(after i: Int) -> Int { i + 1 }
        public func index(before i: Int) -> Int { i - 1 }
    }

    public var rangeView: RangeView { RangeView(ranges: storage) }

    /// The set's ranges that overlap `range`, clipped to it.
    public func rangeView(of range: Range<Int>) -> RangeView {
        RangeView(ranges: storage.compactMap { r in
            let clipped = r.clamped(to: range)
            return clipped.isEmpty ? nil : clipped
        })
    }

    public func rangeView<R: RangeExpression>(of range: R) -> RangeView where R.Bound == Int {
        rangeView(of: range.relative(to: 0..<Int.max))
    }

    // MARK: Membership

    public func contains(_ integer: Int) -> Bool {
        position(of: integer) != nil
    }

    public func contains(integersIn range: Range<Int>) -> Bool {
        if range.isEmpty { return true }
        return storage.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    public func contains<R: RangeExpression>(integersIn range: R) -> Bool where R.Bound == Int {
        contains(integersIn: range.relative(to: 0..<Int.max))
    }

    public func contains(integersIn indexSet: IndexSet) -> Bool {
        indexSet.storage.allSatisfy { contains(integersIn: $0) }
    }

    public func intersects(integersIn range: Range<Int>) -> Bool {
        storage.contains { $0.overlaps(range) }
    }

    public func intersects<R: RangeExpression>(integersIn range: R) -> Bool where R.Bound == Int {
        intersects(integersIn: range.relative(to: 0..<Int.max))
    }

    public var count: Int { storage.reduce(0) { $0 + $1.count } }

    public func count(in range: Range<Int>) -> Int {
        storage.reduce(0) { $0 + $1.clamped(to: range).count }
    }

    public func count<R: RangeExpression>(in range: R) -> Int where R.Bound == Int {
        count(in: range.relative(to: 0..<Int.max))
    }

    public var first: Int? { storage.first?.lowerBound }
    public var last: Int? { storage.last.map { $0.upperBound - 1 } }

    public func integerGreaterThan(_ integer: Int) -> Int? {
        for range in storage where range.upperBound > integer + 1 {
            return Swift.max(range.lowerBound, integer + 1)
        }
        return nil
    }

    public func integerGreaterThanOrEqualTo(_ integer: Int) -> Int? {
        integerGreaterThan(integer - 1)
    }

    public func integerLessThan(_ integer: Int) -> Int? {
        for range in storage.reversed() where range.lowerBound < integer {
            return Swift.min(range.upperBound, integer) - 1
        }
        return nil
    }

    public func integerLessThanOrEqualTo(_ integer: Int) -> Int? {
        integerLessThan(integer + 1)
    }

    // MARK: Changing

    @discardableResult
    public mutating func insert(_ integer: Int) -> (inserted: Bool, memberAfterInsert: Int) {
        if contains(integer) { return (false, integer) }
        insert(integersIn: integer..<(integer + 1))
        return (true, integer)
    }

    @discardableResult
    public mutating func update(with integer: Int) -> Int? {
        let present = contains(integer)
        insert(integer)
        return present ? integer : nil
    }

    public mutating func insert(integersIn range: Range<Int>) {
        guard !range.isEmpty else { return }
        storage = IndexSet.normalized(storage + [range])
    }

    public mutating func insert<R: RangeExpression>(integersIn range: R) where R.Bound == Int {
        insert(integersIn: range.relative(to: 0..<Int.max))
    }

    @discardableResult
    public mutating func remove(_ integer: Int) -> Int? {
        guard contains(integer) else { return nil }
        remove(integersIn: integer..<(integer + 1))
        return integer
    }

    public mutating func remove(integersIn range: Range<Int>) {
        guard !range.isEmpty else { return }
        var result: [Range<Int>] = []
        for r in storage {
            if !r.overlaps(range) {
                result.append(r)
                continue
            }
            if r.lowerBound < range.lowerBound { result.append(r.lowerBound..<range.lowerBound) }
            if r.upperBound > range.upperBound { result.append(range.upperBound..<r.upperBound) }
        }
        storage = result
    }

    // Apple's two (not a RangeExpression, as insert(integersIn:) has).
    public mutating func remove(integersIn range: ClosedRange<Int>) {
        remove(integersIn: Range(range))
    }

    public mutating func removeAll() {
        storage = []
    }

    /// Moves every integer at or above `integer` by `delta`. A negative
    /// `delta` first removes the integers in `integer + delta ..< integer`.
    public mutating func shift(startingAt integer: Int, by delta: Int) {
        guard delta != 0 else { return }
        if delta < 0 { remove(integersIn: Swift.max(0, integer + delta)..<integer) }
        var result: [Range<Int>] = []
        for r in storage {
            if r.upperBound <= integer {
                result.append(r)
            } else if r.lowerBound >= integer {
                result.append((r.lowerBound + delta)..<(r.upperBound + delta))
            } else {
                result.append(r.lowerBound..<integer)
                result.append((integer + delta)..<(r.upperBound + delta))
            }
        }
        storage = IndexSet.normalized(result)
    }

    public func filteredIndexSet(in range: Range<Int>, includeInteger: (Int) throws -> Bool) rethrows -> IndexSet {
        var result = IndexSet()
        for integer in self where range.contains(integer) {
            if try includeInteger(integer) { result.insert(integer) }
        }
        return result
    }

    public func filteredIndexSet(includeInteger: (Int) throws -> Bool) rethrows -> IndexSet {
        var result = IndexSet()
        for integer in self where try includeInteger(integer) {
            result.insert(integer)
        }
        return result
    }

    // MARK: Helpers

    func position(of integer: Int) -> Int? {
        var low = 0
        var high = storage.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = storage[middle]
            if integer < range.lowerBound {
                high = middle - 1
            } else if integer >= range.upperBound {
                low = middle + 1
            } else {
                return middle
            }
        }
        return nil
    }

    static func normalized(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.filter({ !$0.isEmpty }).sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<Swift.max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

// MARK: - Collection

extension IndexSet: BidirectionalCollection {
    public struct Index: Comparable, Sendable, CustomStringConvertible {
        let value: Int
        let rangeIndex: Int

        public static func < (lhs: Index, rhs: Index) -> Bool {
            lhs.rangeIndex < rhs.rangeIndex || (lhs.rangeIndex == rhs.rangeIndex && lhs.value < rhs.value)
        }

        public var description: String { "index \(value) in a range \(rangeIndex)" }
    }

    public var startIndex: Index {
        Index(value: storage.first?.lowerBound ?? 0, rangeIndex: storage.isEmpty ? 0 : 0)
    }

    public var endIndex: Index {
        Index(value: storage.last?.upperBound ?? 0, rangeIndex: storage.count)
    }

    public subscript(position: Index) -> Int { position.value }

    public func index(after i: Index) -> Index {
        let next = i.value + 1
        if next < storage[i.rangeIndex].upperBound {
            return Index(value: next, rangeIndex: i.rangeIndex)
        }
        let nextRange = i.rangeIndex + 1
        if nextRange < storage.count {
            return Index(value: storage[nextRange].lowerBound, rangeIndex: nextRange)
        }
        return endIndex
    }

    public func index(before i: Index) -> Index {
        if i.rangeIndex < storage.count, i.value > storage[i.rangeIndex].lowerBound {
            return Index(value: i.value - 1, rangeIndex: i.rangeIndex)
        }
        let previous = i.rangeIndex - 1
        return Index(value: storage[previous].upperBound - 1, rangeIndex: previous)
    }

    public var isEmpty: Bool { storage.isEmpty }

    public func index(of integer: Int) -> Index? {
        position(of: integer).map { Index(value: integer, rangeIndex: $0) }
    }
}

// MARK: - Set algebra

extension IndexSet: SetAlgebra {
    public init(arrayLiteral elements: Int...) {
        self.init()
        for element in elements { insert(element) }
    }

    public func union(_ other: IndexSet) -> IndexSet {
        var result = IndexSet()
        result.storage = IndexSet.normalized(storage + other.storage)
        return result
    }

    public mutating func formUnion(_ other: IndexSet) {
        self = union(other)
    }

    public func intersection(_ other: IndexSet) -> IndexSet {
        var result: [Range<Int>] = []
        var i = 0, j = 0
        while i < storage.count && j < other.storage.count {
            let overlap = storage[i].clamped(to: other.storage[j])
            if !overlap.isEmpty { result.append(overlap) }
            if storage[i].upperBound < other.storage[j].upperBound { i += 1 } else { j += 1 }
        }
        var set = IndexSet()
        set.storage = result
        return set
    }

    public mutating func formIntersection(_ other: IndexSet) {
        self = intersection(other)
    }

    public func subtracting(_ other: IndexSet) -> IndexSet {
        var result = self
        for range in other.storage { result.remove(integersIn: range) }
        return result
    }

    public mutating func subtract(_ other: IndexSet) {
        self = subtracting(other)
    }

    public func symmetricDifference(_ other: IndexSet) -> IndexSet {
        subtracting(other).union(other.subtracting(self))
    }

    public mutating func formSymmetricDifference(_ other: IndexSet) {
        self = symmetricDifference(other)
    }
}

extension IndexSet: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "\(count) indexes" }
    public var debugDescription: String { description }
}

extension IndexSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case indexes
    }

    private struct RangeRecord: Codable {
        var location: Int
        var length: Int
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let records = try container.decode([RangeRecord].self, forKey: .indexes)
        self.init()
        storage = IndexSet.normalized(records.map { $0.location..<($0.location + $0.length) })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(storage.map { RangeRecord(location: $0.lowerBound, length: $0.count) }, forKey: .indexes)
    }
}
