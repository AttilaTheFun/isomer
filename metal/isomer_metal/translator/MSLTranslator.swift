// The shader translator's entry: Metal Shading Language source in, one WGSL
// module per entry point out (what `MTLDevice.makeLibrary(source:options:)`
// and `MTLLibrary.makeFunction(name:)` need on WebGPU).
//
// The subset it reads is in docs/parity/Metal.md ("Shaders"): structs,
// helper functions, constants and constexpr samplers; vertex, fragment and
// kernel functions with buffer/texture/sampler/stage_in/builtin
// parameters; MSL's scalar, vector and matrix types and its common math,
// texture and atomic functions. Anything else is an error naming the line,
// rather than a guess.

public struct MSLTranslator: Sendable {
    public let unit: MSLTranslationUnit

    public init(source: String) throws {
        var parser = try MSLParser(source: source)
        unit = try parser.parse()
    }

    /// The vertex, fragment and kernel functions the source declares.
    public var entryPoints: [(name: String, stage: MSLStage)] {
        unit.functions.compactMap { function in function.stage.map { (function.name, $0) } }
    }

    /// One entry point translated, with what it uses of the source.
    public func translate(entryPoint name: String) throws -> TranslatedEntryPoint {
        guard let function = unit.functions.first(where: { $0.name == name && $0.stage != nil }) else {
            throw MSLTranslationError("no vertex, fragment or kernel function named '\(name)'")
        }
        return try WGSLGenerator(unit: unit, entry: function).generate()
    }

    /// Every entry point translated.
    public func translateAll() throws -> [TranslatedEntryPoint] {
        try entryPoints.map { try translate(entryPoint: $0.name) }
    }
}
