/// The artifact kinds the generator emits — one per invocation.
public enum GeneratorKind: String, CaseIterable, Sendable {
    case jniAdapter = "jni-adapter"
    case cHeader = "c-header"
    case cpp
    case rust
    case ts
    case kotlin
    case swiftHostWasm = "swift-host-wasm"
    case cHostWasm = "c-host-wasm"
}

// MARK: - Shared helpers
