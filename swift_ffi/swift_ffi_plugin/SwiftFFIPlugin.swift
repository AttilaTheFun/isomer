import SwiftCompilerPlugin
import SwiftFFIPluginLibrary
import SwiftSyntaxMacros

// MARK: Exported-surface Macros

public struct ExportedEnumMacro: ExportedEnumMacroProtocol {}
public struct ExportedFunctionMacro: ExportedFunctionMacroProtocol {}
public struct ExportedInterfaceMacro: ExportedInterfaceMacroProtocol {}
public struct ExportedStructMacro: ExportedStructMacroProtocol {}

// MARK: SwiftFFI Plugin

@main
struct SwiftFFIPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        ExportedEnumMacro.self,
        ExportedFunctionMacro.self,
        ExportedInterfaceMacro.self,
        ExportedStructMacro.self,
    ]
}
