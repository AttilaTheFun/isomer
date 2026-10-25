// The toolchain's prebuilt macros as one executable plugin for the browser
// compiler, which serves both modules the iOS and Android Playgrounds load as
// libraries (ObservationMacros: @Observable; SwiftMacros: @TaskLocal,
// @OptionSet, @DebugDescription, the Swiftify and distributed macros). Those
// libraries have no `main` (the in-process plugin server finds their macros
// by name); built for wasm32-wasip1, swift-syntax's CompilerPlugin serves the
// compiler's requests through `swift_wasm_macro_v1_pump`. A macro is found by
// its type's module and name, so one plugin serves both modules
// (`-load-plugin-executable MacroPlugins.wasm#ObservationMacros,SwiftMacros`).

import ObservationMacros
import SwiftCompilerPlugin
import SwiftMacros
import SwiftSyntaxMacros

@main
struct MacroPlugins: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        ObservableMacro.self,
        ObservationTrackedMacro.self,
        ObservationIgnoredMacro.self,
        OptionSetMacro.self,
        DebugDescriptionMacro.self,
        DistributedResolvableMacro.self,
        TaskLocalMacro.self,
        SwiftifyImportMacro.self,
        SwiftifyImportProtocolMacro.self,
    ]
}
