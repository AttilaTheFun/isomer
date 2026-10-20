import SwiftFFIPluginLibrary

// The test-local conforming types (the real ones live in the plugin binary,
// which a test can't link — the protocols carry the implementations).
struct ExportedFunctionMacro: ExportedFunctionMacroProtocol {}
struct ExportedInterfaceMacro: ExportedInterfaceMacroProtocol {}
struct ExportedStructMacro: ExportedStructMacroProtocol {}
