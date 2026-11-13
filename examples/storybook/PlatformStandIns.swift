// iOS's SwiftUI API that one source uses on every platform, without
// `#if os(iOS)`: Apple's own on iOS, Isomer's SwiftUI's elsewhere, and on
// the Mac the Isomer module's stand-ins (apple/libraries/swift_ui/
// AppleMacStandIns.swift). Built with the Storybook so every platform's
// build checks it; shown nowhere.

import Isomer
import SwiftUI

struct PlatformStandIns: View {
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Stand-ins")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
