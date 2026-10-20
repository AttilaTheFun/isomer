import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ExportedFunctionMacroTests: XCTestCase {
    private let macros: [String: any Macro.Type] = [
        "ExportedFunction": ExportedFunctionMacro.self
    ]

    func testBridgeableFunctionValidates() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func greet(name: String, count: Int) -> String { name }
            """,
            expandedSource: """
                public func greet(name: String, count: Int) -> String { name }
                """,
            macros: macros
        )
    }

    func testInterfaceExistentialParameterValidates() {
        // `any Counter` canonicalizes to the bare protocol name, which is a
        // possible interface — permitted here, validated by the analyzer.
        assertMacroExpansion(
            """
            @ExportedFunction
            public func describe(counter: any Counter) -> String { "" }
            """,
            expandedSource: """
                public func describe(counter: any Counter) -> String { "" }
                """,
            macros: macros
        )
    }

    func testResultReturnValidatesAsSuccessType() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func risky() -> Result<String, MyError> { .success("") }
            """,
            expandedSource: """
                public func risky() -> Result<String, MyError> { .success("") }
                """,
            macros: macros
        )
    }

    func testUnbridgeableParameterDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func bad(values: [Double]) {}
            """,
            expandedSource: """
                public func bad(values: [Double]) {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction bad parameter 'values' has unbridgeable type "
                        + "'[Double]'. Supported types: Int, Int32, Double, Bool, String, [UInt8], "
                        + "or an @ExportedInterface protocol.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testNonFunctionDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public var count = 0
            """,
            expandedSource: """
                public var count = 0
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction can only be applied to a function.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    // MARK: - Bridge v2

    func testGenericBridgeableFunctionExpands() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func echo<T: Bridgeable>(_ value: T, fallback: T) -> T { value }
            """,
            expandedSource: """
                public func echo<T: Bridgeable>(_ value: T, fallback: T) -> T { value }
                """,
            macros: macros
        )
    }

    func testGenericWithoutConstraintDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func echo<T>(_ value: T) -> T { value }
            """,
            expandedSource: """
                public func echo<T>(_ value: T) -> T { value }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction echo generic parameter 'T' must be constrained to "
                        + "'Bridgeable' (generic exports bridge by erasing to the Bridgeable "
                        + "vocabulary).",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testReturnOnlyGenericDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func make<T: Bridgeable>(count: Int) -> T { fatalError() }
            """,
            expandedSource: """
                public func make<T: Bridgeable>(count: Int) -> T { fatalError() }
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction make generic parameter 'T' must appear as the type "
                        + "of at least one parameter (return-only generics cannot cross the erased "
                        + "ABI).",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testClosureParameterExpands() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func transform(_ x: Int, using f: (Int) -> Int) -> Int { f(x) }
            """,
            expandedSource: """
                public func transform(_ x: Int, using f: (Int) -> Int) -> Int { f(x) }
                """,
            macros: macros
        )
    }

    func testEscapingClosureParameterExpands() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func onTick(_ callback: @escaping (Int) -> Void) {}
            """,
            expandedSource: """
                public func onTick(_ callback: @escaping (Int) -> Void) {}
                """,
            macros: macros
        )
    }

    func testClosureWithUnbridgeableElementDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func bad(f: ([Double]) -> Void) {}
            """,
            expandedSource: """
                public func bad(f: ([Double]) -> Void) {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction bad parameter 'f' closure parameter has "
                        + "unbridgeable type '[Double]'. Supported types: Int, Int32, Double, "
                        + "Bool, String, [UInt8], or an @ExportedInterface protocol.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testLazyReturnExpands() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func expensive(for name: String) -> Lazy<String> { Lazy { name } }
            """,
            expandedSource: """
                public func expensive(for name: String) -> Lazy<String> { Lazy { name } }
                """,
            macros: macros
        )
    }

    func testLazyParameterDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func bad(value: Lazy<String>) {}
            """,
            expandedSource: """
                public func bad(value: Lazy<String>) {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedFunction bad parameter 'value': Lazy<T> is only supported "
                        + "as a return type.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    func testResultParameterExpands() {
        assertMacroExpansion(
            """
            @ExportedFunction
            public func describe(_ r: Result<Int, Error>) -> String { "" }
            """,
            expandedSource: """
                public func describe(_ r: Result<Int, Error>) -> String { "" }
                """,
            macros: macros
        )
    }
}
