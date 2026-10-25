// SwiftUI's macros, declared as Apple's SwiftUI declares them since the iOS
// 27 SDK: `@State` is a macro (State.swift's property wrapper stays, for
// `State(initialValue:)` and code that names the type), and so is `@Entry`.
// //swift_ui_macros:SwiftUIMacros implements them, expanding them as Apple's
// plugin does (with this module named where Apple's name SwiftUICore); every
// SwiftUI library lists it in its `plugins` (swift_ui_macros/defs.bzl), so it
// is loaded for every module that depends on one.
//
// Declared only by Swift 6.4 and later. Apple's expansion of a private
// `@State` adds a private property with an init accessor, which before 6.4
// made the view's memberwise initializer private (`Foo(x: 1)` inaccessible):
// with the swift.org 6.3.2 toolchain (wasm, Android, Linux, Windows) `@State`
// is the property wrapper alone until Isomer's toolchain is 6.4; Apple
// platforms' builds, with Xcode's 6.4, have the macros.
//
// ISOMER_NO_SWIFTUI_MACROS leaves them out too, from the SwiftUI the
// Playground's compilers build against (wasm/libraries/hot_swift_ui): in a
// browser or on an iPhone no compiler plugin can run, and `@State` as the
// property wrapper alone means the same.

#if compiler(>=6.4) && !ISOMER_NO_SWIFTUI_MACROS

@attached(accessor, names: named(init), named(get), named(set)) @attached(peer, names: prefixed(`_`), prefixed(__), prefixed(`$`))
public macro State() = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")

@attached(accessor, names: named(init), named(get), named(set)) @attached(peer, names: prefixed(`_`), prefixed(__), prefixed(`$`))
public macro State<Value>(initialValue: Value) = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")

@attached(accessor, names: named(init), named(get), named(set)) @attached(peer, names: prefixed(`_`), prefixed(__), prefixed(`$`))
public macro State<Value>(wrappedValue: Value) = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")

@attached(accessor, names: named(init), named(get), named(set))
public macro _StatePropertyWrapperStorage(initialValue: String) = #externalMacro(module: "SwiftUIMacros", type: "StatePropertyWrapperStorageMacro")

@attached(accessor, names: named(init), named(get), named(set))
public macro _StatePropertyWrapperStorage() = #externalMacro(module: "SwiftUIMacros", type: "StatePropertyWrapperStorageMacro")

@attached(accessor, names: named(get))
public macro _StateInitialStoredValue(_ initialValue: String) = #externalMacro(module: "SwiftUIMacros", type: "StateInitialStoredValueMacro")

@attached(accessor, names: named(get))
public macro _StateProjectedValue() = #externalMacro(module: "SwiftUIMacros", type: "StateProjectedValueMacro")

@attached(accessor, names: named(get))
public macro _PropertyWrapperProjectedValue() = #externalMacro(module: "SwiftUIMacros", type: "ProjectedValueMacro")

@attached(accessor) @attached(peer, names: prefixed(__Key_))
public macro Entry() = #externalMacro(module: "SwiftUIMacros", type: "EntryMacro")

@attached(accessor)
public macro __EntryDefaultValue() = #externalMacro(module: "SwiftUIMacros", type: "EntryDefaultValueMacro")

@freestanding(expression)
public macro _SwiftUIEntryTypeCheck<T>(_ type: T.Type, macroName: String, propertyName: String) -> Void = #externalMacro(module: "SwiftUIMacros", type: "EntryTypeCheckMacro")

@freestanding(expression)
public macro _SwiftUIEntryTypeCheck<T>(_ type: T.Type, macroName: String, propertyName: String) -> Void = #externalMacro(module: "SwiftUIMacros", type: "EntryTypeCheckClassMacro") where T: AnyObject

@freestanding(expression)
public macro _SwiftUIEntryTypeCheck<T>(_ type: Optional<T>.Type, macroName: String, propertyName: String) -> Void = #externalMacro(module: "SwiftUIMacros", type: "EntryTypeCheckClassMacro") where T: AnyObject

#endif
