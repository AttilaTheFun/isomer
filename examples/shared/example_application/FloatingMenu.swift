import SwiftUI

/// A menu floated above a box by its alignment guide, as AgentUI's composer
/// floats its slash commands: the box sits right under the navigation bar,
/// so the menu reaches over the bar: drawn above it and taking the taps on
/// the web and Android (Isomer's floating layers), under it in the iPhone's
/// tree renderer for now. The words below say which was picked. Opened with
/// ISO_OPEN_APP=floatingmenu.
struct FloatingMenuScreen: View {
    @State private var picked = "none"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 44)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Button("/compact") { picked = "/compact" }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                        Button("/goal") { picked = "/goal" }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                    }
                    .frame(width: 200, alignment: .leading)
                    .background(Color.yellow.opacity(0.9), in: RoundedRectangle(cornerRadius: 12))
                    .alignmentGuide(.top) { $0[.bottom] + 6 }
                    .accessibilityIdentifier("floating-menu")
                }
            Text("picked=\(picked)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Floating Menu")
    }
}
