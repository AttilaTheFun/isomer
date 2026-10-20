import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ExportedStructMacroTests: XCTestCase {
    private let macros: [String: any Macro.Type] = [
        "ExportedStruct": ExportedStructMacro.self
    ]

    func testSynthesizesMemberwiseInitializer() {
        assertMacroExpansion(
            """
            @ExportedStruct
            public struct Stats {
                public var count: Int
                public var label: String
            }
            """,
            expandedSource: """
                public struct Stats {
                    public var count: Int
                    public var label: String

                    public init(count: Int, label: String) {
                        self.count = count
                        self.label = label
                    }
                }
                """,
            macros: macros
        )
    }

    func testUnbridgeableFieldDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedStruct
            public struct Bad {
                public var values: [Double]
            }
            """,
            expandedSource: """
                public struct Bad {
                    public var values: [Double]
                }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedStruct property 'values' has type '[Double]'; struct fields "
                        + "must be bridgeable value types.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testEmptyStructDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedStruct
            public struct Empty {}
            """,
            expandedSource: """
                public struct Empty {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedStruct requires at least one stored property.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }
}
