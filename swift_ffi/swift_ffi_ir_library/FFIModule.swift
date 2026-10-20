// The intermediate representation shared between the source analyzer (which
// produces it from annotated Swift) and the per-platform generators (which
// consume it to emit the C-ABI glue and native bindings). Encoded as JSON on
// disk so the two halves are decoupled.

/// The exported surface found in a single source file (or, after merging, an
/// entire module).
public struct FFIModule: Codable, Equatable {
    public var functions: [FFIFunction]
    public var interfaces: [FFIInterface]
    public var structs: [FFIStruct]
    public var enums: [FFIEnum]
    /// The Swift modules these declarations came from. Exports may live in
    /// transitive dependencies (e.g. a dependency's exported protocol
    /// re-exported through a bridge module); the glue imports every contributor.
    public var sourceModules: [String]

    public init(
        functions: [FFIFunction] = [],
        interfaces: [FFIInterface] = [],
        structs: [FFIStruct] = [],
        enums: [FFIEnum] = [],
        sourceModules: [String] = []
    ) {
        self.functions = functions
        self.interfaces = interfaces
        self.structs = structs
        self.enums = enums
        self.sourceModules = sourceModules
    }

    /// Backward-compatible decoding: analysis files written before
    /// `sourceModules` existed simply lack the key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        functions = try container.decodeIfPresent([FFIFunction].self, forKey: .functions) ?? []
        interfaces = try container.decodeIfPresent([FFIInterface].self, forKey: .interfaces) ?? []
        structs = try container.decodeIfPresent([FFIStruct].self, forKey: .structs) ?? []
        enums = try container.decodeIfPresent([FFIEnum].self, forKey: .enums) ?? []
        sourceModules = try container.decodeIfPresent([String].self, forKey: .sourceModules) ?? []
    }

    public var isEmpty: Bool {
        functions.isEmpty && interfaces.isEmpty && structs.isEmpty && enums.isEmpty
    }

    /// Combines two analyses (e.g. merging per-file IR into a module-wide one).
    ///
    /// A declaration that is already present verbatim is not appended again:
    /// the same source file can be analyzed under two Bazel configurations
    /// when a module is reached through two dependency paths (e.g. an alias
    /// and a direct edge), and its exports must be emitted once. A *different*
    /// declaration with the same name is kept so validation still reports it.
    public mutating func merge(_ other: FFIModule) {
        functions.append(contentsOf: other.functions.filter { !functions.contains($0) })
        interfaces.append(contentsOf: other.interfaces.filter { !interfaces.contains($0) })
        structs.append(contentsOf: other.structs.filter { !structs.contains($0) })
        enums.append(contentsOf: other.enums.filter { !enums.contains($0) })
        for module in other.sourceModules where !sourceModules.contains(module) {
            sourceModules.append(module)
        }
    }

    /// The names of all exported interfaces (for validating handle-typed
    /// parameters and returns after the per-file IRs are merged).
    public var interfaceNames: Set<String> { Set(interfaces.map(\.name)) }

    /// The names of all exported structs.
    public var structNames: Set<String> { Set(structs.map(\.name)) }

    /// The names of all exported enums.
    public var enumNames: Set<String> { Set(enums.map(\.name)) }
}
