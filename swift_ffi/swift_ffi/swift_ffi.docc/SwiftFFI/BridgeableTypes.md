# Bridgeable Types

What can cross the FFI boundary, and how each type travels.

## Value types

Scalars map to identical C representations; buffers are copied at the
boundary.

| Swift | C ABI | Kotlin | TypeScript |
| --- | --- | --- | --- |
| `Int` | `int64_t` | `Long` | `bigint` |
| `Int32` | `int32_t` | `Int` | `number` |
| `Double` | `double` | `Double` | `number` |
| `Bool` | `int32_t` (0/1) | `Boolean` | `boolean` |
| `String` | UTF-8 (pointer, length) in; +1 string box out | `String` | `string` |
| `[UInt8]` | (pointer, length) in; +1 byte box out | `ByteArray` | `Uint8Array` |

## Interfaces

An `@ExportedInterface` protocol crosses as an owned handle. Swift-owned
instances are boxed behind a retained opaque pointer with per-method
macro-expanded `@c` entries; consumers see an idiomatic wrapper class. Interfaces also
cross *into* Swift: a consumer-implemented instance travels as a foreign
reference, and the generated glue wraps it in a Swift proxy class that
implements the protocol by calling back out.

## Structs

An `@ExportedStruct` is a flat value type copied field-wise: every stored
property must be a bridgeable value type (no interfaces or nested structs).
On the C ABI a struct is a packed buffer of 8-byte slots, one per field.
Kotlin sees a `data class`; TypeScript sees a plain object interface.

## Effects

Exported free functions may be `async` and/or throwing. A throwing function
(or one returning `Result<T, E>` — recorded as `T` with the throwing bit)
bridges to `Result<T>` in Kotlin and a rejected promise/`Result` shape in
TypeScript. Interface *methods* may not be async or throwing.
