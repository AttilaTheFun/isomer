/// The Swift types swift_ffi passes across the flat C-ABI boundary by value.
/// Scalars map to identical C representations; `String` is copied at the
/// boundary (UTF-8 bytes in, a released string box out).
public enum BridgeValueType: String, CaseIterable, Sendable {
    case int = "Int"
    case int32 = "Int32"
    case double = "Double"
    case bool = "Bool"
    case string = "String"
    case bytes = "[UInt8]"

    public init?(typeName: String) {
        self.init(rawValue: typeName)
    }
}
