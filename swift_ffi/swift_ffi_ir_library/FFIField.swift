/// One stored property of an exported struct.
public struct FFIField: Codable, Equatable {
    public var name: String
    public var type: String

    public init(name: String, type: String) {
        self.name = name
        self.type = type
    }
}
