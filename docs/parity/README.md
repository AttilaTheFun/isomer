# What Isomer implements of Apple's frameworks

On Apple platforms an Isomer app uses Apple's frameworks. Elsewhere `import SwiftUI`, `Foundation`, `CoreGraphics`, `Metal`, `CoreTransferable`, `UniformTypeIdentifiers`, `PhotosUI`, `ImageIO`, `Observation` and `Synchronization` are Isomer's (or, for Observation and Synchronization, the Swift toolchain's own), with Apple's names and as much of Apple's interface as can be written in Swift. Each page says what is implemented, what is not, why, and whether it is planned, and would list what the module has that Apple's does not: declarations, other signatures or conformances. None has any but ImageIO, a known gap (superset.md): each other interface is a strict subset of Apple's, and `tools/parity/parity.py --check --strict` keeps it so.

Against Apple's iOS 27.0 SDK. Regenerate with `tools/parity/parity.py`.

missing/<Module>.md lists each module's missing declarations one by one, with Apple's signatures, by area and type (and the conformances, Sendable and overloads its types lack): what to choose the next work from. [superset.md](superset.md) is the other direction: what Isomer has beyond Apple's interfaces, checked or not, and what its own modules add.

| Module | Counted | Implemented | Excluded | Not yet | Unclassified | Missing, listed |
|---|---|---|---|---|---|---|
| [CoreGraphics](CoreGraphics.md) | 1357 | 425 (31%) | 627 | 303 | 2 | [missing/CoreGraphics.md](missing/CoreGraphics.md) |
| [Foundation](Foundation.md) | 12077 | 4753 (39%) | 3603 | 3721 | 0 | [missing/Foundation.md](missing/Foundation.md) |
| [SwiftUI](SwiftUI.md) | 7784 | 1907 (24%) | 530 | 5347 | 0 | [missing/SwiftUI.md](missing/SwiftUI.md) |
| [Metal](Metal.md) | 3580 | 860 (24%) | 1156 | 1563 | 1 | [missing/Metal.md](missing/Metal.md) |
| [CoreTransferable](CoreTransferable.md) | 83 | 1 (1%) | 2 | 80 | 0 | [missing/CoreTransferable.md](missing/CoreTransferable.md) |
| [UniformTypeIdentifiers](UniformTypeIdentifiers.md) | 229 | 32 (14%) | 8 | 189 | 0 | [missing/UniformTypeIdentifiers.md](missing/UniformTypeIdentifiers.md) |
| [PhotosUI](PhotosUI.md) | 246 | 26 (11%) | 126 | 94 | 0 | [missing/PhotosUI.md](missing/PhotosUI.md) |
| [ImageIO](ImageIO.md) | 869 | 15 (2%) | 0 | 854 | 0 | [missing/ImageIO.md](missing/ImageIO.md) |
| [Observation](Observation.md) | 60 | 25 (42%) | 0 | 35 | 0 | [missing/Observation.md](missing/Observation.md) |
| [Synchronization](Synchronization.md) | 325 | 316 (97%) | 0 | 9 | 0 | [missing/Synchronization.md](missing/Synchronization.md) |
