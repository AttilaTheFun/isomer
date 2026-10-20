// NSRange: a location and a length, in UTF-16 code units when it is a
// string's (as Apple's Foundation and corelibs have it; swift-foundation
// has none), with the conversions to and from a string's indices.

import FoundationEssentials

public struct _NSRange: Hashable, Sendable {
    public var location: Int
    public var length: Int

    public init() {
        location = 0
        length = 0
    }

    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

public typealias NSRange = _NSRange
public typealias NSRangePointer = UnsafeMutablePointer<NSRange>

/// A location that is no location.
public let NSNotFound: Int = .max

public func NSMakeRange(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
}

public func NSMaxRange(_ range: NSRange) -> Int {
    range.location + range.length
}

public func NSLocationInRange(_ location: Int, _ range: NSRange) -> Bool {
    location >= range.location && location - range.location < range.length
}

public func NSEqualRanges(_ a: NSRange, _ b: NSRange) -> Bool {
    a == b
}

public func NSUnionRange(_ a: NSRange, _ b: NSRange) -> NSRange {
    let start = min(a.location, b.location)
    return NSRange(location: start, length: max(NSMaxRange(a), NSMaxRange(b)) - start)
}

public func NSIntersectionRange(_ a: NSRange, _ b: NSRange) -> NSRange {
    let start = max(a.location, b.location)
    let end = min(NSMaxRange(a), NSMaxRange(b))
    return end > start ? NSRange(location: start, length: end - start) : NSRange(location: 0, length: 0)
}

public func NSStringFromRange(_ range: NSRange) -> String {
    "{\(range.location), \(range.length)}"
}

public func NSRangeFromString(_ string: String) -> NSRange {
    let numbers = string.split(whereSeparator: { !$0.isNumber && $0 != "-" }).compactMap { Int($0) }
    return NSRange(location: numbers.first ?? 0, length: numbers.count > 1 ? numbers[1] : 0)
}

extension NSRange: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "{\(location), \(length)}" }
    public var debugDescription: String {
        location == NSNotFound ? "{NSNotFound, \(length)}" : description
    }
}

extension NSRange {
    public var lowerBound: Int { location }
    public var upperBound: Int { location + length }

    public init(_ x: Range<Int>) {
        self.init(location: x.lowerBound, length: x.count)
    }

    public init<R: RangeExpression>(_ region: R) where R.Bound: FixedWidthInteger {
        let range = region.relative(to: 0..<R.Bound.max)
        self.init(location: Int(range.lowerBound), length: Int(range.upperBound - range.lowerBound))
    }

    /// The UTF-16 range of a range of a string's indices.
    public init<R: RangeExpression, S: StringProtocol>(_ region: R, in target: S) where R.Bound == String.Index {
        let range = region.relative(to: target)
        let start = target.utf16.distance(from: target.startIndex, to: range.lowerBound)
        let length = target.utf16.distance(from: range.lowerBound, to: range.upperBound)
        self.init(location: start, length: length)
    }

    public func contains(_ index: Int) -> Bool {
        NSLocationInRange(index, self)
    }

    public func union(_ other: NSRange) -> NSRange {
        NSUnionRange(self, other)
    }

    public func intersection(_ other: NSRange) -> NSRange? {
        let start = max(location, other.location)
        let end = min(upperBound, other.upperBound)
        return end >= start ? NSRange(location: start, length: end - start) : nil
    }
}

extension Range where Bound == String.Index {
    /// The string's indices for a UTF-16 range; nil when it is out of the
    /// string or splits a character's code units.
    public init?<S: StringProtocol>(_ range: NSRange, in string: S) {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        let utf16 = string.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: range.length, limitedBy: utf16.endIndex),
              let lower = String.Index(start, within: string), let upper = String.Index(end, within: string) else {
            return nil
        }
        self = lower..<upper
    }
}

extension Range where Bound: BinaryInteger {
    public init?(_ range: NSRange) {
        guard range.location != NSNotFound else { return nil }
        self = Bound(range.location)..<Bound(range.location + range.length)
    }
}
