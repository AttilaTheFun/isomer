// Edges, insets and alignments. CoreGraphics' geometry (CGFloat, CGPoint,
// CGSize, CGRect…) and Foundation's types come from those modules: Apple's on
// Apple platforms, Isomer's (//core_graphics, //foundation) on wasm and
// Android. Linux and Windows still build on the toolchain's Foundation
// (swift-corelibs-foundation), which declares CGFloat, CGPoint, CGSize and
// CGRect itself; Isomer's CoreGraphics there is the rest. As Apple's SwiftUI
// does, this module re-exports both, so `import SwiftUI` alone reaches
// `CGFloat`, `Date` and `URL`.

@_exported import CoreGraphics
@_exported import Foundation

extension CGRect {
    /// The overlap of two rectangles, or `.zero` when they do not meet
    /// (CoreGraphics' `intersection` gives `.null` then, whose origin is at
    /// infinity): what clip rectangles and scissors want.
    func clipped(to other: CGRect) -> CGRect {
        let overlap = intersection(other)
        return overlap.isNull ? .zero : overlap
    }
}

public enum Edge: Int8, CaseIterable, Sendable {
    case top, leading, bottom, trailing

    public struct Set: OptionSet, Sendable {
        public let rawValue: Int8
        public init(rawValue: Int8) { self.rawValue = rawValue }

        public static let top = Set(rawValue: 1 << 0)
        public static let leading = Set(rawValue: 1 << 1)
        public static let bottom = Set(rawValue: 1 << 2)
        public static let trailing = Set(rawValue: 1 << 3)
        public static let horizontal: Set = [.leading, .trailing]
        public static let vertical: Set = [.top, .bottom]
        public static let all: Set = [.top, .leading, .bottom, .trailing]
    }
}

public struct EdgeInsets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
        self.top = top
        self.leading = leading
        self.bottom = bottom
        self.trailing = trailing
    }

    var horizontal: CGFloat { leading + trailing }
    var vertical: CGFloat { top + bottom }
}

public struct HorizontalAlignment: Equatable, Sendable {
    enum Kind: Sendable { case leading, center, trailing }
    let kind: Kind

    public static let leading = HorizontalAlignment(kind: .leading)
    public static let center = HorizontalAlignment(kind: .center)
    public static let trailing = HorizontalAlignment(kind: .trailing)
}

public struct VerticalAlignment: Equatable, Sendable {
    enum Kind: Sendable { case top, center, bottom }
    let kind: Kind

    public static let top = VerticalAlignment(kind: .top)
    public static let center = VerticalAlignment(kind: .center)
    public static let bottom = VerticalAlignment(kind: .bottom)
    /// Approximated as `center`; real baseline alignment needs font metrics.
    public static let firstTextBaseline = VerticalAlignment(kind: .center)
}

public struct Alignment: Equatable, Sendable {
    public var horizontal: HorizontalAlignment
    public var vertical: VerticalAlignment

    public init(horizontal: HorizontalAlignment, vertical: VerticalAlignment) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let center = Alignment(horizontal: .center, vertical: .center)
    public static let leading = Alignment(horizontal: .leading, vertical: .center)
    public static let trailing = Alignment(horizontal: .trailing, vertical: .center)
    public static let top = Alignment(horizontal: .center, vertical: .top)
    public static let bottom = Alignment(horizontal: .center, vertical: .bottom)
    public static let topLeading = Alignment(horizontal: .leading, vertical: .top)
    public static let topTrailing = Alignment(horizontal: .trailing, vertical: .top)
    public static let bottomLeading = Alignment(horizontal: .leading, vertical: .bottom)
    public static let bottomTrailing = Alignment(horizontal: .trailing, vertical: .bottom)
}

enum StackAxis {
    case horizontal, vertical, depth
}

/// A size proposal where either dimension may be unspecified.
struct ProposedSize {
    var width: CGFloat?
    var height: CGFloat?

    init(width: CGFloat? = nil, height: CGFloat? = nil) {
        self.width = width
        self.height = height
    }

    init(_ size: CGSize) {
        self.init(width: size.width, height: size.height)
    }
}
