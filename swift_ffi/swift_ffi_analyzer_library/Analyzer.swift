import SwiftFFIIRLibrary
import SwiftParser

/// Extracts the exported FFI surface from annotated Swift source: the
/// analyzer half of the swift_ffi pipeline (the generator consumes the
/// resulting IR). One instance analyzes one source file; the per-file
/// results are merged downstream (`FFIModule.merge`).
public struct Analyzer {
    public init() {}

    /// Parses `source` and collects every `@ExportedFunction` /
    /// `@ExportedInterface` / `@ExportedStruct` declaration.
    ///
    /// - Parameters:
    ///   - source: the Swift source text to analyze.
    ///   - moduleName: the Swift module the source belongs to, recorded in
    ///     the IR (when non-empty) so generators import every exporting
    ///     module.
    public func analyze(source: String, moduleName: String = "") -> FFIModule {
        let tree = Parser.parse(source: source)
        let collector = ExportCollector(viewMode: .sourceAccurate)
        collector.walk(tree)

        var module = collector.module
        if !module.isEmpty && !moduleName.isEmpty {
            module.sourceModules = [moduleName]
        }
        return module
    }
}
