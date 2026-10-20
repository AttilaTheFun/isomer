/// An exported interface (a Swift protocol bridged as an owned handle with an
/// idiomatic wrapper on the consumer side).
public struct FFIInterface: Codable, Equatable {
    public var name: String
    public var methods: [FFIMethod]
    /// The C symbol namespace segment (`@ExportedInterface(namespace:)`):
    /// the entries are `swift_ffi_[<namespace>_]<name>_invoke` / `_release` /
    /// `register_<name>`.
    public var namespace: String?

    public init(name: String, methods: [FFIMethod], namespace: String? = nil) {
        self.name = name
        self.methods = methods
        self.namespace = namespace
    }
}
