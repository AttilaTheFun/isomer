// A long agent conversation in AgentUI's AgentView — the transcript Visor
// shows — for measuring how a large conversation scrolls and streams: user
// turns, markdown replies with lists and code, and tool-call rows. With
// streaming on (the button), the last reply grows a word at a time.
import AgentUI
import SwiftUI

@main
struct TranscriptStressApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TranscriptStressScreen()
                    .navigationTitle("Transcript")
            }
        }
    }
}

enum TranscriptStressData {
    static let replies = [
        "Here is what I found:\n\n- The **renderer** diffs the tree by key.\n- Rows that did not change are *skipped*.\n- Only the rows on screen are built.\n\nNext I'll measure it on the device.",
        "I updated `TreeEncoder.swift` so the diff matches children by identity:\n\n```swift\nfor child in new.children {\n    if let index = oldIndex[child.matchKey] {\n        order.append(Int32(index))\n    }\n}\n```\n\nThe tests pass.",
        "See https://example.com/documentation/a/very/long/path/that/has/no/spaces/anywhere/in/it/and/keeps/going/index.html and `Sources/Module/Subdirectory/AVeryLongFileNameThatGoesOnAndOnAndOn.swift`. The list keeps each row's identity, so inserting a message above doesn't touch the others.",
        "1. Build the app.\n2. Install it on the phone.\n3. Open a long conversation and scroll.\n\nIf frames drop, the trace will say whether it's composition, layout or drawing.",
    ]

    static let messages: [TranscriptMessage] = (0..<300).map { index in
        switch index % 4 {
        case 0:
            // Every third question carries text with nowhere to break (a
            // URL, a path): it wraps inside the bubble, not past the screen.
            let unbroken = index % 12 == 8
                ? " https://example.com/releases/download/v0.10/a-very-long-artifact-name-with-no-spaces-in-it-at-all.tar.gz and /workspace/project/Sources/Module/Subdirectory/AnotherDirectory/AVeryLongFileNameThatGoesOnAndOn.swift"
                : ""
            return TranscriptMessage(id: "m\(index)", role: .user, text: "Question \(index / 4): can you check how the list behaves when the conversation gets long?" + unbroken)
        case 1:
            return TranscriptMessage(id: "m\(index)", role: .tool, text: "ok", toolName: "Bash")
        default:
            return TranscriptMessage(id: "m\(index)", role: .assistant, text: replies[index % replies.count], activities: ["Reading files"])
        }
    }
}

struct TranscriptStressScreen: View {
    @State private var messages = TranscriptStressData.messages
    @State private var draft = ""
    @State private var streaming = false

    var body: some View {
        AgentView(messages: messages, activity: streaming ? "Writing…" : nil,
                  emptyBody: "", emptyFootnote: "", draft: $draft, busy: streaming,
                  send: {}, stop: { streaming = false }) {
            Button { streaming.toggle() } label: { AgentPillLabel(streaming ? "Stop stream" : "Stream") }.agentPillButton()
        } attachments: {
            EmptyView()
        }
        .task {
            let words = "the list builds only what is on screen and keeps every row it did not change".split(separator: " ")
            var tick = 0
            while true {
                try? await Task.sleep(nanoseconds: 80_000_000)
                guard streaming else { continue }
                tick += 1
                if tick % 60 == 1 {
                    messages.append(TranscriptMessage(id: "s\(tick)", role: .assistant, text: ""))
                }
                let last = messages.count - 1
                messages[last] = TranscriptMessage(id: messages[last].id, role: .assistant,
                                                   text: messages[last].text + (messages[last].text.isEmpty ? "" : " ") + words[tick % words.count])
            }
        }
    }
}
