# Wasm dependency injection

A native host embeds a bridged wasm feature and injects services keyed by an
`@ExportedEnum`; the guest looks them up through the module-neutral
`dependencies` dictionary. Implemented end to end (the TS, Swift-host, and
C-host loaders all offer the same dictionary); isomer's WasmView is the
flagship integration.

## The shape

Host (Swift shown; TS and C are equivalent — see the generated
`Dependencies` builders / the `<mod>_dependency` table):

```swift
let bridge = try Greeter.load(
    engine: engine, wasm: bytes,
    dependencies: ["counter": Dependencies.counter { CounterImpl() }])
```

- The **keys** are the raw values of an `@ExportedEnum` (String-raw) the
  feature module declares — shared vocabulary between host and guest:

  ```swift
  @ExportedEnum
  public enum GreeterDependencyKey: String {
      case counter
  }
  ```

- The **values** wrap an `@ExportedInterface` implementation as an ordinal
  blob DISPATCHER (the same channel closures and foreign objects use), plus
  a `lazy` flag deferring host-side construction to the guest's first use.

Guest (wasm Swift):

```swift
if let counter = dependencies[GreeterDependencyKey.counter] as? Lazy<any Counter> {
    counter.value.increment()
}
```

In-process compiled embeddings skip all of this: the host calls
`installDependencies([Key.counter: Lazy { CounterImpl() }])` and the guest
resolves real instances.

## Mechanics (docs/abi.md has the full contract)

- Each `@ExportedInterface` expansion emits a
  `swift_ffi_[<ns>_]register_<Proto>` export that files a typed proxy
  factory in the guest under the interface's **registry key**
  (`swift_ffi_[<ns>_]<Proto>`). Generated host loaders call every register
  export at setup.
- A guest lookup calls the fixed `dependency_get(key_ptr, key_len)` import.
  The host answers 0 (absent) or a packed +1 blob of
  `.list([.bool(lazy), .string(registry key), .int32(dispatcher id)])`.
- The guest matches the registry key to a factory and constructs a typed
  dispatcher-backed proxy — `any Proto`, or `Lazy<any Proto>` when the host
  injected lazily — so the consumer-side casts are exact.
- Method calls dispatch through the fixed `closure_invoke` import as
  ordinal-led blobs; the host releases its registry entry when the guest
  proxy deinits (`foreign_release`).

Hosts that inject nothing still bind all six fixed imports (see
docs/abi.md) — `dependency_get` just answers 0.
