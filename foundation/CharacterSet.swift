// CharacterSet for platforms without Apple's framework. Upstream
// leaves it to swift-corelibs-foundation's NSCharacterSet; here it is a Swift
// value: explicit ranges of scalars, the built-in sets (by Unicode general
// category, CoreFoundation's bitmaps where Essentials has them, the URL
// component sets by RFC 3986), and their combinations, evaluated per scalar.

import FoundationEssentials

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
public struct CharacterSet: Hashable, SetAlgebra, Sendable {
    public typealias Element = Unicode.Scalar
    public typealias ArrayLiteralElement = Unicode.Scalar

    enum BuiltIn: Hashable, Sendable {
        case controlCharacters
        case whitespaces
        case whitespacesAndNewlines
        case decimalDigits
        case letters
        case lowercaseLetters
        case uppercaseLetters
        case nonBaseCharacters
        case alphanumerics
        case decomposables
        case illegalCharacters
        case punctuationCharacters
        case capitalizedLetters
        case symbols
        case newlines
        case urlUserAllowed
        case urlPasswordAllowed
        case urlHostAllowed
        case urlPathAllowed
        case urlQueryAllowed
        case urlFragmentAllowed

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            let value = scalar.value
            switch self {
            case .controlCharacters:
                switch scalar.properties.generalCategory {
                case .control, .format: return true
                default: return false
                }
            case .whitespaces:
                return value == 0x09 || scalar.properties.generalCategory == .spaceSeparator
            case .whitespacesAndNewlines:
                if (0x09...0x0D).contains(value) || value == 0x85 { return true }
                switch scalar.properties.generalCategory {
                case .spaceSeparator, .lineSeparator, .paragraphSeparator: return true
                default: return false
                }
            case .newlines:
                return (0x0A...0x0D).contains(value) || value == 0x85 || value == 0x2028 || value == 0x2029
            case .decimalDigits:
                return scalar.properties.generalCategory == .decimalNumber
            case .letters:
                return Self.isLetter(scalar) || Self.isMark(scalar)
            case .lowercaseLetters:
                return BuiltInUnicodeScalarSet.lowercaseLetters.contains(scalar)
                    || scalar.properties.generalCategory == .lowercaseLetter
            case .uppercaseLetters:
                return BuiltInUnicodeScalarSet.uppercaseLetters.contains(scalar)
                    || scalar.properties.generalCategory == .uppercaseLetter
                    || scalar.properties.generalCategory == .titlecaseLetter
            case .nonBaseCharacters:
                return Self.isMark(scalar)
            case .alphanumerics:
                return Self.isLetter(scalar) || Self.isMark(scalar) || Self.isNumber(scalar)
            case .decomposables:
                return BuiltInUnicodeScalarSet.canonicalDecomposables.contains(scalar)
            case .illegalCharacters:
                return scalar.properties.generalCategory == .unassigned
            case .punctuationCharacters:
                switch scalar.properties.generalCategory {
                case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
                     .initialPunctuation, .finalPunctuation, .otherPunctuation:
                    return true
                default:
                    return false
                }
            case .capitalizedLetters:
                return scalar.properties.generalCategory == .titlecaseLetter
            case .symbols:
                switch scalar.properties.generalCategory {
                case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
                default: return false
                }
            case .urlUserAllowed, .urlPasswordAllowed:
                return Self.isUnreserved(value) || Self.isSubDelimiter(value)
            case .urlHostAllowed:
                return Self.isUnreserved(value) || Self.isSubDelimiter(value)
                    || value == 0x3A || value == 0x5B || value == 0x5D  // : [ ]
            case .urlPathAllowed:
                return Self.isUnreserved(value) || Self.isSubDelimiter(value)
                    || value == 0x3A || value == 0x40 || value == 0x2F  // : @ /
            case .urlQueryAllowed, .urlFragmentAllowed:
                return Self.isUnreserved(value) || Self.isSubDelimiter(value)
                    || value == 0x3A || value == 0x40 || value == 0x2F || value == 0x3F  // : @ / ?
            }
        }

        static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: return true
            default: return false
            }
        }

        static func isMark(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: return true
            default: return false
            }
        }

        static func isNumber(_ scalar: Unicode.Scalar) -> Bool {
            switch scalar.properties.generalCategory {
            case .decimalNumber, .letterNumber, .otherNumber: return true
            default: return false
            }
        }

        /// RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~".
        static func isUnreserved(_ value: UInt32) -> Bool {
            (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || (0x30...0x39).contains(value)
                || value == 0x2D || value == 0x2E || value == 0x5F || value == 0x7E
        }

        /// RFC 3986 sub-delims: "!" / "$" / "&" / "'" / "(" / ")" / "*" / "+" / "," / ";" / "=".
        static func isSubDelimiter(_ value: UInt32) -> Bool {
            switch value {
            case 0x21, 0x24, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x2B, 0x2C, 0x3B, 0x3D: return true
            default: return false
            }
        }
    }

    indirect enum Storage: Hashable, Sendable {
        /// Sorted, non-overlapping, non-adjacent ranges of scalar values.
        case ranges([ClosedRange<UInt32>])
        case builtIn(BuiltIn)
        case inverted(Storage)
        case union(Storage, Storage)
        case intersection(Storage, Storage)
        case subtracting(Storage, Storage)
        case symmetricDifference(Storage, Storage)

        func contains(_ scalar: Unicode.Scalar) -> Bool {
            switch self {
            case .ranges(let ranges):
                let value = scalar.value
                var low = 0
                var high = ranges.count - 1
                while low <= high {
                    let middle = (low + high) / 2
                    let range = ranges[middle]
                    if value < range.lowerBound {
                        high = middle - 1
                    } else if value > range.upperBound {
                        low = middle + 1
                    } else {
                        return true
                    }
                }
                return false
            case .builtIn(let set):
                return set.contains(scalar)
            case .inverted(let set):
                return !set.contains(scalar)
            case .union(let a, let b):
                return a.contains(scalar) || b.contains(scalar)
            case .intersection(let a, let b):
                return a.contains(scalar) && b.contains(scalar)
            case .subtracting(let a, let b):
                return a.contains(scalar) && !b.contains(scalar)
            case .symmetricDifference(let a, let b):
                return a.contains(scalar) != b.contains(scalar)
            }
        }

        var explicitRanges: [ClosedRange<UInt32>]? {
            if case .ranges(let ranges) = self { return ranges }
            return nil
        }
    }

    var storage: Storage

    init(storage: Storage) {
        self.storage = storage
    }

    // MARK: Making sets

    public init() {
        storage = .ranges([])
    }

    public init(charactersIn range: Range<Unicode.Scalar>) {
        if range.isEmpty {
            storage = .ranges([])
        } else {
            storage = .ranges([range.lowerBound.value...(range.upperBound.value - 1)])
        }
    }

    public init(charactersIn range: ClosedRange<Unicode.Scalar>) {
        storage = .ranges([range.lowerBound.value...range.upperBound.value])
    }

    public init(charactersIn string: __shared String) {
        storage = .ranges(Self.normalized(string.unicodeScalars.map { $0.value...$0.value }))
    }

    /// A set from a bitmap as `bitmapRepresentation` makes one.
    public init(bitmapRepresentation data: __shared Data) {
        var ranges: [ClosedRange<UInt32>] = []
        let bytes = [UInt8](data)
        func addPlane(_ plane: UInt32, from offset: Int) {
            guard offset < bytes.count else { return }
            let end = min(offset + 8192, bytes.count)
            for index in offset..<end where bytes[index] != 0 {
                for bit in 0..<8 where bytes[index] & (1 << bit) != 0 {
                    let value = (plane << 16) | UInt32((index - offset) * 8 + bit)
                    ranges.append(value...value)
                }
            }
        }
        addPlane(0, from: 0)
        var offset = 8192
        while offset < bytes.count {
            let plane = UInt32(bytes[offset])
            addPlane(plane, from: offset + 1)
            offset += 8193
        }
        storage = .ranges(Self.normalized(ranges))
    }

    public init?(contentsOfFile file: __shared String) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else { return nil }
        self.init(bitmapRepresentation: data)
    }

    public init(arrayLiteral elements: Unicode.Scalar...) {
        storage = .ranges(Self.normalized(elements.map { $0.value...$0.value }))
    }

    public static var controlCharacters: CharacterSet { CharacterSet(storage: .builtIn(.controlCharacters)) }
    public static var whitespaces: CharacterSet { CharacterSet(storage: .builtIn(.whitespaces)) }
    public static var whitespacesAndNewlines: CharacterSet { CharacterSet(storage: .builtIn(.whitespacesAndNewlines)) }
    public static var decimalDigits: CharacterSet { CharacterSet(storage: .builtIn(.decimalDigits)) }
    public static var letters: CharacterSet { CharacterSet(storage: .builtIn(.letters)) }
    public static var lowercaseLetters: CharacterSet { CharacterSet(storage: .builtIn(.lowercaseLetters)) }
    public static var uppercaseLetters: CharacterSet { CharacterSet(storage: .builtIn(.uppercaseLetters)) }
    public static var nonBaseCharacters: CharacterSet { CharacterSet(storage: .builtIn(.nonBaseCharacters)) }
    public static var alphanumerics: CharacterSet { CharacterSet(storage: .builtIn(.alphanumerics)) }
    public static var decomposables: CharacterSet { CharacterSet(storage: .builtIn(.decomposables)) }
    public static var illegalCharacters: CharacterSet { CharacterSet(storage: .builtIn(.illegalCharacters)) }
    public static var punctuationCharacters: CharacterSet { CharacterSet(storage: .builtIn(.punctuationCharacters)) }
    public static var capitalizedLetters: CharacterSet { CharacterSet(storage: .builtIn(.capitalizedLetters)) }
    public static var symbols: CharacterSet { CharacterSet(storage: .builtIn(.symbols)) }
    public static var newlines: CharacterSet { CharacterSet(storage: .builtIn(.newlines)) }
    public static var urlUserAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlUserAllowed)) }
    public static var urlPasswordAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlPasswordAllowed)) }
    public static var urlHostAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlHostAllowed)) }
    public static var urlPathAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlPathAllowed)) }
    public static var urlQueryAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlQueryAllowed)) }
    public static var urlFragmentAllowed: CharacterSet { CharacterSet(storage: .builtIn(.urlFragmentAllowed)) }

    // MARK: Membership

    public func contains(_ member: Unicode.Scalar) -> Bool {
        storage.contains(member)
    }

    public var inverted: CharacterSet {
        if case .inverted(let inner) = storage { return CharacterSet(storage: inner) }
        return CharacterSet(storage: .inverted(storage))
    }

    public mutating func invert() {
        self = inverted
    }

    public func hasMember(inPlane plane: UInt8) -> Bool {
        let start = UInt32(plane) << 16
        for value in start...(start + 0xFFFF) {
            if let scalar = Unicode.Scalar(value), contains(scalar) { return true }
        }
        return false
    }

    /// The set as a bitmap: 8192 bytes for the Basic Multilingual Plane, then
    /// for each other plane with members its number and 8192 bytes.
    public var bitmapRepresentation: Data {
        var result = Data(count: 8192)
        for plane in UInt32(0)...16 {
            var bitmap = [UInt8](repeating: 0, count: 8192)
            var any = false
            for low in UInt32(0)...0xFFFF {
                if let scalar = Unicode.Scalar((plane << 16) | low), contains(scalar) {
                    bitmap[Int(low >> 3)] |= UInt8(1 << (low & 7))
                    any = true
                }
            }
            if plane == 0 {
                result = Data(bitmap)
            } else if any {
                result.append(UInt8(plane))
                result.append(contentsOf: bitmap)
            }
        }
        return result
    }

    // MARK: Changing sets

    public mutating func insert(charactersIn range: Range<Unicode.Scalar>) {
        formUnion(CharacterSet(charactersIn: range))
    }

    public mutating func insert(charactersIn range: ClosedRange<Unicode.Scalar>) {
        formUnion(CharacterSet(charactersIn: range))
    }

    public mutating func remove(charactersIn range: Range<Unicode.Scalar>) {
        subtract(CharacterSet(charactersIn: range))
    }

    public mutating func remove(charactersIn range: ClosedRange<Unicode.Scalar>) {
        subtract(CharacterSet(charactersIn: range))
    }

    public mutating func insert(charactersIn string: String) {
        formUnion(CharacterSet(charactersIn: string))
    }

    public mutating func remove(charactersIn string: String) {
        subtract(CharacterSet(charactersIn: string))
    }

    @discardableResult
    public mutating func insert(_ character: Unicode.Scalar) -> (inserted: Bool, memberAfterInsert: Unicode.Scalar) {
        if contains(character) { return (false, character) }
        formUnion(CharacterSet(charactersIn: character...character))
        return (true, character)
    }

    @discardableResult
    public mutating func update(with character: Unicode.Scalar) -> Unicode.Scalar? {
        let present = contains(character)
        formUnion(CharacterSet(charactersIn: character...character))
        return present ? character : nil
    }

    @discardableResult
    public mutating func remove(_ character: Unicode.Scalar) -> Unicode.Scalar? {
        guard contains(character) else { return nil }
        subtract(CharacterSet(charactersIn: character...character))
        return character
    }

    // MARK: Set algebra

    public func union(_ other: CharacterSet) -> CharacterSet {
        if let a = storage.explicitRanges, let b = other.storage.explicitRanges {
            return CharacterSet(storage: .ranges(Self.normalized(a + b)))
        }
        return CharacterSet(storage: .union(storage, other.storage))
    }

    public mutating func formUnion(_ other: CharacterSet) {
        self = union(other)
    }

    public func intersection(_ other: CharacterSet) -> CharacterSet {
        if let a = storage.explicitRanges, let b = other.storage.explicitRanges {
            var result: [ClosedRange<UInt32>] = []
            var i = 0, j = 0
            while i < a.count && j < b.count {
                let low = max(a[i].lowerBound, b[j].lowerBound)
                let high = min(a[i].upperBound, b[j].upperBound)
                if low <= high { result.append(low...high) }
                if a[i].upperBound < b[j].upperBound { i += 1 } else { j += 1 }
            }
            return CharacterSet(storage: .ranges(result))
        }
        return CharacterSet(storage: .intersection(storage, other.storage))
    }

    public mutating func formIntersection(_ other: CharacterSet) {
        self = intersection(other)
    }

    public func subtracting(_ other: CharacterSet) -> CharacterSet {
        if let a = storage.explicitRanges, let b = other.storage.explicitRanges {
            var result: [ClosedRange<UInt32>] = []
            for range in a {
                var pieces = [range]
                for cut in b where cut.overlaps(range) {
                    pieces = pieces.flatMap { piece -> [ClosedRange<UInt32>] in
                        guard piece.overlaps(cut) else { return [piece] }
                        var kept: [ClosedRange<UInt32>] = []
                        if piece.lowerBound < cut.lowerBound { kept.append(piece.lowerBound...(cut.lowerBound - 1)) }
                        if piece.upperBound > cut.upperBound { kept.append((cut.upperBound + 1)...piece.upperBound) }
                        return kept
                    }
                }
                result.append(contentsOf: pieces)
            }
            return CharacterSet(storage: .ranges(Self.normalized(result)))
        }
        return CharacterSet(storage: .subtracting(storage, other.storage))
    }

    public mutating func subtract(_ other: CharacterSet) {
        self = subtracting(other)
    }

    public func symmetricDifference(_ other: CharacterSet) -> CharacterSet {
        if storage.explicitRanges != nil, other.storage.explicitRanges != nil {
            return subtracting(other).union(other.subtracting(self))
        }
        return CharacterSet(storage: .symmetricDifference(storage, other.storage))
    }

    public mutating func formSymmetricDifference(_ other: CharacterSet) {
        self = symmetricDifference(other)
    }

    public func isSuperset(of other: CharacterSet) -> Bool {
        other.subtracting(self).isEmpty
    }

    public var isEmpty: Bool {
        if let ranges = storage.explicitRanges { return ranges.isEmpty }
        return materializedRanges.isEmpty
    }

    // MARK: Equality

    /// Every member, as ranges: what equality compares when a set is not
    /// already explicit ranges (it reads all 1,114,112 code points).
    var materializedRanges: [ClosedRange<UInt32>] {
        if let ranges = storage.explicitRanges { return ranges }
        var ranges: [ClosedRange<UInt32>] = []
        var start: UInt32?
        for value in UInt32(0)...0x10FFFF {
            let member = Unicode.Scalar(value).map(contains) ?? false
            if member, start == nil { start = value }
            if !member, let first = start {
                ranges.append(first...(value - 1))
                start = nil
            }
        }
        if let first = start { ranges.append(first...0x10FFFF) }
        return ranges
    }

    public static func == (lhs: CharacterSet, rhs: CharacterSet) -> Bool {
        if lhs.storage == rhs.storage { return true }
        return lhs.materializedRanges == rhs.materializedRanges
    }

    /// Hashes membership of the ASCII and Latin-1 range: equal sets hash
    /// equally whatever their storage.
    public func hash(into hasher: inout Hasher) {
        var bits: UInt64 = 0
        var word = 0
        for value in UInt32(0)..<256 {
            if contains(Unicode.Scalar(value)!) { bits |= 1 << UInt64(value & 63) }
            if value & 63 == 63 {
                hasher.combine(bits)
                bits = 0
                word += 1
            }
        }
    }

    // MARK: Helpers

    static func normalized(_ ranges: [ClosedRange<UInt32>]) -> [ClosedRange<UInt32>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<UInt32>] = []
        for range in sorted {
            if let last = result.last, range.lowerBound <= last.upperBound &+ 1 {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }
}

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension CharacterSet: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "<CharacterSet>" }
    public var debugDescription: String { description }
}

@available(macOS 10.10, iOS 8.0, watchOS 2.0, tvOS 9.0, *)
extension CharacterSet: Codable {
    private enum CodingKeys: String, CodingKey {
        case bitmap
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bitmapRepresentation: try container.decode(Data.self, forKey: .bitmap))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bitmapRepresentation, forKey: .bitmap)
    }
}

