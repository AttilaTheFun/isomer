// The shader translator's back end: one MSL entry point (with the structs,
// helper functions and constants it uses) to one WGSL module.
//
// Expressions are typed as they are written out, so the conversions MSL
// makes implicitly (an int where a float is wanted, a scalar where a vector
// is, a number as a condition) are written explicitly, as WGSL requires;
// literals stay abstract, as WGSL's are. Where WGSL has no direct
// counterpart the generator rewrites: a multi-component swizzle assigned to
// is assigned component by component, a parameter the function changes is
// copied into a variable, `?:` becomes `select`, a do loop a `loop`.

final class WGSLGenerator {
    private struct Variable {
        var name: String
        var type: ShaderType
        /// A reference (`device Foo& p = …`, a `thread T&` parameter):
        /// read through `(*name)`.
        var isPointer = false
        /// A buffer bound as an array: `*p` and `p->` read element 0.
        var isBufferArray = false
    }

    private struct FunctionSignature {
        var name: String
        var parameterTypes: [ShaderType]
        var parameterIsReference: [Bool]
        var returnType: ShaderType
    }

    private let unit: MSLTranslationUnit
    private let entry: MSLFunction
    private let stage: MSLStage
    private let structNames: Set<String>
    private var structFields: [String: [(name: String, type: ShaderType, field: MSLStructField)]] = [:]

    private var scopes: [[String: Variable]] = [[:]]
    private var usedNames: Set<String> = []
    private var temporaryCounter = 0

    private var emittedStructs: [String] = []
    private var structDecorations: [String: [String: String]] = [:]
    private var bufferStructs: Set<String> = []
    private var emittedFunctions: [String: FunctionSignature] = [:]
    private var functionOrder: [String] = []
    private var functionCode: [String: String] = [:]
    private var functionsInProgress: Set<String> = []
    private var globalLines: [String] = []
    private var emittedGlobals: Set<String> = []
    private var bindingLines: [String] = []
    private var bindings: [ShaderBinding] = []
    private var inlineSamplerCount = 0
    private var workgroupLines: [String] = []
    private var vertexInputs: [ShaderVertexInput] = []
    private var fragmentOutputs: [Int] = []
    private var usesGrid = false
    private var usesWorkgroupOverrides = false
    /// The function being written: its return type, for `return`.
    private var currentReturnType: ShaderType = .void
    private var currentIsEntry = false

    init(unit: MSLTranslationUnit, entry: MSLFunction) throws {
        guard let stage = entry.stage else {
            throw MSLTranslationError("'\(entry.name)' is not a vertex, fragment or kernel function", at: entry.location)
        }
        self.unit = unit
        self.entry = entry
        self.stage = stage
        structNames = Set(unit.structs.map(\.name))
        for s in unit.structs {
            var fields: [(name: String, type: ShaderType, field: MSLStructField)] = []
            for field in s.fields {
                var type = try resolve(field.type, at: field.location)
                if let size = field.arraySize {
                    type = .array(type, try constantInteger(size))
                }
                fields.append((field.name, type, field))
            }
            structFields[s.name] = fields
        }
    }

    // MARK: Module

    func generate() throws -> TranslatedEntryPoint {
        let entryCode = try emitEntry()
        var lines: [String] = []
        lines.append("// Translated by Isomer from the Metal shading language: '\(entry.name)'.")
        for name in emittedStructs {
            lines.append(structDeclaration(name))
        }
        lines.append(contentsOf: globalLines)
        lines.append(contentsOf: workgroupLines)
        lines.append(contentsOf: bindingLines)
        if usesWorkgroupOverrides {
            lines.append("override _isomer_wg_x: u32 = 1;")
            lines.append("override _isomer_wg_y: u32 = 1;")
            lines.append("override _isomer_wg_z: u32 = 1;")
        }
        for name in functionOrder {
            if let code = functionCode[name] { lines.append(code) }
        }
        lines.append(entryCode)
        return TranslatedEntryPoint(
            stage: stage, name: entry.name, entryName: wgslIdentifier(entry.name, declare: false),
            wgsl: lines.joined(separator: "\n") + "\n", bindings: bindings, vertexInputs: vertexInputs,
            fragmentOutputs: fragmentOutputs, usesWorkgroupOverrides: usesWorkgroupOverrides)
    }

    // MARK: Types and names

    private func resolve(_ spec: MSLTypeSpec, at location: MSLSourceLocation) throws -> ShaderType {
        do {
            return try resolveMSLType(spec, structs: structNames)
        } catch var error as MSLTranslationError {
            error.location = error.location ?? location
            throw error
        }
    }

    private func useType(_ type: ShaderType) {
        switch type {
        case .structure(let name):
            guard !emittedStructs.contains(name), let fields = structFields[name] else { return }
            for field in fields { useType(field.type) }
            emittedStructs.append(name)
        case .array(let element, _): useType(element)
        case .pointer(let pointee, _): useType(pointee)
        default: break
        }
    }

    private func structDeclaration(_ name: String) -> String {
        let decorations = structDecorations[name] ?? [:]
        var lines = ["struct \(name) {"]
        for field in structFields[name] ?? [] {
            var attributes = decorations[field.name] ?? ""
            if bufferStructs.contains(name), let wgslSize = wgslSize(field.type),
               let (mslSize, _) = mslLayout(field.type, structs: structFieldTypes), mslSize != wgslSize {
                attributes += "@size(\(mslSize)) "
            }
            lines.append("    \(attributes)\(wgslIdentifier(field.name, declare: false)): \(field.type.wgsl),")
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    private var structFieldTypes: [String: [(String, ShaderType)]] {
        structFields.mapValues { $0.map { ($0.name, $0.type) } }
    }

    private func markBufferStruct(_ type: ShaderType) {
        switch type {
        case .structure(let name):
            if bufferStructs.insert(name).inserted {
                for field in structFields[name] ?? [] { markBufferStruct(field.type) }
            }
        case .array(let element, _): markBufferStruct(element)
        default: break
        }
    }

    /// WGSL words an identifier must not be, and the names of WGSL's types
    /// and built-in functions (shadowing one would hide it).
    private static let reserved: Set<String> = [
        "alias", "break", "case", "const", "const_assert", "continue", "continuing", "default", "diagnostic",
        "discard", "else", "enable", "false", "fn", "for", "if", "let", "loop", "override", "requires", "return",
        "struct", "switch", "true", "var", "while", "NULL", "Self", "abstract", "active", "alignas", "alignof",
        "as", "asm", "asm_fragment", "async", "attribute", "auto", "await", "become", "binding_array", "cast",
        "catch", "class", "co_await", "co_return", "co_yield", "coherent", "column_major", "common", "compile",
        "compile_fragment", "concept", "const_cast", "consteval", "constexpr", "constinit", "crate", "debugger",
        "decltype", "delete", "demote", "demote_to_helper", "do", "dynamic_cast", "enum", "explicit", "export",
        "extends", "extern", "external", "fallthrough", "filter", "final", "finally", "friend", "from", "fxgroup",
        "get", "goto", "groupshared", "highp", "impl", "implements", "import", "inline", "instanceof", "interface",
        "layout", "lowp", "macro", "macro_rules", "match", "mediump", "meta", "mod", "module", "move", "mut",
        "mutable", "namespace", "new", "nil", "noexcept", "noinline", "nointerpolation", "noperspective", "null",
        "nullptr", "of", "operator", "package", "packoffset", "partition", "pass", "patch", "pixelfragment",
        "precise", "precision", "premerge", "priv", "protected", "pub", "public", "readonly", "ref", "regardless",
        "register", "reinterpret_cast", "require", "resource", "restrict", "self", "set", "shared", "sizeof",
        "smooth", "snorm", "static", "static_assert", "static_cast", "std", "subroutine", "super", "target",
        "template", "this", "thread_local", "throw", "trait", "try", "type", "typedef", "typeid", "typename",
        "typeof", "union", "unless", "unorm", "unsafe", "unsized", "use", "using", "varying", "virtual",
        "volatile", "wgsl", "where", "with", "writeonly", "yield",
        "bool", "f16", "f32", "i32", "u32", "vec2", "vec3", "vec4", "mat2x2", "mat2x3", "mat2x4", "mat3x2",
        "mat3x3", "mat3x4", "mat4x2", "mat4x3", "mat4x4", "array", "atomic", "ptr", "sampler",
        "sampler_comparison", "texture_1d", "texture_2d", "texture_2d_array", "texture_3d", "texture_cube",
        "texture_cube_array", "texture_multisampled_2d", "texture_depth_2d", "texture_depth_2d_array",
        "texture_depth_cube", "texture_depth_cube_array", "texture_depth_multisampled_2d",
        "texture_storage_1d", "texture_storage_2d", "texture_storage_2d_array", "texture_storage_3d",
        "abs", "acos", "acosh", "all", "any", "asin", "asinh", "atan", "atan2", "atanh", "bitcast", "ceil",
        "clamp", "cos", "cosh", "cross", "degrees", "determinant", "distance", "dot", "dpdx", "dpdy", "exp",
        "exp2", "faceForward", "floor", "fma", "fract", "length", "log", "log2", "max", "min", "mix", "modf",
        "normalize", "pow", "radians", "reflect", "refract", "round", "saturate", "select", "sign", "sin",
        "sinh", "smoothstep", "sqrt", "step", "tan", "tanh", "transpose", "trunc", "textureSample",
        "textureLoad", "textureStore", "textureDimensions", "workgroupBarrier", "storageBarrier",
    ]

    private func wgslIdentifier(_ name: String, declare: Bool) -> String {
        var result = name
        if WGSLGenerator.reserved.contains(result) || result.hasPrefix("__") { result = "m_" + result }
        return result
    }

    private func declareLocal(_ name: String, type: ShaderType, isPointer: Bool = false, isBufferArray: Bool = false) -> String {
        var wgsl = wgslIdentifier(name, declare: true)
        if scopes.last?[name] != nil || usedNames.contains(wgsl) && scopes.count == 1 {
            temporaryCounter += 1
            wgsl += "_\(temporaryCounter)"
        }
        usedNames.insert(wgsl)
        scopes[scopes.count - 1][name] = Variable(name: wgsl, type: type, isPointer: isPointer, isBufferArray: isBufferArray)
        return wgsl
    }

    private func lookup(_ name: String) -> Variable? {
        for scope in scopes.reversed() {
            if let variable = scope[name] { return variable }
        }
        return nil
    }

    private func temporary() -> String {
        temporaryCounter += 1
        return "_isomer_t\(temporaryCounter)"
    }

    // MARK: Entry point

    private func emitEntry() throws -> String {
        currentIsEntry = true
        let entryName = wgslIdentifier(entry.name, declare: false)
        var parameters: [String] = []
        var prologue: [String] = []
        let group = stage == .fragment ? 1 : 0
        scopes = [[:]]
        let mutated = mutatedNames(in: entry.body)
        var hasGlobalID = false

        for parameter in entry.parameters {
            let attributes = Dictionary(parameter.attributes.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            let type = try resolve(parameter.type, at: parameter.location)
            if let attribute = attributes["buffer"] {
                guard let index = attribute.integerArgument else {
                    throw MSLTranslationError("buffer(…) needs a number", at: parameter.location)
                }
                try bindBuffer(parameter, type: type, index: index, group: group, mutated: mutated)
                continue
            }
            if let attribute = attributes["texture"] {
                guard let index = attribute.integerArgument, case .texture(let kind, let scalar, let access) = type else {
                    throw MSLTranslationError("texture(…) on a parameter that is not a texture", at: parameter.location)
                }
                let name = declareLocal(parameter.name, type: type)
                let binding = 32 + index
                bindingLines.append("@group(\(group)) @binding(\(binding)) var \(name): \(type.wgsl);")
                let kindValue: ShaderBindingKind
                switch access {
                case .sample, .read: kindValue = .texture(kind, scalar)
                case .write, .readWrite:
                    let format = type.wgsl.split(separator: "<").last?.split(separator: ",").first.map(String.init) ?? "rgba8unorm"
                    kindValue = .storageTexture(kind, format: format, access: access == .write ? "write-only" : "read-write")
                }
                bindings.append(ShaderBinding(group: group, binding: binding, kind: kindValue, metalIndex: index, name: name))
                continue
            }
            if let attribute = attributes["sampler"] {
                guard let index = attribute.integerArgument else {
                    throw MSLTranslationError("sampler(…) needs a number", at: parameter.location)
                }
                let name = declareLocal(parameter.name, type: .sampler)
                let binding = 64 + index
                bindingLines.append("@group(\(group)) @binding(\(binding)) var \(name): sampler;")
                bindings.append(ShaderBinding(group: group, binding: binding, kind: .sampler(comparison: false), metalIndex: index, name: name))
                continue
            }
            if attributes["stage_in"] != nil {
                guard case .structure(let structName) = type else {
                    throw MSLTranslationError("[[stage_in]] on a parameter that is not a struct", at: parameter.location)
                }
                useType(type)
                if stage == .vertex {
                    try decorateVertexInput(structName)
                } else {
                    decorateVarying(structName, fragment: true)
                }
                let name = declareParameter(parameter.name, type: type, mutated: mutated, prologue: &prologue)
                parameters.append("\(name): \(type.wgsl)")
                continue
            }
            if let builtin = try builtinParameter(attributes, type: type, at: parameter.location) {
                let wgslType = builtin.type
                if builtin.name.hasPrefix("_isomer_") {
                    // The grid's or the threadgroup's size: what the
                    // dispatch said, not a WGSL builtin.
                    let source = builtin.name == "_isomer_grid" ? "_isomer_grid" : "vec3<u32>(_isomer_wg_x, _isomer_wg_y, _isomer_wg_z)"
                    let name = declareLocal(parameter.name, type: type)
                    prologue.append("let \(name): \(type.wgsl) = \(convert("\(source)\(builtin.extract)", from: builtin.extractedType, to: type));")
                    continue
                }
                if builtin.name == "global_invocation_id" {
                    usesGrid = true
                    hasGlobalID = true
                    parameters.append("@builtin(global_invocation_id) _isomer_global_invocation_id: vec3<u32>")
                    let name = declareLocal(parameter.name, type: type)
                    prologue.append("\(mutated.contains(parameter.name) ? "var" : "let") \(name): \(type.wgsl) = \(convert("_isomer_global_invocation_id\(builtin.extract)", from: builtin.extractedType, to: type));")
                    continue
                }
                if builtin.extract.isEmpty && wgslType == type {
                    let name = declareParameter(parameter.name, type: type, mutated: mutated, prologue: &prologue)
                    parameters.append("@builtin(\(builtin.name)) \(name): \(wgslType.wgsl)")
                } else {
                    let raw = "_isomer_\(builtin.name)"
                    parameters.append("@builtin(\(builtin.name)) \(raw): \(wgslType.wgsl)")
                    let name = declareLocal(parameter.name, type: type)
                    prologue.append("\(mutated.contains(parameter.name) ? "var" : "let") \(name): \(type.wgsl) = \(convert("\(raw)\(builtin.extract)", from: builtin.extractedType, to: type));")
                }
                continue
            }
            if stage == .kernel, parameter.type.addressSpace == "threadgroup" {
                // `threadgroup float *shared [[threadgroup(0)]]`: memory the
                // dispatch sizes; WGSL wants it sized in the shader.
                throw MSLTranslationError("threadgroup memory set by the encoder is not supported; declare it in the kernel with a size", at: parameter.location)
            }
            throw MSLTranslationError("parameter '\(parameter.name)' has no attribute saying where it comes from", at: parameter.location)
        }

        if stage == .kernel {
            usesWorkgroupOverrides = true
            if usesGrid && !hasGlobalID {
                parameters.append("@builtin(global_invocation_id) _isomer_global_invocation_id: vec3<u32>")
            }
            if usesGrid {
                bindingLines.append("@group(1) @binding(0) var<uniform> _isomer_grid: vec3<u32>;")
                bindings.append(ShaderBinding(group: 1, binding: 0, kind: .gridSize, metalIndex: -1, name: "_isomer_grid"))
                prologue.insert("if (any(_isomer_global_invocation_id >= _isomer_grid)) { return; }", at: 0)
            }
        }

        // The return type and its decoration.
        let returnType = try resolve(entry.returnType, at: entry.location)
        currentReturnType = returnType
        var returnClause = ""
        switch stage {
        case .vertex:
            if case .structure(let name) = returnType {
                useType(returnType)
                decorateVarying(name, fragment: false)
                returnClause = " -> \(name)"
            } else if returnType == .vector(.float, 4) {
                returnClause = " -> @builtin(position) vec4<f32>"
            } else if returnType != .void {
                throw MSLTranslationError("a vertex function returns a position or a struct", at: entry.location)
            }
        case .fragment:
            if case .structure(let name) = returnType {
                useType(returnType)
                try decorateFragmentOutput(name)
                returnClause = " -> \(name)"
            } else if returnType != .void {
                let type = returnType.concrete
                fragmentOutputs = [0]
                returnClause = " -> @location(0) \(type.wgsl)"
            }
        case .kernel:
            if returnType != .void {
                throw MSLTranslationError("a kernel returns void", at: entry.location)
            }
        }

        let body = try emitBlockBody(entry.body, indent: "    ")
        var attributes = "@\(stage == .kernel ? "compute" : stage.rawValue)"
        if stage == .kernel {
            attributes += " @workgroup_size(_isomer_wg_x, _isomer_wg_y, _isomer_wg_z)"
        }
        var code = "\(attributes)\nfn \(entryName)(\(parameters.joined(separator: ", ")))\(returnClause) {\n"
        for line in prologue { code += "    \(line)\n" }
        code += body
        code += "}"
        return code
    }

    private func declareParameter(_ name: String, type: ShaderType, mutated: Set<String>, prologue: inout [String]) -> String {
        if mutated.contains(name) {
            let raw = wgslIdentifier(name, declare: true) + "_in"
            let local = declareLocal(name, type: type)
            prologue.append("var \(local): \(type.wgsl) = \(raw);")
            return raw
        }
        return declareLocal(name, type: type)
    }

    private func bindBuffer(_ parameter: MSLParameter, type: ShaderType, index: Int, group: Int, mutated: Set<String>) throws {
        let binding = index
        let space = parameter.type.addressSpace ?? (parameter.type.isConst ? "constant" : "device")
        let writable = space == "device" && !parameter.type.isConst
        if writable && stage == .vertex {
            throw MSLTranslationError("a vertex function cannot write a buffer on the web (WebGPU); make '\(parameter.name)' const", at: parameter.location)
        }
        let access = writable ? "read_write" : "read"
        markBufferStruct(type)
        useType(type)
        if parameter.isPointer {
            let element = type
            let name = declareLocal(parameter.name, type: .array(element, nil), isBufferArray: true)
            bindingLines.append("@group(\(group)) @binding(\(binding)) var<storage, \(access)> \(name): array<\(element.wgsl)>;")
        } else {
            let name = declareLocal(parameter.name, type: type)
            bindingLines.append("@group(\(group)) @binding(\(binding)) var<storage, \(access)> \(name): \(type.wgsl);")
        }
        bindings.append(ShaderBinding(
            group: group, binding: binding, kind: writable ? .storageReadWrite : .storageRead,
            metalIndex: index, name: wgslIdentifier(parameter.name, declare: false)))
    }

    private struct Builtin {
        var name: String
        var type: ShaderType
        /// How the parameter's value is read from the builtin (".xy").
        var extract = ""
        var extractedType: ShaderType
    }

    private func builtinParameter(_ attributes: [String: MSLAttribute], type: ShaderType, at location: MSLSourceLocation) throws -> Builtin? {
        func vectorBuiltin(_ name: String) -> Builtin {
            let full = ShaderType.vector(.uint, 3)
            switch type.componentCount {
            case 1: return Builtin(name: name, type: full, extract: ".x", extractedType: .scalar(.uint))
            case 2: return Builtin(name: name, type: full, extract: ".xy", extractedType: .vector(.uint, 2))
            default: return Builtin(name: name, type: full, extract: "", extractedType: full)
            }
        }
        if attributes["vertex_id"] != nil { return Builtin(name: "vertex_index", type: .scalar(.uint), extractedType: .scalar(.uint)) }
        if attributes["instance_id"] != nil { return Builtin(name: "instance_index", type: .scalar(.uint), extractedType: .scalar(.uint)) }
        if attributes["position"] != nil, stage == .fragment {
            return Builtin(name: "position", type: .vector(.float, 4), extractedType: .vector(.float, 4))
        }
        if attributes["front_facing"] != nil { return Builtin(name: "front_facing", type: .scalar(.bool), extractedType: .scalar(.bool)) }
        if attributes["sample_id"] != nil { return Builtin(name: "sample_index", type: .scalar(.uint), extractedType: .scalar(.uint)) }
        if attributes["thread_position_in_grid"] != nil { return vectorBuiltin("global_invocation_id") }
        if attributes["thread_position_in_threadgroup"] != nil { return vectorBuiltin("local_invocation_id") }
        if attributes["threadgroup_position_in_grid"] != nil { return vectorBuiltin("workgroup_id") }
        if attributes["threadgroups_per_grid"] != nil { return vectorBuiltin("num_workgroups") }
        if attributes["threads_per_grid"] != nil {
            usesGrid = true
            return Builtin(name: "_isomer_grid", type: .vector(.uint, 3), extract: type.componentCount == 1 ? ".x" : type.componentCount == 2 ? ".xy" : "",
                           extractedType: type.componentCount == 1 ? .scalar(.uint) : .vector(.uint, max(type.componentCount, 2)))
        }
        if attributes["threads_per_threadgroup"] != nil {
            return Builtin(name: "_isomer_workgroup_size", type: .vector(.uint, 3), extract: type.componentCount == 1 ? ".x" : type.componentCount == 2 ? ".xy" : "",
                           extractedType: type.componentCount == 1 ? .scalar(.uint) : .vector(.uint, max(type.componentCount, 2)))
        }
        if attributes["thread_index_in_threadgroup"] != nil {
            return Builtin(name: "local_invocation_index", type: .scalar(.uint), extractedType: .scalar(.uint))
        }
        if let attribute = attributes.keys.first {
            if ["base_vertex", "base_instance", "amplification_id", "point_coord", "primitive_id", "barycentric_coord",
                "thread_index_in_simdgroup", "simdgroup_index_in_threadgroup", "threads_per_simdgroup"].contains(attribute) {
                throw MSLTranslationError("[[\(attribute)]] is not supported on the web (WebGPU)", at: location)
            }
        }
        return nil
    }

    private func decorateVertexInput(_ structName: String) throws {
        var decorations: [String: String] = [:]
        for field in structFields[structName] ?? [] {
            guard let attribute = field.field.attributes.first(where: { $0.name == "attribute" }), let location = attribute.integerArgument else {
                throw MSLTranslationError("a [[stage_in]] field needs [[attribute(n)]] ('\(field.name)')", at: field.field.location)
            }
            decorations[field.name] = "@location(\(location)) "
            vertexInputs.append(ShaderVertexInput(location: location, type: field.type))
        }
        structDecorations[structName] = decorations
    }

    /// A vertex function's output or a fragment function's input: the
    /// position is the builtin, the rest take locations in field order.
    private func decorateVarying(_ structName: String, fragment: Bool) {
        var decorations: [String: String] = [:]
        var location = 0
        for field in structFields[structName] ?? [] {
            let names = Set(field.field.attributes.map(\.name))
            if names.contains("position") {
                decorations[field.name] = "@builtin(position) "
                continue
            }
            var decoration = "@location(\(location)) "
            location += 1
            if names.contains("flat") || field.type.scalar?.isInteger == true {
                decoration += "@interpolate(flat) "
            } else if names.contains("center_no_perspective") || names.contains("centroid_no_perspective") {
                decoration += "@interpolate(linear) "
            }
            decorations[field.name] = decoration
        }
        structDecorations[structName] = decorations
    }

    private func decorateFragmentOutput(_ structName: String) throws {
        var decorations: [String: String] = [:]
        for field in structFields[structName] ?? [] {
            if let color = field.field.attributes.first(where: { $0.name == "color" }), let index = color.integerArgument {
                decorations[field.name] = "@location(\(index)) "
                fragmentOutputs.append(index)
            } else if field.field.attributes.contains(where: { $0.name == "depth" }) {
                decorations[field.name] = "@builtin(frag_depth) "
            } else {
                throw MSLTranslationError("a fragment function's output field needs [[color(n)]] or [[depth(…)]] ('\(field.name)')", at: field.field.location)
            }
        }
        structDecorations[structName] = decorations
    }

    // MARK: Helper functions and globals

    private func ensureFunction(_ name: String, at location: MSLSourceLocation) throws -> FunctionSignature? {
        if let signature = emittedFunctions[name] { return signature }
        let candidates = unit.functions.filter { $0.name == name && $0.stage == nil }
        guard let function = candidates.first else { return nil }
        if candidates.count > 1 {
            throw MSLTranslationError("overloaded functions ('\(name)') are not supported", at: location)
        }
        if functionsInProgress.contains(name) {
            throw MSLTranslationError("recursion ('\(name)') is not allowed in WGSL", at: location)
        }
        functionsInProgress.insert(name)
        defer { functionsInProgress.remove(name) }

        // Write it in a scope of its own (globals only).
        let savedScopes = scopes
        let savedReturn = currentReturnType
        let savedIsEntry = currentIsEntry
        currentIsEntry = false
        scopes = [scopes.first ?? [:], [:]]
        defer {
            scopes = savedScopes
            currentReturnType = savedReturn
            currentIsEntry = savedIsEntry
        }

        let mutated = mutatedNames(in: function.body)
        var parameters: [String] = []
        var prologue: [String] = []
        var types: [ShaderType] = []
        var references: [Bool] = []
        for parameter in function.parameters {
            var type = try resolve(parameter.type, at: parameter.location)
            if let size = parameter.arraySize { type = .array(type, try constantInteger(size)) }
            useType(type)
            if parameter.isPointer {
                throw MSLTranslationError("pointer parameters ('\(parameter.name)') are not supported; pass a reference or a value", at: parameter.location)
            }
            if parameter.isReference {
                let space = parameter.type.addressSpace ?? "thread"
                guard space == "thread" else {
                    throw MSLTranslationError("references to \(space) memory in a helper's parameters are not supported on the web", at: parameter.location)
                }
                if !mutated.contains(parameter.name) && parameter.type.isConst {
                    let local = declareLocal(parameter.name, type: type)
                    parameters.append("\(local): \(type.wgsl)")
                    references.append(false)
                } else {
                    let local = declareLocal(parameter.name, type: type, isPointer: true)
                    parameters.append("\(local): ptr<function, \(type.wgsl)>")
                    references.append(true)
                }
            } else {
                let local = declareParameter(parameter.name, type: type, mutated: mutated, prologue: &prologue)
                parameters.append("\(local): \(type.wgsl)")
                references.append(false)
            }
            types.append(type)
        }
        let returnType = try resolve(function.returnType, at: function.location)
        useType(returnType)
        currentReturnType = returnType
        let signature = FunctionSignature(
            name: wgslIdentifier(name, declare: false), parameterTypes: types, parameterIsReference: references,
            returnType: returnType)
        emittedFunctions[name] = signature
        let body = try emitBlockBody(function.body, indent: "    ")
        var code = "fn \(signature.name)(\(parameters.joined(separator: ", ")))"
        if returnType != .void { code += " -> \(returnType.concrete.wgsl)" }
        code += " {\n"
        for line in prologue { code += "    \(line)\n" }
        code += body + "}"
        functionCode[name] = code
        functionOrder.append(name)
        return signature
    }

    private func ensureGlobal(_ name: String, at location: MSLSourceLocation) throws -> Variable? {
        if let variable = scopes.first?[name] { return variable }
        guard let global = unit.globals.first(where: { $0.name == name }) else { return nil }
        if global.type.name == "sampler" {
            let sampler = try inlineSampler(global.constructorArguments ?? [], at: global.location)
            return try declareInlineSampler(name, sampler)
        }
        var type = try resolve(global.type, at: global.location)
        if global.arrayUnsized, case .initializerList(let elements) = global.initializer?.kind {
            type = .array(type, elements.count)
        } else if let size = global.arraySize {
            type = .array(type, try constantInteger(size))
        }
        useType(type)
        let wgslName = wgslIdentifier(name, declare: true)
        var initializer = ""
        if let value = global.initializer {
            let (code, valueType) = try emitExpression(value, expected: type)
            initializer = " = " + convert(code, from: valueType, to: type)
        }
        switch type {
        case .array, .structure:
            globalLines.append("var<private> \(wgslName): \(type.wgsl)\(initializer);")
        default:
            if initializer.isEmpty {
                globalLines.append("var<private> \(wgslName): \(type.wgsl);")
            } else {
                globalLines.append("const \(wgslName): \(type.wgsl)\(initializer);")
            }
        }
        let variable = Variable(name: wgslName, type: type)
        scopes[0][name] = variable
        return variable
    }

    private func declareInlineSampler(_ name: String, _ sampler: ShaderInlineSampler) throws -> Variable {
        let group = stage == .fragment ? 1 : 0
        let binding = 96 + inlineSamplerCount
        inlineSamplerCount += 1
        let wgslName = "_isomer_sampler_\(wgslIdentifier(name, declare: false))"
        let type = sampler.compare == nil ? "sampler" : "sampler_comparison"
        bindingLines.append("@group(\(group)) @binding(\(binding)) var \(wgslName): \(type);")
        bindings.append(ShaderBinding(group: group, binding: binding, kind: .inlineSampler(sampler), metalIndex: -1, name: wgslName))
        let variable = Variable(name: wgslName, type: .sampler)
        scopes[0][name] = variable
        return variable
    }

    private func inlineSampler(_ arguments: [MSLExpr], at location: MSLSourceLocation) throws -> ShaderInlineSampler {
        var sampler = ShaderInlineSampler()
        for argument in arguments {
            var parts: [String]
            switch argument.kind {
            case .qualified(let p): parts = p
            case .identifier(let name): parts = [name]
            default: throw MSLTranslationError("a constexpr sampler's arguments are enumerators (filter::linear…)", at: argument.location)
            }
            if parts.first == "metal" { parts.removeFirst() }
            let group = parts.count > 1 ? parts[0] : ""
            let value = parts.last ?? ""
            func address(_ v: String) throws -> String {
                switch v {
                case "clamp_to_edge", "clamp_to_zero", "clamp_to_border": return "clamp-to-edge"
                case "repeat": return "repeat"
                case "mirrored_repeat": return "mirror-repeat"
                default: throw MSLTranslationError("address mode '\(v)' is not supported", at: argument.location)
                }
            }
            switch group {
            case "filter":
                sampler.minFilter = value == "linear" ? "linear" : "nearest"
                sampler.magFilter = sampler.minFilter
            case "mag_filter": sampler.magFilter = value == "linear" ? "linear" : "nearest"
            case "min_filter": sampler.minFilter = value == "linear" ? "linear" : "nearest"
            case "mip_filter": sampler.mipFilter = value == "linear" ? "linear" : "nearest"
            case "address":
                let mode = try address(value)
                sampler.addressU = mode
                sampler.addressV = mode
                sampler.addressW = mode
            case "s_address": sampler.addressU = try address(value)
            case "t_address": sampler.addressV = try address(value)
            case "r_address": sampler.addressW = try address(value)
            case "compare_func":
                let map = ["never": "never", "less": "less", "less_equal": "less-equal", "greater": "greater",
                           "greater_equal": "greater-equal", "equal": "equal", "not_equal": "not-equal", "always": "always"]
                sampler.compare = map[value]
            case "coord":
                if value == "pixel" {
                    throw MSLTranslationError("samplers with pixel coordinates are not supported on the web", at: argument.location)
                }
            default:
                if ["linear", "nearest"].contains(value) {
                    sampler.minFilter = value
                    sampler.magFilter = value
                } else if ["clamp_to_edge", "repeat", "mirrored_repeat"].contains(value) {
                    let mode = try address(value)
                    sampler.addressU = mode
                    sampler.addressV = mode
                    sampler.addressW = mode
                }
            }
        }
        return sampler
    }

    private func constantInteger(_ expression: MSLExpr) throws -> Int {
        switch expression.kind {
        case .integer(let text):
            let digits = text.filter { !"uUlL".contains($0) }
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") {
                if let value = Int(digits.dropFirst(2), radix: 16) { return value }
            } else if let value = Int(digits) {
                return value
            }
        case .identifier(let name):
            if let global = unit.globals.first(where: { $0.name == name }), let value = global.initializer {
                return try constantInteger(value)
            }
        case .binary(let op, let a, let b):
            let x = try constantInteger(a), y = try constantInteger(b)
            switch op {
            case "+": return x + y
            case "-": return x - y
            case "*": return x * y
            case "/": return y == 0 ? 0 : x / y
            default: break
            }
        default: break
        }
        throw MSLTranslationError("an array's size must be a constant integer", at: expression.location)
    }

    // MARK: Statements

    private func emitBlockBody(_ statements: [MSLStmt], indent: String) throws -> String {
        scopes.append([:])
        defer { scopes.removeLast() }
        var code = ""
        for statement in statements {
            code += try emitStatement(statement, indent: indent)
        }
        return code
    }

    private func emitStatement(_ statement: MSLStmt, indent: String) throws -> String {
        switch statement {
        case .empty:
            return ""
        case .block(let statements):
            return "\(indent){\n" + (try emitBlockBody(statements, indent: indent + "    ")) + "\(indent)}\n"
        case .declaration(let declarations):
            var code = ""
            for declaration in declarations {
                code += try emitDeclaration(declaration, indent: indent)
            }
            return code
        case .expression(let expression):
            return try emitExpressionStatement(expression, indent: indent)
        case .ifStmt(let condition, let then, let otherwise):
            var code = "\(indent)if (\(try emitCondition(condition))) {\n"
            code += try emitBranch(then, indent: indent + "    ")
            code += "\(indent)}"
            if let otherwise {
                if case .ifStmt = otherwise {
                    code += " else " + (try emitStatement(otherwise, indent: indent)).drop(while: { $0 == " " })
                    return code
                }
                code += " else {\n" + (try emitBranch(otherwise, indent: indent + "    ")) + "\(indent)}"
            }
            return code + "\n"
        case .whileStmt(let condition, let body):
            return "\(indent)while (\(try emitCondition(condition))) {\n" + (try emitBranch(body, indent: indent + "    ")) + "\(indent)}\n"
        case .doWhile(let body, let condition):
            var code = "\(indent)loop {\n" + (try emitBranch(body, indent: indent + "    "))
            code += "\(indent)    continuing {\n\(indent)        break if !(\(try emitCondition(condition)));\n\(indent)    }\n"
            return code + "\(indent)}\n"
        case .forStmt(let initializer, let condition, let step, let body):
            scopes.append([:])
            defer { scopes.removeLast() }
            var prefix = ""
            var initCode = ""
            if let initializer {
                if case .declaration(let declarations) = initializer, declarations.count == 1 {
                    initCode = try emitDeclaration(declarations[0], indent: "").trimmingNewline()
                    if initCode.hasSuffix(";") { initCode.removeLast() }
                } else {
                    prefix = try emitStatement(initializer, indent: indent + "    ")
                }
            }
            let conditionCode = try condition.map { try emitCondition($0) } ?? ""
            var stepCode = ""
            var stepStatements: [String] = []
            if let step {
                for part in commaParts(step) {
                    stepStatements.append(try emitExpressionStatement(part, indent: "").trimmingNewline())
                }
                if stepStatements.count == 1 {
                    stepCode = stepStatements[0]
                    if stepCode.hasSuffix(";") { stepCode.removeLast() }
                    if stepCode.contains("\n") { stepCode = "" }
                }
            }
            let bodyCode = try emitBranch(body, indent: indent + "    ")
            if stepStatements.count <= 1 && (stepStatements.isEmpty || !stepCode.isEmpty) {
                let loop = "\(indent)for (\(initCode); \(conditionCode); \(stepCode)) {\n" + bodyCode + "\(indent)}\n"
                if prefix.isEmpty { return loop }
                return "\(indent){\n" + prefix + loop.indented(by: "    ") + "\(indent)}\n"
            }
            // A step WGSL's for cannot take (several statements): a loop
            // with a continuing block.
            var code = "\(indent){\n" + prefix
            if !initCode.isEmpty { code += "\(indent)    \(initCode);\n" }
            code += "\(indent)    loop {\n"
            if !conditionCode.isEmpty { code += "\(indent)        if !(\(conditionCode)) { break; }\n" }
            code += bodyCode.indented(by: "    ")
            code += "\(indent)        continuing {\n"
            for statement in stepStatements { code += "\(indent)            \(statement)\n" }
            code += "\(indent)        }\n\(indent)    }\n\(indent)}\n"
            return code
        case .switchStmt(let selector, let cases):
            let (selectorCode, selectorType) = try emitExpression(selector)
            let concrete = selectorType.concrete
            var code = "\(indent)switch (\(convert(selectorCode, from: selectorType, to: concrete))) {\n"
            var pending: [String] = []
            for item in cases {
                var body = item.body
                if let values = item.values {
                    for value in values {
                        let (valueCode, valueType) = try emitExpression(value, expected: concrete)
                        pending.append(convert(valueCode, from: valueType, to: concrete))
                    }
                } else {
                    pending.append("default")
                }
                if body.isEmpty { continue }  // falls into the next case's body
                if case .breakStmt = body.last { body.removeLast() }
                let labels = pending.contains("default") ? "default" : "case " + pending.joined(separator: ", ")
                pending = []
                code += "\(indent)    \(labels): {\n" + (try emitBlockBody(body, indent: indent + "        ")) + "\(indent)    }\n"
            }
            if !cases.contains(where: { $0.values == nil }) {
                code += "\(indent)    default: {}\n"
            }
            return code + "\(indent)}\n"
        case .returnStmt(let value, let location):
            guard let value else { return "\(indent)return;\n" }
            if currentReturnType == .void {
                throw MSLTranslationError("returning a value from a void function", at: location)
            }
            let (code, type) = try emitExpression(value, expected: currentReturnType)
            return "\(indent)return \(convert(code, from: type, to: currentReturnType.concrete));\n"
        case .breakStmt:
            return "\(indent)break;\n"
        case .continueStmt:
            return "\(indent)continue;\n"
        case .discard:
            return "\(indent)discard;\n"
        }
    }

    private func emitBranch(_ statement: MSLStmt, indent: String) throws -> String {
        if case .block(let statements) = statement {
            return try emitBlockBody(statements, indent: indent)
        }
        scopes.append([:])
        defer { scopes.removeLast() }
        return try emitStatement(statement, indent: indent)
    }

    private func commaParts(_ expression: MSLExpr) -> [MSLExpr] {
        if case .binary(",", let a, let b) = expression.kind {
            return commaParts(a) + commaParts(b)
        }
        return [expression]
    }

    private func emitDeclaration(_ declaration: MSLVarDecl, indent: String) throws -> String {
        if declaration.type.name == "sampler", declaration.isConstexpr || declaration.constructorArguments != nil {
            let sampler = try inlineSampler(declaration.constructorArguments ?? [], at: declaration.location)
            let variable = try declareInlineSampler(declaration.name, sampler)
            scopes[scopes.count - 1][declaration.name] = variable
            return ""
        }
        var type = try resolve(declaration.type, at: declaration.location)
        if declaration.arrayUnsized, case .initializerList(let elements) = declaration.initializer?.kind {
            type = .array(type, elements.count)
        } else if let size = declaration.arraySize {
            type = .array(type, try constantInteger(size))
        }
        useType(type)
        if declaration.type.addressSpace == "threadgroup" {
            guard stage == .kernel else {
                throw MSLTranslationError("threadgroup memory outside a kernel", at: declaration.location)
            }
            let name = "_isomer_shared_\(wgslIdentifier(declaration.name, declare: false))"
            workgroupLines.append("var<workgroup> \(name): \(type.wgsl);")
            scopes[scopes.count - 1][declaration.name] = Variable(name: name, type: type)
            return ""
        }
        // A reference: `device Particle &p = particles[id];` is a pointer
        // to the element, read and written through.
        if declaration.isReference {
            guard let value = declaration.initializer else {
                throw MSLTranslationError("a reference needs something to refer to", at: declaration.location)
            }
            let (code, _) = try emitLValue(value)
            let target = code.hasPrefix("(*") && code.hasSuffix(")") ? String(code.dropFirst(2).dropLast()) : "&\(code)"
            let name = declareLocal(declaration.name, type: type, isPointer: true)
            return "\(indent)let \(name) = \(target);\n"
        }
        let isConst = declaration.type.isConst || declaration.isConstexpr
        var initializer = ""
        if let value = declaration.initializer {
            if case .initializerList(let elements) = value.kind {
                initializer = " = " + (try emitAggregate(elements, as: type, at: value.location))
            } else {
                let (code, valueType) = try emitExpression(value, expected: type)
                initializer = " = " + convert(code, from: valueType, to: type)
            }
        }
        let name = declareLocal(declaration.name, type: type)
        if isConst && !initializer.isEmpty {
            return "\(indent)let \(name): \(type.wgsl)\(initializer);\n"
        }
        return "\(indent)var \(name): \(type.wgsl)\(initializer);\n"
    }

    private func emitExpressionStatement(_ expression: MSLExpr, indent: String) throws -> String {
        switch expression.kind {
        case .assign(let op, let target, let value):
            return try emitAssignment(op, target, value, indent: indent)
        case .postfix(let op, let target):
            return try emitIncrement(op, target, at: expression.location, indent: indent)
        case .unary(let op, let target) where op == "++" || op == "--":
            return try emitIncrement(op, target, at: expression.location, indent: indent)
        case .call(let callee, _):
            let (code, type) = try emitExpression(expression)
            if type != .void, case .identifier(let name) = callee.kind, emittedFunctions[name] == nil {
                return "\(indent)_ = \(code);\n"
            }
            return "\(indent)\(code);\n"
        case .binary(",", _, _):
            var code = ""
            for part in commaParts(expression) { code += try emitExpressionStatement(part, indent: indent) }
            return code
        default:
            let (code, _) = try emitExpression(expression)
            return "\(indent)_ = \(code);\n"
        }
    }

    private func emitIncrement(_ op: String, _ target: MSLExpr, at location: MSLSourceLocation, indent: String) throws -> String {
        let (code, type) = try emitLValue(target)
        guard type.isNumeric else {
            throw MSLTranslationError("\(op) on a value that is not a number", at: location)
        }
        return "\(indent)\(code)\(op);\n"
    }

    private func emitAssignment(_ op: String, _ target: MSLExpr, _ value: MSLExpr, indent: String) throws -> String {
        // A swizzle of several components assigned to: one at a time.
        if case .member(let base, let swizzle) = target.kind, swizzle.count > 1, isSwizzle(swizzle) {
            let (baseCode, baseType) = try emitLValue(base)
            if case .vector(let scalar, _) = baseType {
                let componentType = ShaderType.vector(scalar, swizzle.count)
                var (valueCode, valueType) = try emitExpression(value, expected: componentType)
                if op != "=" {
                    let binaryOp = String(op.dropLast())
                    let current = "\(baseCode).\(swizzle)"
                    let (combined, combinedType) = try arithmetic(binaryOp, (current, componentType), (valueCode, valueType), at: target.location)
                    valueCode = combined
                    valueType = combinedType
                }
                let temp = temporary()
                var code = "\(indent)let \(temp) = \(convert(valueCode, from: valueType, to: componentType));\n"
                for (i, component) in swizzle.enumerated() {
                    code += "\(indent)\(baseCode).\(component) = \(temp).\(["x", "y", "z", "w"][i]);\n"
                }
                return code
            }
        }
        let (targetCode, targetType) = try emitLValue(target)
        let (valueCode, valueType) = try emitExpression(value, expected: targetType)
        if op == "=" {
            return "\(indent)\(targetCode) = \(convert(valueCode, from: valueType, to: targetType));\n"
        }
        let binaryOp = String(op.dropLast())
        if ["<<", ">>"].contains(binaryOp) {
            return "\(indent)\(targetCode) \(op) \(convert(valueCode, from: valueType, to: targetType.with(scalar: .uint)));\n"
        }
        // `x op= y` with WGSL's typing: y converted to x's element type when
        // x's shape takes it directly.
        if targetType.isNumeric {
            var rightTarget = targetType
            if valueType.componentCount == 1 || valueType == .scalar(valueType.scalar ?? .float) {
                rightTarget = .scalar(targetType.scalar ?? .float)
            }
            if case .matrix = targetType, case .vector = valueType { rightTarget = valueType }
            return "\(indent)\(targetCode) \(op) \(convert(valueCode, from: valueType, to: rightTarget));\n"
        }
        return "\(indent)\(targetCode) \(op) \(valueCode);\n"
    }

    private func emitLValue(_ expression: MSLExpr) throws -> (String, ShaderType) {
        switch expression.kind {
        case .identifier, .member, .index:
            return try emitExpression(expression)
        case .unary("*", _):
            return try emitExpression(expression)
        default:
            throw MSLTranslationError("this cannot be assigned to", at: expression.location)
        }
    }

    private func emitCondition(_ expression: MSLExpr) throws -> String {
        let (code, type) = try emitExpression(expression, expected: .scalar(.bool))
        return toBool(code, type)
    }

    private func toBool(_ code: String, _ type: ShaderType) -> String {
        switch type {
        case .scalar(.bool), .vector(.bool, _): return code
        case .scalar(let s): return "(\(code) != \(s.isFloat ? "0.0" : s == .uint ? "0u" : "0"))"
        case .vector(let s, let n): return "(\(code) != vec\(n)<\(s.concrete.wgsl)>())"
        default: return code
        }
    }

    // MARK: Expressions

    private func emitExpression(_ expression: MSLExpr, expected: ShaderType? = nil) throws -> (String, ShaderType) {
        switch expression.kind {
        case .integer(let text):
            var digits = text
            var unsigned = false
            while let last = digits.last, "uUlL".contains(last) {
                if last == "u" || last == "U" { unsigned = true }
                digits.removeLast()
            }
            if unsigned { return (digits + "u", .scalar(.uint)) }
            if expected?.scalar?.isFloat == true && !digits.hasPrefix("0x") {
                return (digits + ".0", .scalar(.abstractFloat))
            }
            return (digits, .scalar(.abstractInt))
        case .float(let text):
            var digits = text
            while let last = digits.last, "fFhH".contains(last) { digits.removeLast() }
            if digits.hasSuffix(".") { digits += "0" }
            if digits.hasPrefix(".") { digits = "0" + digits }
            if !digits.contains(".") && !digits.contains("e") && !digits.contains("E") { digits += ".0" }
            return (digits, .scalar(.abstractFloat))
        case .bool(let value):
            return (value ? "true" : "false", .scalar(.bool))
        case .identifier(let name):
            return try emitIdentifier(name, at: expression.location)
        case .qualified(let parts):
            var trimmed = parts
            if ["metal", "fast", "precise"].contains(trimmed.first ?? "") { trimmed.removeFirst() }
            if trimmed.count == 1 { return try emitIdentifier(trimmed[0], at: expression.location) }
            throw MSLTranslationError("'\(parts.joined(separator: "::"))' is not supported here", at: expression.location)
        case .member(let base, let name):
            return try emitMember(base, name, at: expression.location)
        case .index(let base, let index):
            let (baseCode, baseType) = try emitExpression(base)
            let (indexCode, indexType) = try emitExpression(index)
            let indexConverted = indexType.scalar?.isInteger == true ? indexCode : convert(indexCode, from: indexType, to: .scalar(.int))
            switch baseType {
            case .array(let element, _): return ("\(baseCode)[\(indexConverted)]", element)
            case .vector(let s, _): return ("\(baseCode)[\(indexConverted)]", .scalar(s))
            case .matrix(_, let rows): return ("\(baseCode)[\(indexConverted)]", .vector(.float, rows))
            default: throw MSLTranslationError("indexing something that is not an array, vector or matrix", at: expression.location)
            }
        case .call(let callee, let arguments):
            return try emitCall(callee, arguments, at: expression.location)
        case .construct(let spec, let arguments, let braces):
            let type = try resolve(spec, at: expression.location)
            if braces || (arguments.count != 1 && type.isStructure) {
                return (try emitAggregate(arguments, as: type, at: expression.location), type)
            }
            return try emitConstructor(type, arguments, at: expression.location)
        case .initializerList(let elements):
            guard let expected else {
                throw MSLTranslationError("an initializer list needs a type to go to", at: expression.location)
            }
            return (try emitAggregate(elements, as: expected, at: expression.location), expected)
        case .unary(let op, let operand):
            return try emitUnary(op, operand, at: expression.location)
        case .postfix:
            throw MSLTranslationError("++ and -- inside an expression are not supported; use them as statements", at: expression.location)
        case .binary(let op, let a, let b):
            if op == "," {
                throw MSLTranslationError("the comma operator is supported only in a for loop's step", at: expression.location)
            }
            return try emitBinary(op, a, b, at: expression.location)
        case .assign:
            throw MSLTranslationError("an assignment inside an expression is not supported", at: expression.location)
        case .ternary(let condition, let a, let b):
            let (aCode, aType) = try emitExpression(a, expected: expected)
            let (bCode, bType) = try emitExpression(b, expected: expected)
            let resultType = commonType(aType, bType)
            let conditionCode = try emitCondition(condition)
            return ("select(\(convert(bCode, from: bType, to: resultType)), \(convert(aCode, from: aType, to: resultType)), \(conditionCode))", resultType)
        case .templateCall(let name, let types, let arguments):
            guard let spec = types.first, arguments.count == 1 else {
                throw MSLTranslationError("\(name)<…> takes one type and one value", at: expression.location)
            }
            let type = try resolve(spec, at: expression.location)
            let (code, valueType) = try emitExpression(arguments[0])
            if name == "as_type" || name == "reinterpret_cast" {
                return ("bitcast<\(type.wgsl)>(\(convert(code, from: valueType, to: valueType.concrete)))", type)
            }
            return (convert(code, from: valueType, to: type, explicit: true), type)
        }
    }

    private func emitIdentifier(_ name: String, at location: MSLSourceLocation) throws -> (String, ShaderType) {
        if let variable = try lookup(name) ?? ensureGlobal(name, at: location) {
            if variable.isPointer { return ("(*\(variable.name))", variable.type) }
            return (variable.name, variable.type)
        }
        switch name {
        case "M_PI_F", "M_PI_H", "M_PI": return ("3.14159265358979323846", .scalar(.abstractFloat))
        case "M_PI_2_F", "M_PI_2_H", "M_PI_2": return ("1.57079632679489661923", .scalar(.abstractFloat))
        case "M_PI_4_F", "M_PI_4_H": return ("0.78539816339744830962", .scalar(.abstractFloat))
        case "M_1_PI_F", "M_1_PI_H": return ("0.31830988618379067154", .scalar(.abstractFloat))
        case "M_2_PI_F", "M_2_PI_H": return ("0.63661977236758134308", .scalar(.abstractFloat))
        case "M_E_F", "M_E_H": return ("2.71828182845904523536", .scalar(.abstractFloat))
        case "M_SQRT2_F", "M_SQRT2_H": return ("1.41421356237309504880", .scalar(.abstractFloat))
        case "M_SQRT1_2_F", "M_SQRT1_2_H": return ("0.70710678118654752440", .scalar(.abstractFloat))
        case "M_LN2_F": return ("0.69314718055994530942", .scalar(.abstractFloat))
        case "M_LOG2E_F": return ("1.44269504088896340736", .scalar(.abstractFloat))
        case "FLT_MAX", "MAXFLOAT", "HUGE_VALF": return ("3.40282346638528859812e+38", .scalar(.abstractFloat))
        case "FLT_MIN": return ("1.17549435082228750797e-38", .scalar(.abstractFloat))
        case "FLT_EPSILON": return ("1.1920928955078125e-07", .scalar(.abstractFloat))
        case "INT_MAX": return ("2147483647", .scalar(.abstractInt))
        case "UINT_MAX": return ("4294967295u", .scalar(.uint))
        default:
            throw MSLTranslationError("unknown name '\(name)'", at: location)
        }
    }

    private func isSwizzle(_ name: String) -> Bool {
        name.count <= 4 && (name.allSatisfy { "xyzw".contains($0) } || name.allSatisfy { "rgba".contains($0) })
    }

    private func emitMember(_ base: MSLExpr, _ name: String, at location: MSLSourceLocation) throws -> (String, ShaderType) {
        // `buffer->field` on a buffer bound as an array: its first element.
        if case .identifier(let identifier) = base.kind, let variable = lookup(identifier), variable.isBufferArray,
           case .array(let element, _) = variable.type, case .structure(let structName) = element {
            guard let field = structFields[structName]?.first(where: { $0.name == name }) else {
                throw MSLTranslationError("'\(structName)' has no field '\(name)'", at: location)
            }
            return ("\(variable.name)[0].\(wgslIdentifier(name, declare: false))", field.type)
        }
        let (baseCode, baseType) = try emitExpression(base)
        switch baseType {
        case .structure(let structName):
            guard let field = structFields[structName]?.first(where: { $0.name == name }) else {
                throw MSLTranslationError("'\(structName)' has no field '\(name)'", at: location)
            }
            return ("\(baseCode).\(wgslIdentifier(name, declare: false))", field.type)
        case .vector(let scalar, _) where isSwizzle(name):
            return ("\(baseCode).\(name)", name.count == 1 ? .scalar(scalar) : .vector(scalar, name.count))
        case .scalar(let scalar) where name.allSatisfy({ "xr".contains($0) }):
            return (name.count == 1 ? baseCode : "vec\(name.count)<\(scalar.concrete.wgsl)>(\(baseCode))",
                    name.count == 1 ? .scalar(scalar) : .vector(scalar, name.count))
        default:
            throw MSLTranslationError("'.\(name)' on a value of type \(baseType.wgsl)", at: location)
        }
    }

    private func emitUnary(_ op: String, _ operand: MSLExpr, at location: MSLSourceLocation) throws -> (String, ShaderType) {
        switch op {
        case "-":
            let (code, type) = try emitExpression(operand)
            return ("-\(parenthesized(code))", type)
        case "+":
            return try emitExpression(operand)
        case "!":
            let (code, type) = try emitExpression(operand)
            return ("!\(parenthesized(toBool(code, type)))", type.componentCount > 1 ? .vector(.bool, type.componentCount) : .scalar(.bool))
        case "~":
            let (code, type) = try emitExpression(operand)
            return ("~\(parenthesized(code))", type)
        case "*":
            if case .identifier(let name) = operand.kind, let variable = lookup(name) {
                if variable.isBufferArray, case .array(let element, _) = variable.type {
                    return ("\(variable.name)[0]", element)
                }
                if variable.isPointer { return ("(*\(variable.name))", variable.type) }
            }
            throw MSLTranslationError("'*' on something that is not a buffer or reference", at: location)
        case "&":
            let (code, type) = try emitExpression(operand)
            if code.hasPrefix("(*") && code.hasSuffix(")") {
                return (String(code.dropFirst(2).dropLast()), .pointer(type, "function"))
            }
            return ("&\(code)", .pointer(type, "function"))
        default:
            throw MSLTranslationError("\(op) inside an expression is not supported; use it as a statement", at: location)
        }
    }

    private func parenthesized(_ code: String) -> String {
        let simple = code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }
        return simple ? code : "(\(code))"
    }

    private func emitBinary(_ op: String, _ a: MSLExpr, _ b: MSLExpr, at location: MSLSourceLocation) throws -> (String, ShaderType) {
        let left = try emitExpression(a)
        let right = try emitExpression(b, expected: left.1.isAbstract ? nil : left.1)
        let l = left.1.isAbstract && !right.1.isAbstract ? try emitExpression(a, expected: right.1) : left
        switch op {
        case "+", "-", "*", "/", "%":
            return try arithmetic(op, l, right, at: location)
        case "==", "!=", "<", ">", "<=", ">=":
            let common = commonType(l.1, right.1)
            let n = max(l.1.componentCount, right.1.componentCount)
            let lc = convert(l.0, from: l.1, to: n > 1 && l.1.componentCount == 1 ? common.with(scalar: common.scalar ?? .float) : common)
            let rc = convert(right.0, from: right.1, to: n > 1 && right.1.componentCount == 1 ? common.with(scalar: common.scalar ?? .float) : common)
            let resultType: ShaderType = n > 1 ? .vector(.bool, n) : .scalar(.bool)
            // WGSL compares a vector with a vector: a scalar side is splat.
            let lv = n > 1 && l.1.componentCount == 1 ? "vec\(n)<\((common.scalar ?? .float).concrete.wgsl)>(\(lc))" : lc
            let rv = n > 1 && right.1.componentCount == 1 ? "vec\(n)<\((common.scalar ?? .float).concrete.wgsl)>(\(rc))" : rc
            return ("(\(lv) \(op) \(rv))", resultType)
        case "&&", "||":
            return ("(\(toBool(l.0, l.1)) \(op) \(toBool(right.0, right.1)))", .scalar(.bool))
        case "&", "|", "^":
            if l.1.scalar == .bool && right.1.scalar == .bool {
                return ("(\(l.0) \(op) \(right.0))", l.1)
            }
            let common = commonType(l.1, right.1)
            return ("(\(convert(l.0, from: l.1, to: common)) \(op) \(convert(right.0, from: right.1, to: common)))", common)
        case "<<", ">>":
            let shiftType = l.1.with(scalar: .uint)
            return ("(\(l.0) \(op) \(convert(right.0, from: right.1, to: right.1.componentCount > 1 ? right.1.with(scalar: .uint) : (l.1.componentCount > 1 ? shiftType : .scalar(.uint)))))", l.1)
        default:
            throw MSLTranslationError("operator \(op) is not supported", at: location)
        }
    }

    private func arithmetic(_ op: String, _ l: (String, ShaderType), _ r: (String, ShaderType), at location: MSLSourceLocation) throws -> (String, ShaderType) {
        let (lc, lt) = l
        let (rc, rt) = r
        switch (lt, rt) {
        case (.matrix, .matrix), (.matrix, .vector), (.vector, .matrix):
            let result: ShaderType
            switch (lt, rt) {
            case (.matrix(_, let rows), .vector): result = .vector(.float, rows)
            case (.vector, .matrix(let columns, _)): result = .vector(.float, columns)
            case (.matrix(_, let rows), .matrix(let columns, _)): result = .matrix(columns: columns, rows: rows)
            default: result = lt
            }
            return ("(\(lc) \(op) \(convert(rc, from: rt, to: rt.concrete)))", result)
        case (.matrix, .scalar):
            return ("(\(lc) \(op) \(convert(rc, from: rt, to: .scalar(.float))))", lt)
        case (.scalar, .matrix):
            return ("(\(convert(lc, from: lt, to: .scalar(.float))) \(op) \(rc))", rt)
        default:
            break
        }
        guard lt.isNumeric || lt.scalar == .bool, rt.isNumeric || rt.scalar == .bool else {
            throw MSLTranslationError("arithmetic on \(lt.wgsl) and \(rt.wgsl)", at: location)
        }
        let scalar = commonScalar(lt.scalar ?? .float, rt.scalar ?? .float)
        let n = max(lt.componentCount, rt.componentCount)
        let leftTarget: ShaderType = lt.componentCount > 1 ? .vector(scalar, lt.componentCount) : .scalar(scalar)
        let rightTarget: ShaderType = rt.componentCount > 1 ? .vector(scalar, rt.componentCount) : .scalar(scalar)
        let result: ShaderType = n > 1 ? .vector(scalar, n) : .scalar(scalar)
        return ("(\(convert(lc, from: lt, to: leftTarget)) \(op) \(convert(rc, from: rt, to: rightTarget)))", result)
    }

    private func commonScalar(_ a: ShaderScalar, _ b: ShaderScalar) -> ShaderScalar {
        if a.isAbstract && b.isAbstract {
            return (a == .abstractFloat || b == .abstractFloat) ? .abstractFloat : .abstractInt
        }
        if a.isAbstract { return b == .bool ? .int : (a == .abstractFloat && b.isInteger ? .float : b) }
        if b.isAbstract { return a == .bool ? .int : (b == .abstractFloat && a.isInteger ? .float : a) }
        if a.isFloat || b.isFloat { return .float }
        if a == .uint || b == .uint { return .uint }
        return .int
    }

    private func commonType(_ a: ShaderType, _ b: ShaderType) -> ShaderType {
        if a == b { return a }
        switch (a, b) {
        case (.structure, _), (.array, _), (.texture, _), (.sampler, _): return a
        default: break
        }
        let scalar = commonScalar(a.scalar ?? .float, b.scalar ?? .float)
        let n = max(a.componentCount, b.componentCount)
        if case .matrix = a { return a }
        if case .matrix = b { return b }
        return n > 1 ? .vector(scalar, n) : .scalar(scalar)
    }

    /// The code with its value converted from one type to another, as MSL
    /// converts implicitly (and as a cast does, with `explicit`).
    private func convert(_ code: String, from: ShaderType, to: ShaderType, explicit: Bool = false) -> String {
        if from == to { return code }
        let target = to.concrete
        switch (from, target) {
        case (.scalar(let s), .scalar(let t)):
            if s.isAbstract && (s == .abstractInt || t.isFloat) && t != .bool { return code }
            if t == .bool { return toBool(code, from) }
            if s == .bool { return "select(\(t.isFloat ? "0.0" : t == .uint ? "0u" : "0"), \(t.isFloat ? "1.0" : t == .uint ? "1u" : "1"), \(code))" }
            return "\(t.wgsl)(\(code))"
        case (.scalar(let s), .vector(let t, let n)):
            if s.isAbstract && (s == .abstractInt || t.isFloat) && t != .bool { return "vec\(n)<\(t.wgsl)>(\(code))" }
            return "vec\(n)<\(t.wgsl)>(\(convert(code, from: from, to: .scalar(t))))"
        case (.vector(let s, let m), .vector(let t, let n)) where m == n:
            if s.isAbstract { return code }
            if t == .bool { return "(\(code) != vec\(n)<\(s.wgsl)>())" }
            if s == .bool { return "select(vec\(n)<\(t.wgsl)>(), vec\(n)<\(t.wgsl)>(1), \(code))" }
            return "vec\(n)<\(t.wgsl)>(\(code))"
        case (.vector(_, let m), .vector(let t, let n)) where m > n:
            // MSL truncates a wider vector only with a cast; keep the leading
            // components.
            let swizzle = String("xyzw".prefix(n))
            return convert("(\(code)).\(swizzle)", from: from.componentCount > 0 ? .vector(from.scalar ?? .float, n) : from, to: .vector(t, n))
        default:
            return code
        }
    }

    /// `float4(…)`, `int(x)`, `(float)x`.
    private func emitConstructor(_ type: ShaderType, _ arguments: [MSLExpr], at location: MSLSourceLocation) throws -> (String, ShaderType) {
        switch type {
        case .scalar(let s):
            guard arguments.count == 1 else { throw MSLTranslationError("\(type.wgsl)(…) takes one value", at: location) }
            let (code, valueType) = try emitExpression(arguments[0], expected: type)
            if valueType.componentCount > 1 {
                return (convert("\(code).x", from: .scalar(valueType.scalar ?? s), to: type), type)
            }
            return (convert(code, from: valueType, to: type, explicit: true), type)
        case .vector(let s, let n):
            if arguments.count == 1 {
                let (code, valueType) = try emitExpression(arguments[0], expected: .scalar(s))
                if valueType.componentCount == 1 {
                    return ("vec\(n)<\(s.wgsl)>(\(convert(code, from: valueType, to: .scalar(s))))", type)
                }
                return (convert(code, from: valueType, to: type, explicit: true), type)
            }
            var parts: [String] = []
            for argument in arguments {
                let (code, valueType) = try emitExpression(argument, expected: .scalar(s))
                let target: ShaderType = valueType.componentCount > 1 ? .vector(s, valueType.componentCount) : .scalar(s)
                parts.append(convert(code, from: valueType, to: target))
            }
            return ("vec\(n)<\(s.wgsl)>(\(parts.joined(separator: ", ")))", type)
        case .matrix(let columns, let rows):
            var parts: [String] = []
            for argument in arguments {
                let (code, valueType) = try emitExpression(argument, expected: .scalar(.float))
                let target: ShaderType = valueType.componentCount > 1 ? .vector(.float, valueType.componentCount) : .scalar(.float)
                parts.append(convert(code, from: valueType, to: target))
            }
            if parts.count == 1, let first = arguments.first, case .float = first.kind {
                // MSL's float4x4(1.0): a diagonal matrix.
                var columnsCode: [String] = []
                for c in 0..<columns {
                    var components: [String] = []
                    for r in 0..<rows { components.append(c == r ? parts[0] : "0.0") }
                    columnsCode.append("vec\(rows)<f32>(\(components.joined(separator: ", ")))")
                }
                return ("mat\(columns)x\(rows)<f32>(\(columnsCode.joined(separator: ", ")))", type)
            }
            return ("mat\(columns)x\(rows)<f32>(\(parts.joined(separator: ", ")))", type)
        case .structure:
            return (try emitAggregate(arguments, as: type, at: location), type)
        default:
            throw MSLTranslationError("cannot construct \(type.wgsl)", at: location)
        }
    }

    /// `{a, b}` or `Foo{a, b}`: a struct's fields or an array's elements;
    /// missing fields are zero.
    private func emitAggregate(_ elements: [MSLExpr], as type: ShaderType, at location: MSLSourceLocation) throws -> String {
        switch type {
        case .structure(let name):
            let fields = structFields[name] ?? []
            var parts: [String] = []
            for (i, field) in fields.enumerated() {
                if i < elements.count {
                    if case .initializerList(let nested) = elements[i].kind {
                        parts.append(try emitAggregate(nested, as: field.type, at: elements[i].location))
                    } else {
                        let (code, valueType) = try emitExpression(elements[i], expected: field.type)
                        parts.append(convert(code, from: valueType, to: field.type))
                    }
                } else {
                    parts.append("\(field.type.wgsl)()")
                }
            }
            return "\(name)(\(parts.joined(separator: ", ")))"
        case .array(let element, let count):
            var parts: [String] = []
            for value in elements {
                if case .initializerList(let nested) = value.kind {
                    parts.append(try emitAggregate(nested, as: element, at: value.location))
                } else {
                    let (code, valueType) = try emitExpression(value, expected: element)
                    parts.append(convert(code, from: valueType, to: element))
                }
            }
            while let count, parts.count < count { parts.append("\(element.wgsl)()") }
            return "array<\(element.wgsl), \(count ?? parts.count)>(\(parts.joined(separator: ", ")))"
        case .vector, .matrix, .scalar:
            return try emitConstructor(type, elements, at: location).0
        default:
            throw MSLTranslationError("an initializer list for \(type.wgsl)", at: location)
        }
    }

    // MARK: Calls

    private func emitCall(_ callee: MSLExpr, _ arguments: [MSLExpr], at location: MSLSourceLocation) throws -> (String, ShaderType) {
        // Methods: texture.sample(…), atomic loads…
        if case .member(let base, let method) = callee.kind {
            let (baseCode, baseType) = try emitExpression(base)
            if case .texture(let kind, let scalar, _) = baseType {
                return try emitTextureMethod(baseCode, kind: kind, scalar: scalar, method: method, arguments, at: location)
            }
            throw MSLTranslationError("method '\(method)' on \(baseType.wgsl) is not supported", at: location)
        }
        var name: String
        switch callee.kind {
        case .identifier(let n): name = n
        case .qualified(let parts):
            var trimmed = parts
            if ["metal", "fast", "precise"].contains(trimmed.first ?? "") { trimmed.removeFirst() }
            name = trimmed.joined(separator: "::")
        default:
            throw MSLTranslationError("calling something that is not a function", at: location)
        }
        if let signature = try ensureFunction(name, at: location) {
            guard signature.parameterTypes.count == arguments.count else {
                throw MSLTranslationError("'\(name)' takes \(signature.parameterTypes.count) arguments", at: location)
            }
            var parts: [String] = []
            for (i, argument) in arguments.enumerated() {
                let parameterType = signature.parameterTypes[i]
                let (code, type) = try emitExpression(argument, expected: parameterType)
                if signature.parameterIsReference[i] {
                    if code.hasPrefix("(*") && code.hasSuffix(")") {
                        parts.append(String(code.dropFirst(2).dropLast()))
                    } else {
                        parts.append("&\(code)")
                    }
                } else {
                    parts.append(convert(code, from: type, to: parameterType))
                }
            }
            return ("\(signature.name)(\(parts.joined(separator: ", ")))", signature.returnType)
        }
        return try emitBuiltinCall(name, arguments, at: location)
    }

    private static let sameNameBuiltins: Set<String> = [
        "abs", "acos", "acosh", "asin", "asinh", "atan", "atanh", "ceil", "clamp", "cos", "cosh", "cross",
        "degrees", "determinant", "distance", "dot", "exp", "exp2", "floor", "fma", "fract", "length", "log",
        "log2", "max", "min", "mix", "normalize", "pow", "radians", "reflect", "refract", "round", "saturate",
        "sign", "sin", "sinh", "smoothstep", "sqrt", "step", "tan", "tanh", "transpose", "trunc", "fwidth",
        "all", "any",
    ]

    private static let renamedBuiltins: [String: String] = [
        "fabs": "abs", "fmin": "min", "fmax": "max", "rsqrt": "inverseSqrt", "powr": "pow", "rint": "round",
        "dfdx": "dpdx", "dfdy": "dpdy", "atan2": "atan2", "faceforward": "faceForward",
        "popcount": "countOneBits", "clz": "countLeadingZeros", "ctz": "countTrailingZeros",
        "reverse_bits": "reverseBits", "extract_bits": "extractBits", "insert_bits": "insertBits",
        "pack_float_to_unorm4x8": "pack4x8unorm", "pack_float_to_snorm4x8": "pack4x8snorm",
        "unpack_unorm4x8_to_float": "unpack4x8unorm", "unpack_snorm4x8_to_float": "unpack4x8snorm",
        "pack_float_to_unorm2x16": "pack2x16unorm", "unpack_unorm2x16_to_float": "unpack2x16unorm",
        "pack_half_to_unorm2x16": "pack2x16float",
    ]

    private func emitBuiltinCall(_ name: String, _ arguments: [MSLExpr], at location: MSLSourceLocation) throws -> (String, ShaderType) {
        var typed: [(String, ShaderType)] = []
        for argument in arguments { typed.append(try emitExpression(argument)) }

        func floatArguments() -> ([String], ShaderType) {
            // The common type of the arguments (vector width, float when any
            // is float, else the integer type); each converted to it.
            var common = typed.first?.1 ?? .scalar(.float)
            for (_, type) in typed.dropFirst() { common = commonType(common, type) }
            if common.isAbstract { common = common.concrete }
            let parts = typed.map { code, type in
                convert(code, from: type, to: type.componentCount > 1 || common.componentCount == 1 ? common : common.with(scalar: common.scalar ?? .float))
            }
            return (parts, common)
        }

        switch name {
        case "select":
            guard typed.count == 3 else { break }
            let common = commonType(typed[0].1, typed[1].1)
            let condition = typed[2].1.scalar == .bool ? typed[2].0 : toBool(typed[2].0, typed[2].1)
            return ("select(\(convert(typed[0].0, from: typed[0].1, to: common)), \(convert(typed[1].0, from: typed[1].1, to: common)), \(condition))", common)
        case "fmod":
            let (parts, common) = floatArguments()
            return ("(\(parts[0]) % \(parts[1]))", common)
        case "log10":
            let (parts, common) = floatArguments()
            return ("(log(\(parts[0])) * 0.4342944819032518)", common)
        case "isnan":
            let (parts, common) = floatArguments()
            return ("(\(parts[0]) != \(parts[0]))", common.componentCount > 1 ? .vector(.bool, common.componentCount) : .scalar(.bool))
        case "threadgroup_barrier", "simdgroup_barrier":
            let flags = arguments.first.map { describe($0) } ?? ""
            return (flags.contains("mem_device") ? "storageBarrier()" : "workgroupBarrier()", .void)
        case "atomic_fetch_add_explicit", "atomic_fetch_sub_explicit", "atomic_fetch_min_explicit",
             "atomic_fetch_max_explicit", "atomic_fetch_and_explicit", "atomic_fetch_or_explicit",
             "atomic_fetch_xor_explicit", "atomic_exchange_explicit":
            guard typed.count >= 2 else { break }
            let op = name.replacingOccurrences("atomic_fetch_", "").replacingOccurrences("atomic_", "").replacingOccurrences("_explicit", "")
            let wgsl = ["add": "atomicAdd", "sub": "atomicSub", "min": "atomicMin", "max": "atomicMax",
                        "and": "atomicAnd", "or": "atomicOr", "xor": "atomicXor", "exchange": "atomicExchange"][op]!
            let pointer = typed[0].0.hasPrefix("&") ? typed[0].0 : "&\(typed[0].0)"
            let scalar: ShaderScalar = { if case .pointer(.atomic(let s), _) = typed[0].1 { return s }; return .uint }()
            return ("\(wgsl)(\(pointer), \(convert(typed[1].0, from: typed[1].1, to: .scalar(scalar))))", .scalar(scalar))
        case "atomic_load_explicit":
            let pointer = typed[0].0.hasPrefix("&") ? typed[0].0 : "&\(typed[0].0)"
            let scalar: ShaderScalar = { if case .pointer(.atomic(let s), _) = typed[0].1 { return s }; return .uint }()
            return ("atomicLoad(\(pointer))", .scalar(scalar))
        case "atomic_store_explicit":
            let pointer = typed[0].0.hasPrefix("&") ? typed[0].0 : "&\(typed[0].0)"
            let scalar: ShaderScalar = { if case .pointer(.atomic(let s), _) = typed[0].1 { return s }; return .uint }()
            return ("atomicStore(\(pointer), \(convert(typed[1].0, from: typed[1].1, to: .scalar(scalar))))", .void)
        default:
            break
        }
        let wgslName = WGSLGenerator.renamedBuiltins[name] ?? (WGSLGenerator.sameNameBuiltins.contains(name) ? name : nil)
        guard let wgslName else {
            throw MSLTranslationError("function '\(name)' is not supported (or not defined)", at: location)
        }
        let (parts, common) = floatArguments()
        var resultType = common
        switch name {
        case "length", "distance", "dot", "determinant":
            resultType = .scalar(common.scalar ?? .float)
        case "all", "any":
            return ("\(wgslName)(\(typed.map { toBool($0.0, $0.1) }.joined(separator: ", ")))", .scalar(.bool))
        case "cross":
            resultType = .vector(.float, 3)
        case "transpose":
            if case .matrix(let c, let r) = typed.first?.1 ?? common { resultType = .matrix(columns: r, rows: c) }
        case "popcount", "clz", "ctz", "reverse_bits", "extract_bits", "insert_bits":
            resultType = typed.first?.1.concrete ?? common
            return ("\(wgslName)(\(typed.map(\.0).joined(separator: ", ")))", resultType)
        case "pack_float_to_unorm4x8", "pack_float_to_snorm4x8", "pack_float_to_unorm2x16", "pack_half_to_unorm2x16":
            return ("\(wgslName)(\(parts.joined(separator: ", ")))", .scalar(.uint))
        case "unpack_unorm4x8_to_float", "unpack_snorm4x8_to_float":
            return ("\(wgslName)(\(typed.map(\.0).joined(separator: ", ")))", .vector(.float, 4))
        case "unpack_unorm2x16_to_float":
            return ("\(wgslName)(\(typed.map(\.0).joined(separator: ", ")))", .vector(.float, 2))
        default:
            break
        }
        if ["sin", "cos", "tan", "asin", "acos", "atan", "atan2", "sinh", "cosh", "tanh", "exp", "exp2", "log", "log2",
            "pow", "powr", "sqrt", "rsqrt", "fract", "floor", "ceil", "round", "rint", "trunc", "normalize", "length",
            "distance", "mix", "smoothstep", "step", "saturate", "reflect", "refract", "faceforward", "dfdx", "dfdy",
            "fwidth", "radians", "degrees", "fmod", "fma"].contains(name), resultType.scalar?.isFloat != true {
            // Integer arguments to a float function: MSL converts them.
            let floatType = resultType.with(scalar: .float)
            let converted = typed.map { code, type in convert(code, from: type, to: type.componentCount > 1 ? floatType : .scalar(.float)) }
            return ("\(wgslName)(\(converted.joined(separator: ", ")))", name == "length" || name == "distance" ? .scalar(.float) : floatType)
        }
        return ("\(wgslName)(\(parts.joined(separator: ", ")))", resultType)
    }

    private func describe(_ expression: MSLExpr) -> String {
        switch expression.kind {
        case .identifier(let n): return n
        case .qualified(let parts): return parts.joined(separator: "::")
        case .binary(_, let a, let b): return describe(a) + "|" + describe(b)
        default: return ""
        }
    }

    private func emitTextureMethod(
        _ texture: String, kind: ShaderTextureKind, scalar: ShaderScalar, method: String, _ arguments: [MSLExpr],
        at location: MSLSourceLocation
    ) throws -> (String, ShaderType) {
        let result: ShaderType = kind.isDepth ? .scalar(.float) : .vector(scalar.concrete, 4)
        let coordinateType: ShaderType = kind.coordinateCount == 1 ? .scalar(.float) : .vector(.float, kind.coordinateCount)
        switch method {
        case "sample", "sample_compare":
            guard arguments.count >= 2 else { throw MSLTranslationError("\(method)(sampler, coordinate, …)", at: location) }
            let (sampler, _) = try emitExpression(arguments[0])
            let (coordinateCode, coordinateValueType) = try emitExpression(arguments[1], expected: coordinateType)
            var parts = [texture, sampler, convert(coordinateCode, from: coordinateValueType, to: coordinateType)]
            var rest = Array(arguments.dropFirst(2))
            if kind.isArray, let layer = rest.first {
                let (code, type) = try emitExpression(layer, expected: .scalar(.uint))
                parts.append(convert(code, from: type, to: .scalar(type.scalar == .int ? .int : .uint)))
                rest.removeFirst()
            }
            if method == "sample_compare", let reference = rest.first {
                let (code, type) = try emitExpression(reference, expected: .scalar(.float))
                parts.append(convert(code, from: type, to: .scalar(.float)))
                rest.removeFirst()
                return ("textureSampleCompare(\(parts.joined(separator: ", ")))", .scalar(.float))
            }
            var function = stage == .fragment ? "textureSample" : "textureSampleLevel"
            var levelAdded = false
            for option in rest {
                guard case .call(let callee, let optionArguments) = option.kind, case .identifier(let optionName) = callee.kind else {
                    throw MSLTranslationError("a sample option (level(…), bias(…), gradient2d(…))", at: option.location)
                }
                switch optionName {
                case "level":
                    function = "textureSampleLevel"
                    let (code, type) = try emitExpression(optionArguments[0], expected: .scalar(.float))
                    parts.append(kind.isDepth ? convert(code, from: type, to: .scalar(.int)) : convert(code, from: type, to: .scalar(.float)))
                    levelAdded = true
                case "bias":
                    function = stage == .fragment ? "textureSampleBias" : "textureSampleLevel"
                    let (code, type) = try emitExpression(optionArguments[0], expected: .scalar(.float))
                    parts.append(stage == .fragment ? convert(code, from: type, to: .scalar(.float)) : "0.0")
                    levelAdded = true
                case "gradient2d", "gradient3d", "gradientcube":
                    function = "textureSampleGrad"
                    for value in optionArguments {
                        let (code, type) = try emitExpression(value, expected: coordinateType)
                        parts.append(convert(code, from: type, to: coordinateType))
                    }
                    levelAdded = true
                default:
                    throw MSLTranslationError("sample option '\(optionName)' is not supported", at: option.location)
                }
            }
            if function == "textureSampleLevel" && !levelAdded {
                parts.append(kind.isDepth ? "0" : "0.0")
            }
            return ("\(function)(\(parts.joined(separator: ", ")))", result)
        case "read":
            guard let coordinate = arguments.first else { throw MSLTranslationError("read(coordinate, …)", at: location) }
            let (code, type) = try emitExpression(coordinate)
            var parts = [texture, convert(code, from: type, to: type.componentCount > 1 ? type.with(scalar: type.scalar == .int ? .int : .uint) : .scalar(.uint))]
            var rest = Array(arguments.dropFirst())
            if kind.isArray, let layer = rest.first {
                let (layerCode, layerType) = try emitExpression(layer)
                parts.append(convert(layerCode, from: layerType, to: .scalar(.uint)))
                rest.removeFirst()
            }
            if kind != .texture2dMS && kind != .depth2dMS {
                if let level = rest.first {
                    let (levelCode, levelType) = try emitExpression(level)
                    parts.append(convert(levelCode, from: levelType, to: .scalar(.uint)))
                } else if case .texture(_, _, let access) = ShaderType.texture(kind, scalar, .sample), access == .sample {
                    parts.append("0")
                }
            }
            return ("textureLoad(\(parts.joined(separator: ", ")))", result)
        case "write":
            guard arguments.count >= 2 else { throw MSLTranslationError("write(value, coordinate)", at: location) }
            let (value, valueType) = try emitExpression(arguments[0], expected: result)
            let (code, type) = try emitExpression(arguments[1])
            var parts = [texture, convert(code, from: type, to: type.componentCount > 1 ? type.with(scalar: type.scalar == .int ? .int : .uint) : .scalar(.uint))]
            if kind.isArray, arguments.count > 2 {
                let (layerCode, layerType) = try emitExpression(arguments[2])
                parts.append(convert(layerCode, from: layerType, to: .scalar(.uint)))
            }
            parts.append(convert(value, from: valueType, to: .vector(scalar.concrete, 4)))
            return ("textureStore(\(parts.joined(separator: ", ")))", .void)
        case "get_width", "get_height", "get_depth":
            let component = ["get_width": "x", "get_height": "y", "get_depth": "z"][method]!
            var parts = [texture]
            if let lod = arguments.first {
                let (code, type) = try emitExpression(lod)
                parts.append(convert(code, from: type, to: .scalar(.uint)))
            }
            let dimensions = "textureDimensions(\(parts.joined(separator: ", ")))"
            return (kind.coordinateCount == 1 ? dimensions : "\(dimensions).\(component)", .scalar(.uint))
        case "get_num_mip_levels":
            return ("textureNumLevels(\(texture))", .scalar(.uint))
        case "get_array_size":
            return ("textureNumLayers(\(texture))", .scalar(.uint))
        default:
            throw MSLTranslationError("texture method '\(method)' is not supported", at: location)
        }
    }

    // MARK: Analysis

    /// The names a body assigns to (its parameters among them).
    private func mutatedNames(in statements: [MSLStmt]) -> Set<String> {
        var names: Set<String> = []
        func root(_ e: MSLExpr) -> String? {
            switch e.kind {
            case .identifier(let n): return n
            case .member(let b, _), .index(let b, _): return root(b)
            default: return nil
            }
        }
        func visitExpression(_ e: MSLExpr) {
            switch e.kind {
            case .assign(_, let t, let v):
                if let r = root(t) { names.insert(r) }
                visitExpression(t)
                visitExpression(v)
            case .postfix(_, let t):
                if let r = root(t) { names.insert(r) }
            case .unary(let op, let t):
                if op == "++" || op == "--" || op == "&", let r = root(t) { names.insert(r) }
                visitExpression(t)
            case .binary(_, let a, let b):
                visitExpression(a)
                visitExpression(b)
            case .ternary(let a, let b, let c):
                visitExpression(a); visitExpression(b); visitExpression(c)
            case .call(let c, let args):
                visitExpression(c)
                args.forEach(visitExpression)
            case .construct(_, let args, _), .initializerList(let args), .templateCall(_, _, let args):
                args.forEach(visitExpression)
            case .member(let b, _):
                visitExpression(b)
            case .index(let b, let i):
                visitExpression(b)
                visitExpression(i)
            default: break
            }
        }
        func visit(_ s: MSLStmt) {
            switch s {
            case .block(let b): b.forEach(visit)
            case .declaration(let d): d.forEach { if let i = $0.initializer { visitExpression(i) } }
            case .expression(let e): visitExpression(e)
            case .ifStmt(let c, let t, let e):
                visitExpression(c); visit(t); if let e { visit(e) }
            case .forStmt(let i, let c, let st, let b):
                if let i { visit(i) }
                if let c { visitExpression(c) }
                if let st { visitExpression(st) }
                visit(b)
            case .whileStmt(let c, let b): visitExpression(c); visit(b)
            case .doWhile(let b, let c): visit(b); visitExpression(c)
            case .switchStmt(let e, let cases): visitExpression(e); cases.forEach { $0.body.forEach(visit) }
            case .returnStmt(let e, _): if let e { visitExpression(e) }
            default: break
            }
        }
        statements.forEach(visit)
        return names
    }
}

extension ShaderType {
    var isStructure: Bool {
        if case .structure = self { return true }
        return false
    }
}

extension String {
    func trimmingNewline() -> String {
        var s = self
        while s.last == "\n" { s.removeLast() }
        return s.trimmingSpaces()
    }

    func indented(by prefix: String) -> String {
        split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : prefix + $0 }
            .joined(separator: "\n")
    }
}
