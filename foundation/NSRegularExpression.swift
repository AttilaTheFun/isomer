// NSRegularExpression and its results (Apple's Foundation and corelibs
// have them, over ICU's regular expressions; swift-foundation does not),
// over Swift's own `Regex`: patterns in the syntax both read, matched by
// Unicode scalar, ranges in UTF-16 code units as Apple's are. Swift classes
// (Apple's are NSObject subclasses); the result types besides regular
// expressions' (spelling, dates, links…) are the data detectors', which are
// not here.

import FoundationEssentials

/// Objective-C's BOOL, as the enumeration callbacks take it.
public struct ObjCBool: ExpressibleByBooleanLiteral, Hashable, Sendable {
    public var boolValue: Bool

    public init(_ value: Bool) {
        boolValue = value
    }

    public init(booleanLiteral value: Bool) {
        boolValue = value
    }
}

public final class NSRegularExpression: @unchecked Sendable {
    public struct Options: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let caseInsensitive = Options(rawValue: 1 << 0)
        public static let allowCommentsAndWhitespace = Options(rawValue: 1 << 1)
        public static let ignoreMetacharacters = Options(rawValue: 1 << 2)
        public static let dotMatchesLineSeparators = Options(rawValue: 1 << 3)
        public static let anchorsMatchLines = Options(rawValue: 1 << 4)
        public static let useUnixLineSeparators = Options(rawValue: 1 << 5)
        public static let useUnicodeWordBoundaries = Options(rawValue: 1 << 6)
    }

    public struct MatchingOptions: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let reportProgress = MatchingOptions(rawValue: 1 << 0)
        public static let reportCompletion = MatchingOptions(rawValue: 1 << 1)
        public static let anchored = MatchingOptions(rawValue: 1 << 2)
        public static let withTransparentBounds = MatchingOptions(rawValue: 1 << 3)
        public static let withoutAnchoringBounds = MatchingOptions(rawValue: 1 << 4)
    }

    public struct MatchingFlags: OptionSet, Sendable {
        public let rawValue: UInt
        public init(rawValue: UInt) { self.rawValue = rawValue }
        public static let progress = MatchingFlags(rawValue: 1 << 0)
        public static let completed = MatchingFlags(rawValue: 1 << 1)
        public static let hitEnd = MatchingFlags(rawValue: 1 << 2)
        public static let requiredEnd = MatchingFlags(rawValue: 1 << 3)
        public static let internalError = MatchingFlags(rawValue: 1 << 4)
    }

    public let pattern: String
    public let options: Options
    public let numberOfCaptureGroups: Int
    private let regex: Regex<AnyRegexOutput>

    /// Throws when the pattern is not a regular expression Swift reads.
    public init(pattern: String, options: Options = []) throws {
        self.pattern = pattern
        self.options = options
        var source = options.contains(.ignoreMetacharacters) ? Self.escapedPattern(for: pattern) : pattern
        if options.contains(.allowCommentsAndWhitespace) {
            source = "(?x)" + source
        }
        var regex = try Regex(source)
        if options.contains(.caseInsensitive) { regex = regex.ignoresCase() }
        if options.contains(.dotMatchesLineSeparators) { regex = regex.dotMatchesNewlines() }
        if options.contains(.anchorsMatchLines) { regex = regex.anchorsMatchLineEndings() }
        if !options.contains(.useUnicodeWordBoundaries) { regex = regex.wordBoundaryKind(.simple) }
        self.regex = regex.matchingSemantics(.unicodeScalar)
        numberOfCaptureGroups = Self.captureGroups(in: options.contains(.ignoreMetacharacters) ? "" : pattern)
    }

    /// Opening parentheses that capture: not escaped, not in a character
    /// class, not `(?:`, `(?=`, `(?!`, `(?<=`, `(?<!`, `(?i)` and the like.
    private static func captureGroups(in pattern: String) -> Int {
        let characters = Array(pattern)
        var count = 0
        var index = 0
        var inClass = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\" {
                index += 2
                continue
            }
            if inClass {
                if character == "]" { inClass = false }
            } else if character == "[" {
                inClass = true
            } else if character == "(" {
                if index + 1 < characters.count, characters[index + 1] == "?" {
                    // Named groups capture: (?<name>…), (?P<name>…), (?'name'…).
                    let rest = characters[(index + 2)...].prefix(2)
                    if let first = rest.first, (first == "<" && rest.dropFirst().first.map { $0 != "=" && $0 != "!" } ?? false)
                        || first == "'" || first == "P" {
                        count += 1
                    }
                } else {
                    count += 1
                }
            }
            index += 1
        }
        return count
    }

    public class func escapedPattern(for string: String) -> String {
        var result = ""
        for character in string {
            if "\\^$.|?*+()[]{}".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    public class func escapedTemplate(for string: String) -> String {
        var result = ""
        for character in string {
            if character == "\\" || character == "$" { result.append("\\") }
            result.append(character)
        }
        return result
    }

    // MARK: Matching

    private func results(in string: String, options: MatchingOptions, range: NSRange, first: Bool) -> [NSTextCheckingResult] {
        guard let bounds = Range(range, in: string) else { return [] }
        let text = string[bounds]
        if options.contains(.anchored) {
            guard let match = try? regex.prefixMatch(in: text) else { return [] }
            return [result(for: match, in: string)]
        }
        if first {
            guard let match = try? regex.firstMatch(in: text) else { return [] }
            return [result(for: match, in: string)]
        }
        return text.matches(of: regex).map { result(for: $0, in: string) }
    }

    private func result(for match: Regex<AnyRegexOutput>.Match, in string: String) -> NSTextCheckingResult {
        var ranges: [NSRange] = []
        var names: [String: Int] = [:]
        for (index, element) in match.output.enumerated() {
            if let range = element.range {
                ranges.append(NSRange(range, in: string))
            } else {
                ranges.append(NSRange(location: NSNotFound, length: 0))
            }
            if let name = element.name { names[name] = index }
        }
        return NSTextCheckingResult(ranges: ranges, names: names, regularExpression: self)
    }

    public func matches(in string: String, options: MatchingOptions = [], range: NSRange) -> [NSTextCheckingResult] {
        results(in: string, options: options, range: range, first: false)
    }

    public func firstMatch(in string: String, options: MatchingOptions = [], range: NSRange) -> NSTextCheckingResult? {
        results(in: string, options: options, range: range, first: true).first
    }

    public func numberOfMatches(in string: String, options: MatchingOptions = [], range: NSRange) -> Int {
        matches(in: string, options: options, range: range).count
    }

    public func rangeOfFirstMatch(in string: String, options: MatchingOptions = [], range: NSRange) -> NSRange {
        firstMatch(in: string, options: options, range: range)?.range ?? NSRange(location: NSNotFound, length: 0)
    }

    public func enumerateMatches(
        in string: String, options: MatchingOptions = [], range: NSRange,
        using block: (NSTextCheckingResult?, MatchingFlags, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {
        var stop = ObjCBool(false)
        for result in matches(in: string, options: options, range: range) {
            block(result, [], &stop)
            if stop.boolValue { return }
        }
        if options.contains(.reportCompletion) {
            block(nil, .completed, &stop)
        }
    }

    // MARK: Replacing

    /// `$0`…`$9` (and `${name}`) are a match's groups; `\` escapes.
    public func replacementString(for result: NSTextCheckingResult, in string: String, offset: Int, template templ: String) -> String {
        var output = ""
        let characters = Array(templ)
        var index = 0
        func group(_ range: NSRange) -> String {
            let shifted = NSRange(location: range.location + offset, length: range.length)
            guard range.location != NSNotFound, let bounds = Range(shifted, in: string) else { return "" }
            return String(string[bounds])
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                output.append(characters[index + 1])
                index += 2
                continue
            }
            if character == "$", index + 1 < characters.count {
                if characters[index + 1] == "{", let close = characters[(index + 2)...].firstIndex(of: "}") {
                    let name = String(characters[(index + 2)..<close])
                    output += group(result.range(withName: name))
                    index = close + 1
                    continue
                }
                if let digit = characters[index + 1].wholeNumberValue {
                    var number = digit
                    var next = index + 2
                    // More digits while they still name a group.
                    while next < characters.count, let more = characters[next].wholeNumberValue,
                          number * 10 + more < result.numberOfRanges {
                        number = number * 10 + more
                        next += 1
                    }
                    if number < result.numberOfRanges { output += group(result.range(at: number)) }
                    index = next
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    public func stringByReplacingMatches(in string: String, options: MatchingOptions = [], range: NSRange, withTemplate templ: String) -> String {
        let found = matches(in: string, options: options, range: range)
        guard !found.isEmpty else { return string }
        var output = ""
        var position = string.startIndex
        for result in found {
            guard let bounds = Range(result.range, in: string) else { continue }
            output += string[position..<bounds.lowerBound]
            output += replacementString(for: result, in: string, offset: 0, template: templ)
            position = bounds.upperBound
        }
        output += string[position...]
        return output
    }
}

public final class NSTextCheckingResult: @unchecked Sendable {
    public struct CheckingType: OptionSet, Sendable {
        public let rawValue: UInt64
        public init(rawValue: UInt64) { self.rawValue = rawValue }
        public static let orthography = CheckingType(rawValue: 1 << 1)
        public static let spelling = CheckingType(rawValue: 1 << 2)
        public static let grammar = CheckingType(rawValue: 1 << 3)
        public static let date = CheckingType(rawValue: 1 << 4)
        public static let address = CheckingType(rawValue: 1 << 5)
        public static let link = CheckingType(rawValue: 1 << 6)
        public static let quote = CheckingType(rawValue: 1 << 7)
        public static let dash = CheckingType(rawValue: 1 << 8)
        public static let replacement = CheckingType(rawValue: 1 << 9)
        public static let correction = CheckingType(rawValue: 1 << 10)
        public static let regularExpression = CheckingType(rawValue: 1 << 11)
        public static let phoneNumber = CheckingType(rawValue: 1 << 12)
        public static let transitInformation = CheckingType(rawValue: 1 << 13)
        public static let allSystemTypes = CheckingType(rawValue: 0xffff_ffff)
        public static let allCustomTypes = CheckingType(rawValue: 0xffff_ffff << 32)
        public static let allTypes = CheckingType(rawValue: .max)
    }

    private let ranges: [NSRange]
    private let names: [String: Int]
    public let regularExpression: NSRegularExpression?

    init(ranges: [NSRange], names: [String: Int], regularExpression: NSRegularExpression?) {
        self.ranges = ranges
        self.names = names
        self.regularExpression = regularExpression
    }

    public var resultType: CheckingType { .regularExpression }
    public var range: NSRange { ranges.first ?? NSRange(location: NSNotFound, length: 0) }
    public var numberOfRanges: Int { ranges.count }

    public func range(at idx: Int) -> NSRange {
        idx >= 0 && idx < ranges.count ? ranges[idx] : NSRange(location: NSNotFound, length: 0)
    }

    public func range(withName name: String) -> NSRange {
        names[name].map { range(at: $0) } ?? NSRange(location: NSNotFound, length: 0)
    }

    public func adjustingRanges(offset: Int) -> NSTextCheckingResult {
        NSTextCheckingResult(
            ranges: ranges.map { $0.location == NSNotFound ? $0 : NSRange(location: $0.location + offset, length: $0.length) },
            names: names, regularExpression: regularExpression)
    }

    public class func regularExpressionCheckingResult(ranges: NSRangePointer, count: Int, regularExpression: NSRegularExpression) -> NSTextCheckingResult {
        NSTextCheckingResult(ranges: Array(UnsafeBufferPointer(start: ranges, count: count)), names: [:], regularExpression: regularExpression)
    }
}
