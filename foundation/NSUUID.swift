// NSUUID, as swift-corelibs-foundation has it: a class over swift-foundation's
// UUID, for code written against the Objective-C API (a reference to share,
// `getBytes(_:)` into a C buffer). Equal when their bytes are, described by
// its string. No NSCopying or NSSecureCoding: Isomer's Foundation has no
// coders. UUID and NSUUID bridge as Swift's numbers and NSNumber do
// (NSNumberBridging.swift): `value as? UUID` on an NSUUID held as Any, and
// back.

import FoundationEssentials

open class NSUUID: NSObject, @unchecked Sendable {
    let value: UUID

    /// A new random (version 4) UUID.
    public override init() {
        value = UUID()
        super.init()
    }

    init(value: UUID) {
        self.value = value
        super.init()
    }

    /// A UUID from its string ("E621E1F8-C36C-495A-93FC-0C247A3E6E5F"), or nil.
    public convenience init?(uuidString string: String) {
        guard let value = UUID(uuidString: string) else { return nil }
        self.init(value: value)
    }

    /// A UUID from its 16 bytes (all zero for nil).
    public convenience init(uuidBytes bytes: UnsafePointer<UInt8>?) {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        if let bytes {
            withUnsafeMutableBytes(of: &uuid) { $0.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16)) }
        }
        self.init(value: UUID(uuid: uuid))
    }

    /// Writes its 16 bytes into `uuid`.
    open func getBytes(_ uuid: UnsafeMutablePointer<UInt8>) {
        withUnsafeBytes(of: value.uuid) { UnsafeMutableRawPointer(uuid).copyMemory(from: $0.baseAddress!, byteCount: 16) }
    }

    /// Ordered by bytes, as UUID is.
    open func compare(_ otherUUID: UUID) -> ComparisonResult {
        value == otherUUID ? .orderedSame : (value < otherUUID ? .orderedAscending : .orderedDescending)
    }

    open var uuidString: String { value.uuidString }

    open override func isEqual(_ object: Any?) -> Bool {
        (object as? NSUUID)?.value == value
    }

    open override var hash: Int { value.hashValue }

    open override var description: String { value.uuidString }
}

extension UUID: _ObjectiveCBridgeable {
    public func _bridgeToObjectiveC() -> NSUUID { NSUUID(value: self) }

    public static func _forceBridgeFromObjectiveC(_ x: NSUUID, result: inout UUID?) {
        result = x.value
    }

    @discardableResult
    public static func _conditionallyBridgeFromObjectiveC(_ input: NSUUID, result: inout UUID?) -> Bool {
        result = input.value
        return true
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSUUID?) -> UUID {
        source?.value ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}
