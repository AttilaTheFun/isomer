# Observation for compiled features

Swift's Observation module for an Apple app's feature compiled against
Isomer's frameworks (apple/compiled), on any iOS the app supports: Apple's
needs iOS 17 and macOS 14. The sources are the Swift toolchain's own, the
same open-source module Isomer's other platforms use, at swift-6.3.2-RELEASE
(stdlib/public/Observation/Sources/Observation), under their license
(Apache 2.0 with the Runtime Library Exception, https://swift.org/LICENSE.txt).

What differs from the toolchain's:

- `ThreadLocal.swift` is Isomer's: pthread thread-local storage in place of
  ThreadLocal.cpp, which reads the runtime's private headers.
- `Observations.swift` (the asynchronous sequence of changes, Swift 6.2) is
  left out: its iterator needs the iOS 18 concurrency runtime.
- The `SwiftStdlib` availability names are defined as iOS 13 and macOS
  10.15, so nothing in it is newer than the app.

`@Observable` expands with the toolchain's ObservationMacros plugin; the
module mapping (//apple/compiled:mapping) names this module where code says
`Observation`, Apple's Foundation's re-export of it included.
