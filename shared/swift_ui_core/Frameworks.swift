// The other Apple frameworks SwiftUI's interface names, as Isomer has them:
// CoreTransferable, re-exported as Apple's SwiftUI re-exports it, and
// UniformTypeIdentifiers, imported, not re-exported (an app imports it to
// name `UTType`), as Apple's SwiftUI has it. Combine, UIKit and Dispatch
// are not among them: their APIs exist for backward compatibility, and
// Isomer's apps use Observation, SwiftUI and Swift concurrency
// (2026-10-12). Copying and pasting text is the Isomer module's
// `Clipboard`.

@_exported import CoreTransferable
import UniformTypeIdentifiers
