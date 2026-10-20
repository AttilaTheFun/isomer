import ArgumentParser
import Foundation
import SwiftFFIAnalyzerLibrary

@main
struct Analyze: ParsableCommand {
    @Option(help: "The Swift source file to analyze.")
    var sourceFilePath: String

    @Option(help: "The Swift module the source file belongs to (recorded so generators import every exporting module).")
    var moduleName: String = ""

    @Option(help: "Where to write the JSON analysis for this source file.")
    var analysisFilePath: String

    func run() throws {
        let source = try String(contentsOfFile: sourceFilePath, encoding: .utf8)
        let module = Analyzer().analyze(source: source, moduleName: moduleName)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(module)
        try data.write(to: URL(fileURLWithPath: analysisFilePath))
    }
}
