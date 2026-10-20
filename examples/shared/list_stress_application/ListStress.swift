// A chat-shaped List under load: a long thread of identified rows whose last
// row streams words in while new rows arrive, the shape of an agent
// transcript. It measures what a streaming update costs a host (a long list
// should cost what the rows that changed cost, as it does on iOS) and checks
// that rows keep their identity, the list opens at the bottom and follows
// new rows. Launch hooks (read with getenv, as the other examples do):
// ISO_STRESS_ROWS sets the starting row count (default 400);
// ISO_STRESS_PAUSED=1 starts without streaming.
import SwiftUI
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Android)
import Android
#endif

@main
struct ListStressApp: App {
    var body: some Scene {
        WindowGroup {
            ListStressView()
        }
    }
}

struct StressMessage: Identifiable, Equatable {
    let id: Int
    var author: String
    var text: String

    static let initial = initialMessages()
}

private let words = "the quick brown fox jumps over a lazy dog while agents stream tokens into a long transcript that keeps growing at the bottom".split(separator: " ").map(String.init)

private func launchValue(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

private func initialMessages() -> [StressMessage] {
    let count = Int(launchValue("ISO_STRESS_ROWS") ?? "") ?? 400
    return (0..<count).map { index in
        StressMessage(id: index, author: index % 2 == 0 ? "You" : "Agent", text: sentence(index, 12 + index % 30))
    }
}

private func sentence(_ seed: Int, _ length: Int) -> String {
    (0..<length).map { words[($0 * 7 + seed * 13) % words.count] }.joined(separator: " ")
}

struct ListStressView: View {
    // The starting rows are made once: a view struct is made again on every
    // update (here and in SwiftUI), and so is a `@State` default with it.
    @State private var messages: [StressMessage] = StressMessage.initial
    @State private var streaming = launchValue("ISO_STRESS_PAUSED") != "1"
    @State private var ticks = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(messages.count) rows, \(ticks) updates").font(.footnote).foregroundColor(.secondary)
                Spacer()
                Button(streaming ? "Pause" : "Stream") { streaming.toggle() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            ScrollViewReader { proxy in
                List {
                    ForEach(messages) { message in
                        StressRow(message: message)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .listStyle(.plain)
                .defaultScrollAnchor(.bottom)
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .task {
            // About 25 updates a second: a word onto the last row, and every
            // 40th a new row, as an agent streams.
            while true {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard streaming else { continue }
                ticks += 1
                if ticks % 40 == 0 {
                    let id = (messages.last?.id ?? 0) + 1
                    messages.append(StressMessage(id: id, author: id % 2 == 0 ? "You" : "Agent", text: ""))
                } else if !messages.isEmpty {
                    messages[messages.count - 1].text += (messages[messages.count - 1].text.isEmpty ? "" : " ") + words[ticks % words.count]
                }
            }
        }
    }
}

struct StressRow: View {
    let message: StressMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(message.author).font(.headline)
                Spacer()
                Text("#\(message.id)").font(.caption).foregroundColor(.secondary)
            }
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.body)
        }
        .padding(.vertical, 4)
        .contextMenu { Button("Copy") {} }
    }
}
