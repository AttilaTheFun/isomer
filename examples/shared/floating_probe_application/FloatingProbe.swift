// A menu floated above a box by its alignment guide, as AgentUI's composer
// floats its slash commands, with the box right under the navigation bar:
// the menu reaches over the bar. The web and Android draw it above the bar
// (Isomer's floating layers); the iPhone's tree renderer
// (apple/floating_probe_wasm_ios_application, which opens straight onto it)
// does not yet: there the bar is drawn over it. The words below say which
// command was picked. At the bottom, the same commands as a popover hanging
// from the top of a box, as AgentUI's are on an iPhone or iPad (shown from
// the start; a tap outside puts it away): the iPhone's tree renderer
// presents it as SwiftUI's own, anchored, arrow down.

import SwiftUI

@main
struct FloatingProbeApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack { FloatingProbe() }
        }
    }
}

struct FloatingProbe: View {
    @State private var picked = "none"
    @State private var popover = true

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
                }
            Text("picked=\(picked)")
            Spacer(minLength: 0)
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.gray.opacity(0.15))
                .frame(height: 88)
                .overlay(alignment: .topLeading) {
                    Color.clear
                        .frame(width: 44, height: 1)
                        .popover(isPresented: $popover, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                Button("/compact") { picked = "/compact"; popover = false }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                Button("/goal") { picked = "/goal"; popover = false }
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                            }
                            .padding(6)
                            .frame(width: 300, alignment: .leading)
                            .presentationCompactAdaptation(.popover)
                        }
                }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Floating Probe")
    }
}
