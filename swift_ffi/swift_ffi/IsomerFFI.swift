// IsomerFFI (swift_ffi) — the public surface of the swift_ffi bridge.
//
// These macros annotate the Swift declarations that cross the FFI boundary —
// and they GENERATE the module's entire C ABI as peer declarations, using the
// formalized `@c` attribute (SE-0495): `@c(swift_ffi_[<namespace>_]<name>)`
// entry thunks for functions, and box/proxy/`_invoke`/`_release`/`register`
// peers for interfaces. The annotated `swift_library` is self-contained — no
// generated glue module exists. A Bazel aspect still analyzes the annotated
// sources, but only to generate CONSUMER-side artifacts (the C header and the
// idiomatic Kotlin / TypeScript / C++ / host bindings). See docs/abi.md.
//
// `namespace:` (a lowercase C-identifier string literal) segments the
// C symbol names — `swift_ffi_<namespace>_<name>` — so several bridged
// modules can link into one image without colliding. Macros expand per
// declaration and cannot see the rest of the module, so the namespace is
// written on each exported declaration (not declared once per module).

/// Marks a `public` free (global) function for export across the FFI boundary.
///
/// Bridgeable parameter and return types: `Int`, `Int32`, `Double`, `Bool`,
/// `String` / `[UInt8]` (copied at the boundary), `@ExportedStruct` values,
/// `@ExportedEnum` values, any `@ExportedInterface` protocol (crossing as an
/// owned handle), and `Void` returns. Also supported: generic functions whose
/// type parameters are constrained to `Bridgeable` (and inferable from a
/// parameter), closure parameters over bridgeable types, `Result` as a
/// first-class value, `Lazy<T>` returns, `async`, and `throws`.
///
///     @ExportedFunction
///     public func greeting(for name: String) -> String {
///         "Hello, \(name)!"
///     }
///
/// The expansion adds a peer `@c(swift_ffi_[<ns>_]greeting)` entry marshaling
/// the flat C ABI (see docs/abi.md for the conventions).
@attached(peer, names: prefixed(swift_ffi_), prefixed(swiftFFIThunk_))
public macro ExportedFunction() =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedFunctionMacro")

/// `namespace:` names the C symbol segment: `swift_ffi_<namespace>_<name>`.
@attached(peer, names: prefixed(swift_ffi_), prefixed(swiftFFIThunk_))
public macro ExportedFunction(namespace: String) =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedFunctionMacro")

/// Marks a `public` protocol for export across the FFI boundary.
///
/// Instances cross as owned handles: the expansion boxes `any Proto` behind a
/// retained opaque pointer, and consumers see an idiomatic wrapper type (a
/// Kotlin class implementing `AutoCloseable`, a TypeScript class with
/// `Symbol.dispose`) whose methods dispatch through the generated
/// `@c(swift_ffi_[<ns>_]<Proto>_invoke)` entry as ordinal-led blob calls.
/// Ownership follows the swift-java model: returns are +1 (the consumer
/// wrapper owns the reference and releases it via `_release`), parameters
/// are borrowed for the call. Consumer-side implementations cross the other
/// way as dispatchers behind a generated foreign proxy, and the interface can
/// be injected as a wasm dependency (docs/wasm_di.md) via the generated
/// `register` export.
///
///     @ExportedInterface
///     public protocol Counter {
///         func increment() -> Int
///         func label() -> String
///     }
///
/// A `@MainActor` protocol is called on the main actor: its Swift-owned
/// instances there, and the host's (a proxy made anywhere) from it, so an
/// app keeps one without leaving the main actor.
@attached(
    peer,
    names: prefixed(SwiftFFIBox_), prefixed(SwiftFFIForeign_), prefixed(swiftFFIResolve_),
    prefixed(swiftFFIInvoke_), prefixed(swiftFFIInvokeIsolated_), prefixed(swiftFFIRelease_),
    prefixed(swiftFFIRegister_))
public macro ExportedInterface() =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedInterfaceMacro")

/// `namespace:` names the C symbol segment: `swift_ffi_<namespace>_<Proto>_*`.
@attached(
    peer,
    names: prefixed(SwiftFFIBox_), prefixed(SwiftFFIForeign_), prefixed(swiftFFIResolve_),
    prefixed(swiftFFIInvoke_), prefixed(swiftFFIInvokeIsolated_), prefixed(swiftFFIRelease_),
    prefixed(swiftFFIRegister_))
public macro ExportedInterface(namespace: String) =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedInterfaceMacro")

/// Marks a `public` struct for export across the FFI boundary.
///
/// Exported structs are flat *value* types: every stored property must be a
/// bridgeable value type (`Int`, `Int32`, `Double`, `Bool`, `String`,
/// `[UInt8]` — no interfaces or nested structs). Instances are copied
/// field-wise at the boundary: Kotlin sees a `data class`, TypeScript a plain
/// object interface. The macro synthesizes the public memberwise initializer
/// and the `Bridgeable` conformance (structs travel as self-describing blobs,
/// identified on the wire by their type name).
///
///     @ExportedStruct
///     public struct TextMetrics {
///         public let width: Double
///         public let height: Double
///     }
@attached(member, names: named(init))
@attached(extension, conformances: Bridgeable, names: named(init(bridgeValue:)), named(bridgeValue))
public macro ExportedStruct() =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedStructMacro")

/// Marks a `public` raw-value enum (`String` or `Int` raw type, no associated
/// values) for export across the FFI boundary.
///
/// Exported enums cross by raw value: Kotlin sees an `enum class`, TypeScript
/// a literal union, C++ an `enum class` (Int-raw) or string constants. The
/// macro generates the `Bridgeable` conformance, so exported enums also work
/// as generic arguments, `Result` payloads — and as the keys of a wasm
/// dependency dictionary:
///
///     @ExportedEnum
///     public enum DependencyKey: String {
///         case fooService
///     }
@attached(extension, conformances: Bridgeable, names: named(init(bridgeValue:)), named(bridgeValue))
public macro ExportedEnum() =
    #externalMacro(module: "SwiftFFIPlugin", type: "ExportedEnumMacro")
