// The standalone @main wrapper that turns the OrderStatusCard feature into a
// runnable single-screen app (the "partial" compiled/wasm entry on platforms
// that run the feature as a whole app). It lives in its own file so hosts that
// EMBED the feature as a plain view — Apple's example_partial_compiled native
// SwiftUI host — can compile `OrderStatusCard.swift` alone, without a second
// @main colliding with their own app entry.

import SwiftUI

@main
struct EmbeddedExample: App {
    var body: some Scene {
        WindowGroup("Order Status") {
            OrderStatusCard()
        }
    }
}
