// The dependency-injection story (docs/wasm_di.md): a host embeds a bridged
// feature and injects services keyed by an @ExportedEnum; the guest looks
// them up through this module-neutral API:
//
//     if let counter = dependencies[GreeterDependencyKey.counter] as? Lazy<any Counter> {
//         counter.value.increment()
//     }
//
// In-process (compiled) embeddings install real instances with
// `installDependencies`. Wasm reactors resolve through the fixed
// `swift_ffi.dependency_get` import instead: the host answers with the
// interface's registry key + a foreign id, and the proxy factory that
// `swift_ffi_[ns_]register_<Interface>` (a macro-expanded export the host's
// generated loader calls at setup) registered for that key constructs a
// typed dispatcher-backed proxy.

import SwiftABI

/// A value a host may inject as a dependency: an `@ExportedInterface`
/// implementation, or a `Lazy` of one (deferring host-side construction to
/// the guest's first unwrap).
public protocol AnyExportable {}

extension Lazy: AnyExportable {}

/// The guest-side dependency dictionary, keyed by any String-raw-value key
/// (typically an `@ExportedEnum`).
public struct SwiftFFIDependencies {
    /// Creates the (stateless) dictionary facade; use the shared
    /// `dependencies` global instead of constructing your own.
    public init() {}

    /// Resolves the dependency installed under `key` (any String-raw enum —
    /// typically an `@ExportedEnum`), or nil when the host injected nothing
    /// for it. Cast the result to the expected shape, e.g.
    /// `dependencies[Key.fooService] as? Lazy<any FooService>`.
    public subscript(key: some RawRepresentable<String>) -> Any? {
        if let resolver = swiftFFIDependencyResolver {
            return resolver(key.rawValue)
        }
        #if os(WASI)
        return swiftFFIWasmResolve(key.rawValue)
        #else
        return nil
        #endif
    }
}

/// An in-process resolver (compiled embeddings). When nil, wasm reactors
/// fall through to the `dependency_get` import; everywhere else lookups
/// resolve to nil.
public nonisolated(unsafe) var swiftFFIDependencyResolver: ((String) -> Any?)?

/// In-process injection for compiled embeddings, where the host and the
/// feature share one process (no reactor, no proxies): the host installs its
/// dictionary before the feature's first resolution, keyed by the same
/// String-raw enum the guest resolves with. Wasm hosts inject through the
/// `dependency_get` import instead and never call this.
public func installDependencies<Key: RawRepresentable<String> & Hashable>(
    _ entries: [Key: any AnyExportable]
) {
    let byRawValue = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.rawValue, $0.value) })
    // Installs ACCUMULATE: a host installs its core table and then optional
    // services (an image picker, device motion, preferences) in separate
    // calls; the newest entry for a key wins, earlier tables stay reachable.
    let previous = swiftFFIDependencyResolver
    swiftFFIDependencyResolver = { key in byRawValue[key] ?? previous?(key) }
}

/// The dependencies the embedding host injected.
public nonisolated(unsafe) let dependencies = SwiftFFIDependencies()

// MARK: - The wasm proxy-factory registry

/// Constructs a typed dispatcher-backed proxy for one `@ExportedInterface`:
/// `direct` yields `any P`, `lazy` yields `Lazy<any P>` (both erased to
/// `Any` for the registry — the closures carry the real types, so consumer
/// casts like `as? Lazy<any P>` succeed).
public struct SwiftFFIDependencyFactory {
    let direct: (any SwiftFFIDispatcher) -> Any
    let lazy: (any SwiftFFIDispatcher) -> Any

    public init(
        direct: @escaping (any SwiftFFIDispatcher) -> Any,
        lazy: @escaping (any SwiftFFIDispatcher) -> Any
    ) {
        self.direct = direct
        self.lazy = lazy
    }
}

private nonisolated(unsafe) var swiftFFIDependencyFactories: [String: SwiftFFIDependencyFactory] = [:]

/// Registers the proxy factory for one interface under its symbolic registry
/// key (`swift_ffi_[<ns>_]<Interface>`). Called by the macro-expanded
/// `register_<Interface>` exports — hosts invoke those at setup when they
/// inject dependencies.
public func swiftFFIRegisterDependencyFactory(
    key: String, factory: SwiftFFIDependencyFactory
) {
    swiftFFIDependencyFactories[key] = factory
}

#if os(WASI)

/// Resolves one key through the host: `dependency_get` answers with a blob
/// `.list([.bool(lazy), .string(registry key), .int32(foreign id)])` (packed
/// (len << 32) | ptr, +1 via swift_ffi_alloc), matched to a registered
/// factory by the registry key.
func swiftFFIWasmResolve(_ key: String) -> Any? {
    let keyBytes = Array(key.utf8)
    let packed = keyBytes.withUnsafeBytes {
        swift_ffi_wasm_dependency_get($0.baseAddress, Int32($0.count))
    }
    guard packed != 0 else { return nil }
    let blob = SwiftFFIBridge.unpackForeignBytes(packed)
    guard case .list(let items)? = try? SwiftFFIBlob.decode(blob),
        items.count == 3,
        case .bool(let lazyFlag) = items[0],
        case .string(let registryKey) = items[1],
        case .int32(let id) = items[2],
        let factory = swiftFFIDependencyFactories[registryKey]
    else { return nil }
    let dispatcher = SwiftFFIWasmDispatcher(id: id)
    return lazyFlag ? factory.lazy(dispatcher) : factory.direct(dispatcher)
}

#endif  // os(WASI)
