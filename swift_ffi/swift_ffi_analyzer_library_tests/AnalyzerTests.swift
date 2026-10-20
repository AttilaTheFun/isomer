import SwiftFFIAnalyzerLibrary
import SwiftFFIIRLibrary
import XCTest

final class AnalyzerTests: XCTestCase {
    private let analyzer = Analyzer()

    func testCollectsExportedFunction() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func greet(name: String, count: Int) -> String { name }
                """,
            moduleName: "Greeter"
        )
        XCTAssertEqual(
            module.functions,
            [
                FFIFunction(
                    name: "greet",
                    parameters: [
                        FFIParameter(label: "name", type: "String"),
                        FFIParameter(label: "count", type: "Int"),
                    ],
                    returnType: "String"
                )
            ]
        )
        XCTAssertEqual(module.sourceModules, ["Greeter"])
    }

    func testIgnoresUnannotatedDeclarations() {
        let module = analyzer.analyze(
            source: """
                public func plain() {}
                public struct Plain { public var x: Int }
                public protocol PlainProtocol { func f() }
                """
        )
        XCTAssertTrue(module.isEmpty)
        XCTAssertTrue(module.sourceModules.isEmpty)
    }

    func testCanonicalizesExistentialAny() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func describe(counter: any Counter) -> any Counter { counter }
                """
        )
        XCTAssertEqual(module.functions.first?.parameters.first?.type, "Counter")
        XCTAssertEqual(module.functions.first?.returnType, "Counter")
    }

    func testRecordsThrowingAndAsync() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func fetch(url: String) async throws -> String { url }
                """
        )
        let function = module.functions[0]
        XCTAssertTrue(function.isAsync)
        XCTAssertTrue(function.isThrowing)
        XCTAssertFalse(function.wrapsResult)
    }

    func testUnwrapsResultReturn() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func risky() -> Result<String, MyError> { .success("") }
                """
        )
        let function = module.functions[0]
        XCTAssertEqual(function.returnType, "String")
        XCTAssertTrue(function.isThrowing)
        XCTAssertTrue(function.wrapsResult)
    }

    func testCollectsInterfaceMethods() {
        let module = analyzer.analyze(
            source: """
                @ExportedInterface
                public protocol Counter {
                    func increment(by amount: Int) -> Int
                    func reset()
                }
                """
        )
        XCTAssertEqual(
            module.interfaces,
            [
                FFIInterface(
                    name: "Counter",
                    methods: [
                        FFIMethod(
                            name: "increment",
                            parameters: [FFIParameter(label: "by", type: "Int")],
                            returnType: "Int"
                        ),
                        FFIMethod(name: "reset", parameters: [], returnType: "Void"),
                    ]
                )
            ]
        )
    }

    func testCollectsStructStoredProperties() {
        let module = analyzer.analyze(
            source: """
                @ExportedStruct
                public struct Stats {
                    public var count: Int
                    public var label: String
                    public var derived: Int { count * 2 }
                }
                """
        )
        XCTAssertEqual(
            module.structs,
            [
                FFIStruct(
                    name: "Stats",
                    fields: [
                        FFIField(name: "count", type: "Int"),
                        FFIField(name: "label", type: "String"),
                    ]
                )
            ]
        )
    }

    // MARK: - Bridge v2

    func testCollectsGenericFunction() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func echo<T: Bridgeable>(_ value: T, fallback: T) -> T { value }
                """
        )
        let function = module.functions.first
        XCTAssertEqual(function?.genericParameters, ["T"])
        XCTAssertEqual(
            function?.parameters,
            [
                FFIParameter(label: "_", type: "T"),
                FFIParameter(label: "fallback", type: "T"),
            ]
        )
        XCTAssertEqual(function?.returnType, "T")
    }

    func testCollectsClosureParameter() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func transform(_ x: Int, using f: @escaping (Int, String) -> Int) -> Int { x }
                """
        )
        let parameter = module.functions.first?.parameters.last
        XCTAssertEqual(
            parameter?.closure,
            FFIClosureType(parameters: ["Int", "String"], returnType: "Int")
        )
    }

    func testCollectsVoidClosureParameter() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func onTick(_ callback: @escaping (Int) -> Void) {}
                """
        )
        let parameter = module.functions.first?.parameters.first
        XCTAssertEqual(
            parameter?.closure,
            FFIClosureType(parameters: ["Int"], returnType: "Void")
        )
    }

    func testCollectsResultParameter() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func describe(_ r: Result<Int, Error>) -> String { "" }
                """
        )
        let parameter = module.functions.first?.parameters.first
        XCTAssertEqual(parameter?.resultSuccess, "Int")
        XCTAssertEqual(parameter?.type, "Result<Int, Error>")
    }

    func testCollectsLazyReturn() {
        let module = analyzer.analyze(
            source: """
                @ExportedFunction
                public func expensive(for name: String) -> Lazy<String> { Lazy { name } }
                """
        )
        let function = module.functions.first
        XCTAssertEqual(function?.returnType, "String")
        XCTAssertEqual(function?.returnsLazy, true)
        XCTAssertEqual(function?.isThrowing, false)
    }
}
