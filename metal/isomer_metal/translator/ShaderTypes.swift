// The shader translator's types: what an MSL type is once resolved, how it
// is spelled in WGSL, and how it is laid out in memory (MSL's rules, which a
// translated struct reproduces with @size where WGSL's differ).

public enum ShaderScalar: String, Hashable, Sendable {
    case bool
    case int
    case uint
    case float
    /// A literal without a suffix: it takes the type it is used as (WGSL's
    /// abstract numbers do the same).
    case abstractInt
    case abstractFloat

    var wgsl: String {
        switch self {
        case .bool: return "bool"
        case .int, .abstractInt: return "i32"
        case .uint: return "u32"
        case .float, .abstractFloat: return "f32"
        }
    }

    var isFloat: Bool { self == .float || self == .abstractFloat }
    var isInteger: Bool { self == .int || self == .uint || self == .abstractInt }
    var isAbstract: Bool { self == .abstractInt || self == .abstractFloat }

    /// The concrete type an abstract literal becomes by itself.
    var concrete: ShaderScalar {
        switch self {
        case .abstractInt: return .int
        case .abstractFloat: return .float
        default: return self
        }
    }
}

public enum ShaderTextureKind: String, Hashable, Sendable {
    case texture1d, texture1dArray, texture2d, texture2dArray, texture2dMS, texture3d, textureCube, textureCubeArray
    case depth2d, depth2dArray, depth2dMS, depthCube

    var isDepth: Bool { rawValue.hasPrefix("depth") }

    var wgslName: String {
        switch self {
        case .texture1d: return "texture_1d"
        case .texture1dArray: return "texture_1d"
        case .texture2d: return "texture_2d"
        case .texture2dArray: return "texture_2d_array"
        case .texture2dMS: return "texture_multisampled_2d"
        case .texture3d: return "texture_3d"
        case .textureCube: return "texture_cube"
        case .textureCubeArray: return "texture_cube_array"
        case .depth2d: return "texture_depth_2d"
        case .depth2dArray: return "texture_depth_2d_array"
        case .depth2dMS: return "texture_depth_multisampled_2d"
        case .depthCube: return "texture_depth_cube"
        }
    }

    var storageName: String {
        switch self {
        case .texture1d, .texture1dArray: return "texture_storage_1d"
        case .texture2dArray: return "texture_storage_2d_array"
        case .texture3d: return "texture_storage_3d"
        default: return "texture_storage_2d"
        }
    }

    /// The coordinate's component count for sampling and loading.
    var coordinateCount: Int {
        switch self {
        case .texture1d, .texture1dArray: return 1
        case .texture3d, .textureCube, .textureCubeArray, .depthCube: return 3
        default: return 2
        }
    }

    var isArray: Bool {
        switch self {
        case .texture1dArray, .texture2dArray, .textureCubeArray, .depth2dArray: return true
        default: return false
        }
    }
}

public enum ShaderTextureAccess: String, Hashable, Sendable {
    case sample, read, write, readWrite
}

public indirect enum ShaderType: Hashable, Sendable, CustomStringConvertible {
    case void
    case scalar(ShaderScalar)
    case vector(ShaderScalar, Int)
    case matrix(columns: Int, rows: Int)
    case structure(String)
    /// `count` nil: a buffer's runtime-sized array.
    case array(ShaderType, Int?)
    case texture(ShaderTextureKind, ShaderScalar, ShaderTextureAccess)
    case sampler
    case atomic(ShaderScalar)
    /// A reference or pointer (an address space: function, private,
    /// workgroup, storage, uniform).
    case pointer(ShaderType, String)

    public var description: String { wgsl }

    var wgsl: String {
        switch self {
        case .void: return "void"
        case .scalar(let s): return s.wgsl
        case .vector(let s, let n): return "vec\(n)<\(s.wgsl)>"
        case .matrix(let c, let r): return "mat\(c)x\(r)<f32>"
        case .structure(let name): return name
        case .array(let element, let count):
            if let count { return "array<\(element.wgsl), \(count)>" }
            return "array<\(element.wgsl)>"
        case .texture(let kind, let scalar, let access):
            switch access {
            case .sample, .read:
                if kind.isDepth { return kind.wgslName }
                return "\(kind.wgslName)<\(scalar.concrete.wgsl)>"
            case .write, .readWrite:
                let format: String
                switch scalar.concrete {
                case .uint: format = "rgba32uint"
                case .int: format = "rgba32sint"
                default: format = "rgba8unorm"
                }
                return "\(kind.storageName)<\(format), \(access == .write ? "write" : "read_write")>"
            }
        case .sampler: return "sampler"
        case .atomic(let s): return "atomic<\(s.wgsl)>"
        case .pointer(let pointee, let space): return "ptr<\(space), \(pointee.wgsl)>"
        }
    }

    var scalar: ShaderScalar? {
        switch self {
        case .scalar(let s), .vector(let s, _): return s
        case .matrix: return .float
        default: return nil
        }
    }

    var componentCount: Int {
        switch self {
        case .scalar: return 1
        case .vector(_, let n): return n
        default: return 0
        }
    }

    var isNumeric: Bool {
        switch self {
        case .scalar(let s), .vector(let s, _): return s != .bool
        case .matrix: return true
        default: return false
        }
    }

    var isAbstract: Bool { scalar?.isAbstract ?? false }

    /// The same shape with another element type.
    func with(scalar newScalar: ShaderScalar) -> ShaderType {
        switch self {
        case .scalar: return .scalar(newScalar)
        case .vector(_, let n): return .vector(newScalar, n)
        default: return self
        }
    }

    /// Abstract literals made concrete.
    var concrete: ShaderType {
        switch self {
        case .scalar(let s): return .scalar(s.concrete)
        case .vector(let s, let n): return .vector(s.concrete, n)
        default: return self
        }
    }
}

/// MSL's memory layout of a type: size and alignment in bytes. Nil for a type
/// that cannot be in a buffer.
func mslLayout(_ type: ShaderType, structs: [String: [(String, ShaderType)]]) -> (size: Int, alignment: Int)? {
    switch type {
    case .scalar(let s):
        return s == .bool ? (1, 1) : (4, 4)
    case .vector(let s, let n):
        if s == .bool { return nil }
        switch n {
        case 2: return (8, 8)
        default: return (16, 16)
        }
    case .matrix(let c, let r):
        let column = r == 2 ? 8 : 16
        return (column * c, column)
    case .array(let element, let count):
        guard let (size, alignment) = mslLayout(element, structs: structs) else { return nil }
        let stride = roundUp(size, alignment)
        return (stride * (count ?? 1), alignment)
    case .structure(let name):
        guard let fields = structs[name] else { return nil }
        var offset = 0
        var alignment = 1
        for (_, fieldType) in fields {
            guard let (size, fieldAlignment) = mslLayout(fieldType, structs: structs) else { return nil }
            offset = roundUp(offset, fieldAlignment) + size
            alignment = max(alignment, fieldAlignment)
        }
        return (roundUp(offset, alignment), alignment)
    case .atomic:
        return (4, 4)
    default:
        return nil
    }
}

/// WGSL's size of a type, where it differs from MSL's only for 3-vectors.
func wgslSize(_ type: ShaderType) -> Int? {
    switch type {
    case .vector(_, 3): return 12
    default: return nil
    }
}

func roundUp(_ value: Int, _ alignment: Int) -> Int {
    (value + alignment - 1) / alignment * alignment
}

/// Resolves an MSL type name to a shader type.
func resolveMSLType(_ spec: MSLTypeSpec, structs: Set<String>) throws -> ShaderType {
    var name = spec.name
    if name.hasPrefix("packed_") {
        throw MSLTranslationError("packed vector types (\(name)) are not supported yet")
    }
    switch name {
    case "void": return .void
    case "bool": return .scalar(.bool)
    case "int", "short", "char", "int32_t", "int16_t", "int8_t", "long", "int64_t", "ptrdiff_t":
        return .scalar(.int)
    case "uint", "ushort", "uchar", "uint32_t", "uint16_t", "uint8_t", "ulong", "uint64_t", "size_t":
        return .scalar(.uint)
    case "float", "half", "double": return .scalar(.float)
    case "sampler": return .sampler
    case "atomic_int": return .atomic(.int)
    case "atomic_uint": return .atomic(.uint)
    default: break
    }
    if structs.contains(name) { return .structure(name) }
    if let kind = textureKind(name) {
        var scalar: ShaderScalar = .float
        var access: ShaderTextureAccess = .sample
        if let first = spec.templateArguments.first {
            switch first {
            case "float", "half": scalar = .float
            case "int", "short": scalar = .int
            case "uint", "ushort": scalar = .uint
            default: break
            }
        }
        if spec.templateArguments.count > 1 {
            let accessName = spec.templateArguments[1].replacingOccurrences("access::", "")
            switch accessName {
            case "sample": access = .sample
            case "read": access = .read
            case "write": access = .write
            case "read_write": access = .readWrite
            default: throw MSLTranslationError("texture access '\(accessName)' is not supported")
            }
        }
        return .texture(kind, scalar, access)
    }
    if name == "array", spec.templateArguments.count == 2, let count = Int(spec.templateArguments[1]) {
        let element = try resolveMSLType(MSLTypeSpec(name: spec.templateArguments[0]), structs: structs)
        return .array(element, count)
    }
    if name == "atomic", let first = spec.templateArguments.first {
        return .atomic(first == "uint" ? .uint : .int)
    }
    // Vectors and matrices: float4, uint2, half3x3…
    for (prefix, scalar) in [("bool", ShaderScalar.bool), ("uchar", .uint), ("char", .int), ("ushort", .uint), ("short", .int),
                             ("uint", .uint), ("int", .int), ("half", .float), ("float", .float)] where name.hasPrefix(prefix) {
        name.removeFirst(prefix.count)
        if let n = Int(name), (2...4).contains(n) { return .vector(scalar, n) }
        if name.count == 3, name.dropFirst().first == "x", let c = Int(String(name.first!)), let r = Int(String(name.last!)),
           (2...4).contains(c), (2...4).contains(r), scalar == .float {
            return .matrix(columns: c, rows: r)
        }
        break
    }
    throw MSLTranslationError("unknown type '\(spec.description)'")
}

func textureKind(_ name: String) -> ShaderTextureKind? {
    switch name {
    case "texture1d": return .texture1d
    case "texture1d_array": return .texture1dArray
    case "texture2d": return .texture2d
    case "texture2d_array": return .texture2dArray
    case "texture2d_ms": return .texture2dMS
    case "texture3d": return .texture3d
    case "texturecube": return .textureCube
    case "texturecube_array": return .textureCubeArray
    case "depth2d": return .depth2d
    case "depth2d_array": return .depth2dArray
    case "depth2d_ms": return .depth2dMS
    case "depthcube": return .depthCube
    default: return nil
    }
}

extension String {
    func replacingOccurrences(_ target: String, _ replacement: String) -> String {
        guard !target.isEmpty else { return self }
        var result = ""
        var rest = Substring(self)
        while let range = rest.range(of: target) {
            result += rest[rest.startIndex..<range.lowerBound]
            result += replacement
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

extension Substring {
    func range(of target: String) -> Range<Substring.Index>? {
        guard !target.isEmpty, count >= target.count else { return nil }
        var start = startIndex
        while start < endIndex {
            if self[start...].hasPrefix(target) {
                return start..<index(start, offsetBy: target.count)
            }
            start = index(after: start)
        }
        return nil
    }
}
