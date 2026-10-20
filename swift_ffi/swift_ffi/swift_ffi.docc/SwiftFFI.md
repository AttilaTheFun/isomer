# ``SwiftFFI``

SwiftFFI bridges Swift libraries to native, WebAssembly, Android, and web
consumers from a single annotated source of truth.

## Overview

The SwiftFFI module provides three validating macros — ``ExportedFunction()``,
``ExportedInterface()``, and ``ExportedStruct()`` — that mark the declarations
crossing the FFI boundary. The macros reject unbridgeable signatures at
compile time, in your source; they emit no FFI code themselves.

The bridge itself is produced during the build: a Bazel aspect runs the
analyzer over the annotated sources to extract a JSON intermediate
representation, and the generator consumes the merged IR to emit both halves
of every binding — the macro-expanded `@c` C ABI inside the module, and idiomatic
consumer bindings (Kotlin, TypeScript, a C header, or a Swift/C wasm host
facade) on the other.

Ownership follows the swift-java model: interface instances and string
returns cross the boundary as +1 retained handles the consumer releases
exactly once; parameters are borrowed for the call.

## Topics

### Essentials

- <doc:GettingStartedWithSwiftFFI>
- <doc:BridgeableTypes>
- <doc:OwnershipModel>

### Macros

- ``ExportedFunction()``
- ``ExportedInterface()``
- ``ExportedStruct()``
