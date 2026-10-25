// The user's run fills the screen with no chrome — the project's SwiftUI IS
// the app — so the way out is a shake: `ShakeToLeave` wraps the run surface
// (a WasmView on iOS, the page's run overlay on the web) and asks before
// leaving. The surface is injected; the shell is shared.

import SwiftUI

public struct ShakeToLeave<Surface: View>: View {
    let title: String
    let message: String
    let leaveTitle: String
    let surface: Surface
    let onLeave: () -> Void
    @State private var askDismiss = false

    public init(title: String = "Leave the app?", message: String = "Shake again any time to get back here.",
                leaveTitle: String = "Leave", onLeave: @escaping () -> Void, @ViewBuilder surface: () -> Surface) {
        self.title = title
        self.message = message
        self.leaveTitle = leaveTitle
        self.onLeave = onLeave
        self.surface = surface()
    }

    public var body: some View {
        surface
            // A fresh cover starts without the question (state can outlive a
            // dismissed presentation on the reimplementation).
            .onAppear { askDismiss = false }
            .onShake { askDismiss = true }
            .alert(title, isPresented: $askDismiss) {
                Button(leaveTitle, role: .destructive) {
                    askDismiss = false
                    onLeave()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(message)
            }
    }
}
