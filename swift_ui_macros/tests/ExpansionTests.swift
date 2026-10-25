import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import SwiftUIMacrosLibrary
import XCTest

/// The expansions as swift-syntax lays them out. That they are Apple's, to
/// the character, is swift_ui_macros/compare_with_xcode.sh's check.
final class ExpansionTests: XCTestCase {
    private let macros: [String: any Macro.Type] = [
        "State": StateMacro.self,
        "Entry": EntryMacro.self,
    ]

    func testInternalStateIsStoredInAState() {
        assertMacroExpansion(
            """
            struct V {
                @State var count: Int = 0
            }
            """,
            expandedSource: """
                struct V {
                    var count: Int {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = SwiftUI.State(initialValue: initialValue)
                        }
                        get {
                            _count.wrappedValue
                        }
                        nonmutating set {
                            _count.wrappedValue = newValue
                        }
                    }

                    private var _count = SwiftUI.State<Int>(initialValue: 0)

                    @SwiftUI._PropertyWrapperProjectedValue
                    var $count = SwiftUI.State<Int>(initialValue: 0).projectedValue
                }
                """,
            macros: macros
        )
    }

    func testDidSetRunsAfterTheWrite() {
        assertMacroExpansion(
            """
            struct V {
                @State var count: Int = 0 {
                    didSet { print(count) }
                }
            }
            """,
            expandedSource: """
                struct V {
                    var count: Int {
                        @storageRestrictions(initializes: _count)
                        init(initialValue) {
                            _count = SwiftUI.State(initialValue: initialValue)
                        }
                        get {
                            _count.wrappedValue
                        }
                        nonmutating set {
                            _count.wrappedValue = newValue
                            ({
                                print(count)
                                })()
                        }
                    }

                    private var _count = SwiftUI.State<Int>(initialValue: 0)

                    @SwiftUI._PropertyWrapperProjectedValue
                    var $count = SwiftUI.State<Int>(initialValue: 0).projectedValue
                }
                """,
            macros: macros
        )
    }

    func testEnvironmentEntry() {
        assertMacroExpansion(
            """
            extension EnvironmentValues {
                @Entry var tint: Int = 1
            }
            """,
            expandedSource: """
                extension EnvironmentValues {
                    var tint: Int {
                        get {
                            self[__Key_tint.self]
                        }
                        set {
                            self[__Key_tint.self] = newValue
                        }
                        _modify {
                            yield &self[__Key_tint.self]
                        }
                    }

                    private struct __Key_tint: SwiftUI.EnvironmentKey {
                        @SwiftUI.__EntryDefaultValue
                        static var defaultValue: Int = 1
                    }
                }
                """,
            macros: macros
        )
    }
}
