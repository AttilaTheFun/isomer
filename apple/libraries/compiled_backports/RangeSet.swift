// The standard library's `RangeSet` (Swift 6.0: iOS 18, macOS 15) for a
// feature compiled against Isomer's frameworks on an older OS, where SwiftUI's
// `TextSelection` carries one. A set of non-overlapping, non-adjacent ranges,
// kept sorted: enough of the standard library's interface to make one and
// read it. Code that names `RangeSet` itself still gets the standard
// library's (this module is not imported by a feature's sources).

public struct RangeSet<Bound: Comparable> {
    /// The ranges, sorted, none empty, none touching another.
    public private(set) var ranges: [Range<Bound>]

    public init() {
        ranges = []
    }

    public init(_ range: Range<Bound>) {
        ranges = range.isEmpty ? [] : [range]
    }

    public init<S: Sequence>(_ ranges: S) where S.Element == Range<Bound> {
        self.ranges = []
        for range in ranges { insert(contentsOf: range) }
    }

    public var isEmpty: Bool { ranges.isEmpty }

    public func contains(_ value: Bound) -> Bool {
        ranges.contains { $0.contains(value) }
    }

    /// Adds `range`, merged with the ranges it overlaps or touches.
    public mutating func insert(contentsOf range: Range<Bound>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound
        var upper = range.upperBound
        var kept: [Range<Bound>] = []
        for existing in ranges {
            if existing.upperBound < lower || existing.lowerBound > upper {
                kept.append(existing)
            } else {
                lower = Swift.min(lower, existing.lowerBound)
                upper = Swift.max(upper, existing.upperBound)
            }
        }
        kept.append(lower ..< upper)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Takes `range` out, splitting the ranges it falls inside.
    public mutating func remove(contentsOf range: Range<Bound>) {
        guard !range.isEmpty else { return }
        var kept: [Range<Bound>] = []
        for existing in ranges {
            if existing.upperBound <= range.lowerBound || existing.lowerBound >= range.upperBound {
                kept.append(existing)
                continue
            }
            if existing.lowerBound < range.lowerBound { kept.append(existing.lowerBound ..< range.lowerBound) }
            if existing.upperBound > range.upperBound { kept.append(range.upperBound ..< existing.upperBound) }
        }
        ranges = kept
    }
}

extension RangeSet: Equatable {}
extension RangeSet: Hashable where Bound: Hashable {}
extension RangeSet: Sendable where Bound: Sendable {}

extension RangeSet: CustomStringConvertible {
    public var description: String {
        "RangeSet(" + ranges.map { "\($0)" }.joined(separator: ", ") + ")"
    }
}
