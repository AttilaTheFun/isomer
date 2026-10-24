// `as? Int` (and the other numbers) on an NSNumber, as Apple's Foundation
// has it: each number type bridges to NSNumber, and Swift's runtime casts
// through `_ObjectiveCBridgeable` on every platform, Objective-C or not. A
// cast succeeds only when the number is exactly one of the type (SE-0170):
// `2.5 as? Int` is nil, `1 as? Double` 1.0, `true as? Int` 1; a Double that
// isn't exactly a Float becomes the nearest one, as Apple's does. What
// JSONSerialization reads, `json["count"] as? Int`, works so.

import FoundationEssentials

extension NSNumber {
    /// The number as `T`, when it is exactly one.
    func exactly<T: BinaryInteger>(_: T.Type) -> T? {
        switch storage {
        case .signed(let v): return T(exactly: v)
        case .unsigned(let v): return T(exactly: v)
        case .floating(let v): return T(exactly: v)
        case .boolean(let v): return v ? 1 : 0
        }
    }

    /// The number as `T`, when it is exactly one (a Double within a
    /// Float's range is one, rounded).
    func exactly<T: BinaryFloatingPoint>(_: T.Type) -> T? {
        switch storage {
        case .signed(let v): return T(exactly: v)
        case .unsigned(let v): return T(exactly: v)
        case .floating(let v):
            if v.isNaN { return T.nan }
            if let exact = T(exactly: v) { return exact }
            return abs(v) <= Double(T.greatestFiniteMagnitude) || v.isInfinite ? T(v) : nil
        case .boolean(let v): return v ? 1 : 0
        }
    }
}

extension Bool {
    /// True for a number that is 1 (or true), false for 0 (or false), else nil.
    public init?(exactly number: NSNumber) {
        if let value = number.boolStorage {
            self = value
        } else if number.doubleValue == 1 {
            self = true
        } else if number.doubleValue == 0 {
            self = false
        } else {
            return nil
        }
    }
}

extension Int {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Int.self) else { return nil }
        self = value
    }
}

extension Int: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Int?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Int?) -> Bool {
        result = Int(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int {
        guard let source, let value = Int(exactly: source) else { fatalError("Unable to bridge NSNumber to Int") }
        return value
    }
}

extension Int8 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Int8.self) else { return nil }
        self = value
    }
}

extension Int8: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Int8?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Int8?) -> Bool {
        result = Int8(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int8 {
        guard let source, let value = Int8(exactly: source) else { fatalError("Unable to bridge NSNumber to Int8") }
        return value
    }
}

extension Int16 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Int16.self) else { return nil }
        self = value
    }
}

extension Int16: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Int16?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Int16?) -> Bool {
        result = Int16(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int16 {
        guard let source, let value = Int16(exactly: source) else { fatalError("Unable to bridge NSNumber to Int16") }
        return value
    }
}

extension Int32 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Int32.self) else { return nil }
        self = value
    }
}

extension Int32: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Int32?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Int32?) -> Bool {
        result = Int32(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int32 {
        guard let source, let value = Int32(exactly: source) else { fatalError("Unable to bridge NSNumber to Int32") }
        return value
    }
}

extension Int64 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Int64.self) else { return nil }
        self = value
    }
}

extension Int64: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Int64?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Int64?) -> Bool {
        result = Int64(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Int64 {
        guard let source, let value = Int64(exactly: source) else { fatalError("Unable to bridge NSNumber to Int64") }
        return value
    }
}

extension UInt {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(UInt.self) else { return nil }
        self = value
    }
}

extension UInt: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt?) -> Bool {
        result = UInt(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt {
        guard let source, let value = UInt(exactly: source) else { fatalError("Unable to bridge NSNumber to UInt") }
        return value
    }
}

extension UInt8 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(UInt8.self) else { return nil }
        self = value
    }
}

extension UInt8: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt8?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt8?) -> Bool {
        result = UInt8(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt8 {
        guard let source, let value = UInt8(exactly: source) else { fatalError("Unable to bridge NSNumber to UInt8") }
        return value
    }
}

extension UInt16 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(UInt16.self) else { return nil }
        self = value
    }
}

extension UInt16: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt16?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt16?) -> Bool {
        result = UInt16(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt16 {
        guard let source, let value = UInt16(exactly: source) else { fatalError("Unable to bridge NSNumber to UInt16") }
        return value
    }
}

extension UInt32 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(UInt32.self) else { return nil }
        self = value
    }
}

extension UInt32: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt32?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt32?) -> Bool {
        result = UInt32(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt32 {
        guard let source, let value = UInt32(exactly: source) else { fatalError("Unable to bridge NSNumber to UInt32") }
        return value
    }
}

extension UInt64 {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(UInt64.self) else { return nil }
        self = value
    }
}

extension UInt64: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt64?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout UInt64?) -> Bool {
        result = UInt64(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> UInt64 {
        guard let source, let value = UInt64(exactly: source) else { fatalError("Unable to bridge NSNumber to UInt64") }
        return value
    }
}

extension Float {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Float.self) else { return nil }
        self = value
    }
}

extension Float: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Float?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Float?) -> Bool {
        result = Float(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Float {
        guard let source, let value = Float(exactly: source) else { fatalError("Unable to bridge NSNumber to Float") }
        return value
    }
}

extension Double {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(Double.self) else { return nil }
        self = value
    }
}

extension Double: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Double?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Double?) -> Bool {
        result = Double(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Double {
        guard let source, let value = Double(exactly: source) else { fatalError("Unable to bridge NSNumber to Double") }
        return value
    }
}

extension CGFloat {
    public init?(exactly number: NSNumber) {
        guard let value = number.exactly(CGFloat.self) else { return nil }
        self = value
    }
}

extension CGFloat: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: Double(self)) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout CGFloat?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout CGFloat?) -> Bool {
        result = CGFloat(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> CGFloat {
        guard let source, let value = CGFloat(exactly: source) else { fatalError("Unable to bridge NSNumber to CGFloat") }
        return value
    }
}

extension Bool: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSNumber { NSNumber(value: self) }

    public static func _forceBridgeFromObjectiveC(_ source: NSNumber, result: inout Bool?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ source: NSNumber, result: inout Bool?) -> Bool {
        result = Bool(exactly: source)
        return result != nil
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSNumber?) -> Bool {
        guard let source, let value = Bool(exactly: source) else { fatalError("Unable to bridge NSNumber to Bool") }
        return value
    }
}
