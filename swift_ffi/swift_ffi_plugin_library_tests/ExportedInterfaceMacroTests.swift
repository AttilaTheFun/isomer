import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

final class ExportedInterfaceMacroTests: XCTestCase {
    private let macros: [String: any Macro.Type] = [
        "ExportedInterface": ExportedInterfaceMacro.self
    ]

    func testBridgeableProtocolValidates() {
        assertMacroExpansion(
            """
            @ExportedInterface
            public protocol Counter {
                func increment(by amount: Int) -> Int
                func label() -> String
            }
            """,
            expandedSource: """
                public protocol Counter {
                    func increment(by amount: Int) -> Int
                    func label() -> String
                }
                """,
            macros: macros
        )
    }

    func testNonProtocolDiagnoses() {
        assertMacroExpansion(
            """
            @ExportedInterface
            public struct NotAProtocol {}
            """,
            expandedSource: """
                public struct NotAProtocol {}
                """,
            diagnostics: [
                DiagnosticSpec(
                    message: "@ExportedInterface can only be applied to a protocol.",
                    line: 1,
                    column: 1
                )
            ],
            macros: macros
        )
    }

    /// An SPI protocol's public peers are declared with its SPI too (a public
    /// declaration cannot name an SPI protocol).
    func testSPIProtocolPeersCarryTheSPI() throws {
        let source = Parser.parse(source: """
            @_spi(Isomer) @ExportedInterface
            public protocol Counter {
                func increment(by amount: Int) -> Int
            }
            """)
        let proto = try XCTUnwrap(source.statements.first?.item.as(ProtocolDeclSyntax.self))
        let attribute = try XCTUnwrap(proto.attributes.compactMap { $0.as(AttributeSyntax.self) }
            .first { $0.attributeName.trimmedDescription == "ExportedInterface" })
        let peers = try ExportedInterfaceMacro.expansion(
            of: attribute, providingPeersOf: proto, in: BasicMacroExpansionContext())
            .map(\.description).joined(separator: "\n")
        XCTAssertTrue(peers.contains("@_spi(Isomer) public final class SwiftFFIBox_Counter"), peers)
        XCTAssertTrue(peers.contains("@_spi(Isomer) public func swiftFFIRelease_Counter"), peers)
        XCTAssertFalse(peers.contains("@_spi(Isomer) final class"), peers)
        XCTAssertFalse(peers.contains("@_spi(Isomer)     public"), peers)
    }

    /// A `package` protocol's peers are `package` (a public declaration
    /// cannot name a package protocol).
    func testPackageProtocolPeersArePackage() throws {
        let source = Parser.parse(source: """
            @ExportedInterface
            package protocol Counter {
                func increment(by amount: Int) -> Int
            }
            """)
        let proto = try XCTUnwrap(source.statements.first?.item.as(ProtocolDeclSyntax.self))
        let attribute = try XCTUnwrap(proto.attributes.compactMap { $0.as(AttributeSyntax.self) }
            .first { $0.attributeName.trimmedDescription == "ExportedInterface" })
        let peers = try ExportedInterfaceMacro.expansion(
            of: attribute, providingPeersOf: proto, in: BasicMacroExpansionContext())
            .map(\.description).joined(separator: "\n")
        XCTAssertTrue(peers.contains("package final class SwiftFFIBox_Counter"), peers)
        XCTAssertTrue(peers.contains("package func swiftFFIRelease_Counter"), peers)
        XCTAssertFalse(peers.contains("public final class SwiftFFIBox_Counter"), peers)
    }
}
