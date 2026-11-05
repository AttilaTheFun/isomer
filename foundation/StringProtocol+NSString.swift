// The string API Swift code reaches through NSString on Apple
// platforms and through swift-corelibs-foundation elsewhere, for platforms
// that have neither: searching, replacing, trimming and splitting by
// character sets, unlocalized comparison, percent encoding, padding. They are
// built on Essentials' own search and comparison (String+Comparison.swift).
// The "localized" comparisons compare without locale data
// (FoundationInternationalization supplies the locale-aware case mappings).

import FoundationEssentials

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension StringProtocol {
    // MARK: Finding

    /// The first range of `aString` in the string (the last, with
    /// `.backwards`), within `searchRange`.
    public func range<T: StringProtocol>(
        of aString: T, options mask: String.CompareOptions = [], range searchRange: Range<Index>? = nil,
        locale: Locale? = nil
    ) -> Range<Index>? {
        var substring = Substring(self)
        if let searchRange { substring = substring[searchRange] }
        guard let found = try? substring._range(of: Substring(aString), options: mask) else { return nil }
        return found
    }

    /// The first range of a scalar from `aSet` (the last, with
    /// `.backwards`), within `aRange`.
    public func rangeOfCharacter(
        from aSet: CharacterSet, options mask: String.CompareOptions = [], range aRange: Range<Index>? = nil
    ) -> Range<Index>? {
        var substring = Substring(self)
        if let aRange { substring = substring[aRange] }
        guard !substring.isEmpty else { return nil }
        return substring.unicodeScalars._rangeOfCharacter(
            anchored: mask.contains(.anchored), backwards: mask.contains(.backwards),
            matchingPredicate: aSet.contains)
    }

    public func localizedStandardRange<T: StringProtocol>(of str: T) -> Range<Index>? {
        range(of: str, options: [.caseInsensitive, .diacriticInsensitive])
    }

    public func localizedCaseInsensitiveContains<T: StringProtocol>(_ other: T) -> Bool {
        range(of: other, options: .caseInsensitive) != nil
    }

    public func localizedStandardContains<T: StringProtocol>(_ str: T) -> Bool {
        localizedStandardRange(of: str) != nil
    }

    // MARK: Comparing

    public func caseInsensitiveCompare<T: StringProtocol>(_ aString: T) -> ComparisonResult {
        compare(aString, options: .caseInsensitive)
    }

    public func localizedCompare<T: StringProtocol>(_ aString: T) -> ComparisonResult {
        compare(aString)
    }

    public func localizedCaseInsensitiveCompare<T: StringProtocol>(_ aString: T) -> ComparisonResult {
        compare(aString, options: .caseInsensitive)
    }

    /// Finder-style ordering: case-insensitive, numbers by value.
    public func localizedStandardCompare<T: StringProtocol>(_ string: T) -> ComparisonResult {
        compare(string, options: [.caseInsensitive, .numeric])
    }

    // MARK: Replacing

    /// The string with every occurrence of `target` in `searchRange` replaced.
    /// With `.regularExpression`, `target` is a pattern and `replacement` a
    /// template (`$0`…`$9` for the match and its groups, `\` escaping).
    public func replacingOccurrences<Target: StringProtocol, Replacement: StringProtocol>(
        of target: Target, with replacement: Replacement, options: String.CompareOptions = [],
        range searchRange: Range<Index>? = nil
    ) -> String {
        let whole = Substring(self)
        let scope = searchRange.map { whole[$0] } ?? whole
        let replacementString = String(replacement)
        guard !target.isEmpty else { return String(self) }

        var result = String(whole[whole.startIndex..<scope.startIndex])
        #if !NO_REGEX
        if options.contains(.regularExpression) {
            guard let regex = try? RegexPatternCache.cache.regex(
                for: String(target), caseInsensitive: options.contains(.caseInsensitive))
            else { return String(self) }
            var cursor = scope.startIndex
            for match in scope.matches(of: regex) {
                if options.contains(.anchored) && match.range.lowerBound != scope.startIndex { break }
                result += scope[cursor..<match.range.lowerBound]
                result += Self._expandTemplate(replacementString, match: match, in: scope)
                cursor = match.range.upperBound
                if options.contains(.anchored) { break }
            }
            result += scope[cursor...]
            result += whole[scope.endIndex...]
            return result
        }
        #endif

        var cursor = scope.startIndex
        var searchOptions = options
        searchOptions.remove(.backwards)
        while cursor <= scope.endIndex {
            guard let found = try? scope[cursor...]._range(of: Substring(target), options: searchOptions),
                  !found.isEmpty
            else { break }
            result += scope[cursor..<found.lowerBound]
            result += replacementString
            cursor = found.upperBound
            if options.contains(.anchored) { break }
        }
        result += scope[cursor...]
        result += whole[scope.endIndex...]
        return result
    }

    #if !NO_REGEX
    static func _expandTemplate(_ template: String, match: Regex<AnyRegexOutput>.Match, in scope: Substring) -> String {
        var result = ""
        var iterator = template.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                if let next = iterator.next() { result.append(next) }
            } else if character == "$", let next = iterator.next() {
                if let digit = next.wholeNumberValue, digit < match.output.count {
                    if let range = match.output[digit].range { result += scope[range] }
                } else {
                    result.append(character)
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
    #endif

    /// The string with the characters in `range` replaced by `replacement`.
    public func replacingCharacters<T: StringProtocol, R: RangeExpression>(
        in range: R, with replacement: T
    ) -> String where R.Bound == Index {
        let bounds = range.relative(to: self)
        return String(self[startIndex..<bounds.lowerBound]) + String(replacement)
            + String(self[bounds.upperBound..<endIndex])
    }

    // MARK: Trimming and splitting

    /// The string without the scalars from `set` at either end.
    public func trimmingCharacters(in set: CharacterSet) -> String {
        let scalars = Substring(self).unicodeScalars
        var start = scalars.startIndex
        var end = scalars.endIndex
        while start < end, set.contains(scalars[start]) {
            scalars.formIndex(after: &start)
        }
        while end > start {
            let before = scalars.index(before: end)
            if !set.contains(scalars[before]) { break }
            end = before
        }
        return String(Substring(scalars[start..<end]))
    }

    /// The pieces between scalars from `separator` (empty pieces kept).
    public func components(separatedBy separator: CharacterSet) -> [String] {
        let scalars = Substring(self).unicodeScalars
        var result: [String] = []
        var pieceStart = scalars.startIndex
        var index = scalars.startIndex
        while index < scalars.endIndex {
            if separator.contains(scalars[index]) {
                result.append(String(Substring(scalars[pieceStart..<index])))
                pieceStart = scalars.index(after: index)
            }
            scalars.formIndex(after: &index)
        }
        result.append(String(Substring(scalars[pieceStart..<scalars.endIndex])))
        return result
    }

    /// Calls `body` with each line, without its terminator; `stop` ends it.
    public func enumerateLines(invoking body: @escaping (_ line: String, _ stop: inout Bool) -> Void) {
        var stop = false
        var lineStart = startIndex
        var index = startIndex
        while index < endIndex {
            let character = self[index]
            if character.isNewline {
                body(String(self[lineStart..<index]), &stop)
                if stop { return }
                lineStart = self.index(after: index)
            }
            index = self.index(after: index)
        }
        if lineStart < endIndex {
            body(String(self[lineStart..<endIndex]), &stop)
        }
    }

    // MARK: Building

    public func appending<T: StringProtocol>(_ aString: T) -> String {
        String(self) + String(aString)
    }

    /// The string padded with `padString` (from `padIndex`) or cut, to
    /// `newLength` UTF-16 code units.
    public func padding<T: StringProtocol>(toLength newLength: Int, withPad padString: T, startingAt padIndex: Int) -> String {
        let units = Array(utf16)
        if units.count >= newLength {
            return String(decoding: units[0..<Swift.max(newLength, 0)], as: UTF16.self)
        }
        let pad = Array(padString.utf16)
        guard !pad.isEmpty else { return String(self) }
        var result = units
        var padPosition = padIndex % pad.count
        while result.count < newLength {
            result.append(pad[padPosition])
            padPosition = (padPosition + 1) % pad.count
        }
        return String(decoding: result, as: UTF16.self)
    }

    // MARK: Percent encoding

    /// The string with every scalar outside `allowedCharacters` written as
    /// `%XX` per UTF-8 byte.
    public func addingPercentEncoding(withAllowedCharacters allowedCharacters: CharacterSet) -> String? {
        var result = ""
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "A", "B", "C", "D", "E", "F"]
        for scalar in unicodeScalars {
            if allowedCharacters.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 {
                    result.append("%")
                    result.append(hex[Int(byte >> 4)])
                    result.append(hex[Int(byte & 0xF)])
                }
            }
        }
        return result
    }

    /// The string with its `%XX` sequences decoded, or nil when they are not
    /// valid UTF-8 or a `%` is not followed by two hex digits.
    public var removingPercentEncoding: String? {
        var bytes: [UInt8] = []
        let source = Array(utf8)
        var index = 0
        func hexValue(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        while index < source.count {
            if source[index] == 0x25 {
                guard index + 2 < source.count,
                      let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2])
                else { return nil }
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(validating: bytes, as: UTF8.self)
    }
}

