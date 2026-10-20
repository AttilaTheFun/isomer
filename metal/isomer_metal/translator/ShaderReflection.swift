// What a translated entry point needs from its pipeline: its WGSL, and the
// resources it binds (where Metal's indices went in WGSL's groups and
// bindings), its vertex inputs, its fragment outputs.
//
// Binding scheme (one WGSL module per entry point):
//   group 0: a vertex or kernel function's resources, group 1: a fragment
//   function's; within a group, buffer(n) at binding n, texture(n) at
//   32 + n, sampler(n) at 64 + n, constexpr samplers at 96 + i.
//   A kernel that reads its thread position in the grid gets the grid's
//   size at group 1, binding 0, and stops threads beyond it (Metal's
//   dispatchThreads runs only the grid's threads).

public enum ShaderBindingKind: Hashable, Sendable {
    case uniform
    case storageRead
    case storageReadWrite
    case texture(ShaderTextureKind, ShaderScalar)
    case storageTexture(ShaderTextureKind, format: String, access: String)
    case sampler(comparison: Bool)
    /// A `constexpr sampler` declared in the shader: the executor makes it.
    case inlineSampler(ShaderInlineSampler)
    /// The grid's size in threads (vec3<u32>), for a kernel.
    case gridSize
}

public struct ShaderInlineSampler: Hashable, Sendable {
    public var minFilter = "nearest"
    public var magFilter = "nearest"
    public var mipFilter = "nearest"
    public var addressU = "clamp-to-edge"
    public var addressV = "clamp-to-edge"
    public var addressW = "clamp-to-edge"
    public var compare: String?
}

public struct ShaderBinding: Hashable, Sendable {
    public var group: Int
    public var binding: Int
    public var kind: ShaderBindingKind
    /// Metal's index for the resource (buffer(n), texture(n), sampler(n));
    /// -1 for what the shader makes itself.
    public var metalIndex: Int
    public var name: String
}

public struct ShaderVertexInput: Hashable, Sendable {
    /// `[[attribute(n)]]`: the WGSL location and the vertex descriptor's
    /// attribute index.
    public var location: Int
    public var type: ShaderType
}

public struct TranslatedEntryPoint: Sendable {
    public var stage: MSLStage
    /// The function's name in the source.
    public var name: String
    /// Its name in the WGSL (the same unless it collided with a WGSL word).
    public var entryName: String
    public var wgsl: String
    public var bindings: [ShaderBinding]
    public var vertexInputs: [ShaderVertexInput]
    /// The color attachments a fragment function writes.
    public var fragmentOutputs: [Int]
    /// A kernel's workgroup size comes from the dispatch (WGSL overrides
    /// `_isomer_wg_x`, `_isomer_wg_y`, `_isomer_wg_z`).
    public var usesWorkgroupOverrides: Bool

    /// The reflection as JSON, for the WebGPU executor.
    public var reflectionJSON: String {
        var parts: [String] = []
        parts.append("\"stage\":\"\(stage.rawValue)\"")
        parts.append("\"entry\":\(jsonString(entryName))")
        var bindingParts: [String] = []
        for binding in bindings {
            var fields = ["\"group\":\(binding.group)", "\"binding\":\(binding.binding)",
                          "\"index\":\(binding.metalIndex)", "\"name\":\(jsonString(binding.name))"]
            switch binding.kind {
            case .uniform: fields.append("\"kind\":\"uniform\"")
            case .storageRead: fields.append("\"kind\":\"read-only-storage\"")
            case .storageReadWrite: fields.append("\"kind\":\"storage\"")
            case .texture(let kind, let scalar):
                fields.append("\"kind\":\"texture\"")
                fields.append("\"dimension\":\"\(kind.rawValue)\"")
                fields.append("\"sampleType\":\"\(kind.isDepth ? "depth" : scalar.concrete == .float ? "float" : scalar.concrete == .uint ? "uint" : "sint")\"")
            case .storageTexture(let kind, let format, let access):
                fields.append("\"kind\":\"storage-texture\"")
                fields.append("\"dimension\":\"\(kind.rawValue)\"")
                fields.append("\"format\":\"\(format)\"")
                fields.append("\"access\":\"\(access)\"")
            case .sampler(let comparison):
                fields.append("\"kind\":\"\(comparison ? "comparison-sampler" : "sampler")\"")
            case .inlineSampler(let s):
                fields.append("\"kind\":\"inline-sampler\"")
                var sampler = ["\"minFilter\":\"\(s.minFilter)\"", "\"magFilter\":\"\(s.magFilter)\"",
                               "\"mipmapFilter\":\"\(s.mipFilter)\"", "\"addressModeU\":\"\(s.addressU)\"",
                               "\"addressModeV\":\"\(s.addressV)\"", "\"addressModeW\":\"\(s.addressW)\""]
                if let compare = s.compare { sampler.append("\"compare\":\"\(compare)\"") }
                fields.append("\"sampler\":{\(sampler.joined(separator: ","))}")
            case .gridSize:
                fields.append("\"kind\":\"grid\"")
            }
            bindingParts.append("{\(fields.joined(separator: ","))}")
        }
        parts.append("\"bindings\":[\(bindingParts.joined(separator: ","))]")
        parts.append("\"vertexInputs\":[\(vertexInputs.map { "{\"location\":\($0.location),\"type\":\(jsonString($0.type.wgsl))}" }.joined(separator: ","))]")
        parts.append("\"fragmentOutputs\":[\(fragmentOutputs.map(String.init).joined(separator: ","))]")
        parts.append("\"workgroupOverrides\":\(usesWorkgroupOverrides)")
        return "{\(parts.joined(separator: ","))}"
    }
}

func jsonString(_ text: String) -> String {
    var out = "\""
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if scalar.value < 0x20 {
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out + "\""
}
