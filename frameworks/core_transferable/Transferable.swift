// CoreTransferable's `Transferable`, as far as SwiftUI's pickers and drops
// take it: a type a picker or a drop hands over, its bytes (`Data`) or where
// they are (`URL`). Apple's SwiftUI re-exports CoreTransferable; Isomer's
// does too. Apple platforms use Apple's, but for a feature compiled against
// Isomer's frameworks there (apple/compiled), which has this one on every OS
// the app supports (Apple's needs iOS 16).

import Foundation

public protocol Transferable {}

extension Data: Transferable {}
extension URL: Transferable {}
extension String: Transferable {}
/// No item: a share preview without an image or icon (`SharePreview<Never, Never>`).
extension Never: Transferable {}
