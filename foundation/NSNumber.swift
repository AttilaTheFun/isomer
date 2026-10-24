// NSNumber (Apple's Foundation and corelibs have it; swift-foundation does
// not): a number of any of Swift's numeric types, read back as any. A Swift
// class; Swift's numbers bridge to it as Apple's do (NSNumberBridging.swift:
// `as? Int` on an NSNumber is exact, `intValue` truncates).

import FoundationEssentials

open class NSNumber: Hashable, CustomStringConvertible, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, @unchecked Sendable {
    enum Storage: Hashable {
        case signed(Int64)
        case unsigned(UInt64)
        case floating(Double)
        case boolean(Bool)
    }

    let storage: Storage

    public init(value: Int) { storage = .signed(Int64(value)) }
    public init(value: Int8) { storage = .signed(Int64(value)) }
    public init(value: Int16) { storage = .signed(Int64(value)) }
    public init(value: Int32) { storage = .signed(Int64(value)) }
    public init(value: Int64) { storage = .signed(value) }
    public init(value: UInt) { storage = .unsigned(UInt64(value)) }
    public init(value: UInt8) { storage = .unsigned(UInt64(value)) }
    public init(value: UInt16) { storage = .unsigned(UInt64(value)) }
    public init(value: UInt32) { storage = .unsigned(UInt64(value)) }
    public init(value: UInt64) { storage = .unsigned(value) }
    public init(value: Float) { storage = .floating(Double(value)) }
    public init(value: Double) { storage = .floating(value) }
    public init(value: Bool) { storage = .boolean(value) }

    /// What the number was made from, for JSONSerialization's writing.
    var boolStorage: Bool? { if case .boolean(let v) = storage { v } else { nil } }
    var isFloatingStorage: Bool { if case .floating = storage { true } else { false } }
    var isUnsignedStorage: Bool { if case .unsigned = storage { true } else { false } }

    public required convenience init(integerLiteral value: Int) { self.init(value: value) }
    public required convenience init(floatLiteral value: Double) { self.init(value: value) }
    public required convenience init(booleanLiteral value: Bool) { self.init(value: value) }

    open var int64Value: Int64 {
        switch storage {
        case .signed(let v): return v
        case .unsigned(let v): return Int64(truncatingIfNeeded: v)
        case .floating(let v): return v.isFinite ? Int64(v.rounded(.towardZero).clamped(-9.2e18, 9.2e18)) : 0
        case .boolean(let v): return v ? 1 : 0
        }
    }

    open var uint64Value: UInt64 {
        switch storage {
        case .unsigned(let v): return v
        case .signed(let v): return UInt64(truncatingIfNeeded: v)
        case .floating(let v): return v.isFinite && v > 0 ? UInt64(v.rounded(.towardZero).clamped(0, 1.8e19)) : 0
        case .boolean(let v): return v ? 1 : 0
        }
    }

    open var doubleValue: Double {
        switch storage {
        case .signed(let v): return Double(v)
        case .unsigned(let v): return Double(v)
        case .floating(let v): return v
        case .boolean(let v): return v ? 1 : 0
        }
    }

    open var boolValue: Bool {
        switch storage {
        case .boolean(let v): return v
        case .floating(let v): return v != 0
        default: return int64Value != 0
        }
    }

    open var intValue: Int { Int(truncatingIfNeeded: int64Value) }
    open var int8Value: Int8 { Int8(truncatingIfNeeded: int64Value) }
    open var int16Value: Int16 { Int16(truncatingIfNeeded: int64Value) }
    open var int32Value: Int32 { Int32(truncatingIfNeeded: int64Value) }
    open var uintValue: UInt { UInt(truncatingIfNeeded: uint64Value) }
    open var uint8Value: UInt8 { UInt8(truncatingIfNeeded: uint64Value) }
    open var uint16Value: UInt16 { UInt16(truncatingIfNeeded: uint64Value) }
    open var uint32Value: UInt32 { UInt32(truncatingIfNeeded: uint64Value) }
    open var floatValue: Float { Float(doubleValue) }

    open var stringValue: String {
        switch storage {
        case .signed(let v): return String(v)
        case .unsigned(let v): return String(v)
        case .floating(let v): return v == v.rounded() && abs(v) < 1e15 ? String(Int64(v)) : String(v)
        case .boolean(let v): return v ? "1" : "0"
        }
    }

    open var description: String { stringValue }

    open func compare(_ otherNumber: NSNumber) -> ComparisonResult {
        let a = doubleValue, b = otherNumber.doubleValue
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    open func isEqual(to number: NSNumber) -> Bool {
        compare(number) == .orderedSame
    }

    public static func == (a: NSNumber, b: NSNumber) -> Bool {
        a.isEqual(to: b)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(doubleValue)
    }
}

extension Double {
    fileprivate func clamped(_ low: Double, _ high: Double) -> Double {
        Swift.min(Swift.max(self, low), high)
    }
}

extension Int {
    public init(truncating number: NSNumber) { self = number.intValue }
}

extension Double {
    public init(truncating number: NSNumber) { self = number.doubleValue }
}

extension Bool {
    public init(truncating number: NSNumber) { self = number.boolValue }
}
