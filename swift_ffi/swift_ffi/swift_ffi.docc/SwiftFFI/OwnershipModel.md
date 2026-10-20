# Ownership Model

Who retains what, on both sides of the boundary.

## The swift-java convention

SwiftFFI follows the ownership model of
[swift-java](https://github.com/swiftlang/swift-java): values returned across
the boundary are **+1** (the receiver owns the reference and must release it
exactly once), and parameters are **borrowed** for the duration of the call.

## Interface handles

- A Swift instance returned to a consumer is boxed and retained; the
  generated wrapper (Kotlin `AutoCloseable`, TypeScript `Symbol.dispose`)
  releases the handle on `close()`/disposal, with the collector as backstop.
- A consumer instance passed into Swift is parked in the consumer's foreign
  registry (a JNI global ref on Android; a registry entry on the web). The
  generated Swift proxy retains it and releases the entry when ARC drops
  the proxy.

## Strings and byte arrays

Inbound, strings and `[UInt8]` travel as borrowed (pointer, length) buffers
the glue copies immediately. Outbound, the glue returns a +1 box the consumer
copies out of and releases in the same call.

## Struct buffers

A struct crosses as a packed slot buffer owned by whoever allocated it;
string/byte fields inside the buffer are freed by whichever side *reads*
the slot.
