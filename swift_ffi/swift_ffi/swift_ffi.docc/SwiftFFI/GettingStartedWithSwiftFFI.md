# Getting Started with SwiftFFI

Annotate a Swift library, wire two Bazel rules, and call the result from
Kotlin, TypeScript, C, or another Swift process.

## Annotate the exported surface

Mark the declarations that cross the boundary. Everything else in the module
stays private to Swift.

```swift
import IsomerFFI

@ExportedFunction
public func greeting(for name: String) -> String {
    "Hello, \(name)!"
}

@ExportedInterface
public protocol Counter {
    func increment() -> Int
    func label() -> String
}

@ExportedStruct
public struct TextMetrics {
    public var width: Double
    public var height: Double
}
```

The macros validate bridgeability at compile time — an unbridgeable parameter
type is an error in your source file, not a generator failure later.

## Generate the bridge

The Bazel rules run the analyzer and generator during the build. Wrap the
annotated library with the binding flavor each consumer needs — for example,
a wasm reactor plus TypeScript bindings:

```python
load("@isomer//swift_ffi/rules:swift_ffi.bzl", "ts_swift_library")

ts_swift_library(
    name = "greeter_web",
    swift = ":greeter",
)
```

The same annotated target feeds every backend: `kotlin_swift_library` for
Android (JNI glue + a Kotlin facade), `swift_host_library` for a native Swift
process embedding the reactor, and the C header/host kinds for C embedders.

## Call it from the consumer

```typescript
import { Greeter } from "./greeter_web.js";

const greeter = await Greeter.load(wasmBytes);
console.log(greeter.greeting("world"));
```

Interface instances arrive as idiomatic wrapper classes that own their Swift
handle (`AutoCloseable` in Kotlin, `Symbol.dispose` in TypeScript); see
<doc:OwnershipModel>.
