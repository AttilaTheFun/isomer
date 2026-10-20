# Parity reports

`parity.py` writes docs/parity/: for each Apple framework Isomer provides off
Apple platforms (SwiftUI, Foundation, CoreGraphics; Observation and
Synchronization, which are the Swift toolchain's), what of Apple's interface
Isomer implements, what it does not, why, and whether it is planned.

    tools/parity/parity.py              # builds Isomer's wasm modules, then compares
    tools/parity/parity.py --no-build   # compares the graphs the last run left

Both sides are symbol graphs: Apple's from the installed Xcode's iOS SDK
(`swift-symbolgraph-extract`, which also gives the Swift view of a C or
Objective-C framework), Isomer's from its modules as compiled for wasm (the
compiler writes their graphs as it compiles them: `-emit-symbol-graph`). A
declaration matches by its path, name with argument labels, and parameter
types. Apple's private (underscored), unavailable and deprecated declarations
are not counted; what the compiler gives a type (`hashValue`, `rawValue`) is
there when the type is.

`reasons/<Module>.json` sorts what is missing: groups matched by regular
expression on `Type.member(labels:)`, each excluded or not yet, with why and
the intent (planned, maybe, not planned); `newer` puts what Apple's SDK
introduced in a given iOS version or later into a group of its own;
`deviations` lists what is implemented differently. A missing declaration no
group claims is reported as not yet classified: add a group, or the
declaration.
