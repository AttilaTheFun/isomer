import ArgumentParser
import Foundation
import SwiftFFIGeneratorLibrary
import SwiftFFIIRLibrary

extension GeneratorKind: @retroactive ExpressibleByArgument {}

@main
struct Generate: ParsableCommand {
    @Option(help: "JSON file listing the per-source analysis JSON paths.")
    var analysisManifest: String

    @Option(help: "The artifact kind to generate.")
    var kind: GeneratorKind

    @Option(help: "Where to write the generated artifact.")
    var output: String

    @Option(help: "The Swift module the glue imports / the symbol namespace.")
    var moduleName: String = "Module"

    @Option(help: "Kotlin package for the kotlin/jni kinds.")
    var javaPackage: String = "com.example"

    @Option(help: "Kotlin facade object name for the kotlin/jni kinds.")
    var javaClass: String = "Native"

    @Option(help: "Native library name for System.loadLibrary in the kotlin kind.")
    var libraryName: String = "native"

    @Option(help: "The generated C header's file name (jni-adapter / cpp includes).")
    var headerName: String = ""

    func run() throws {
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: analysisManifest))
        let paths = try JSONDecoder().decode([String].self, from: manifestData)

        var module = FFIModule()
        let decoder = JSONDecoder()
        for path in paths {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            module.merge(try decoder.decode(FFIModule.self, from: data))
        }

        let generator = Generator(module: module)
        try generator.validate()
        let contents = try generator.artifact(
            kind: kind,
            moduleName: moduleName,
            javaPackage: javaPackage,
            javaClass: javaClass,
            libraryName: libraryName,
            headerName: headerName
        )
        try contents.write(toFile: output, atomically: true, encoding: .utf8)
    }
}
