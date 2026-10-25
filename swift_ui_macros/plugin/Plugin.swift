// The SwiftUIMacros compiler plugin: Isomer's SwiftUI declares its macros
// with `#externalMacro(module: "SwiftUIMacros", ...)`, as Apple's does.

import SwiftCompilerPlugin
import SwiftSyntaxMacros

@main
struct SwiftUIMacrosPlugin: CompilerPlugin {
    let providingMacros: [any Macro.Type] = [
        StateMacro.self,
        StatePropertyWrapperStorageMacro.self,
        StateProjectedValueMacro.self,
        StateInitialStoredValueMacro.self,
        ProjectedValueMacro.self,
        EntryMacro.self,
        EntryDefaultValueMacro.self,
        EntryTypeCheckMacro.self,
        EntryTypeCheckClassMacro.self,
    ]
}
