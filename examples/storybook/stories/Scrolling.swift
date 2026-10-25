// Scrolling: vertical and horizontal scroll views, lazy stacks,
// scrolling from code, and what is moving a scroll.

import SwiftUI

extension StoryCatalog {
    static let scrolling = StoryArea(id: "scrolling", title: "Scrolling", symbol: "scroll", stories: [
        Story(
            "scrolling.vertical", "ScrollView and LazyVStack",
            height: 280,
            summary: "Content taller than its space, scrolled; a lazy stack makes rows only as they come into view."
        ) { VerticalScrollStory() },
        Story(
            "scrolling.horizontal", "Horizontal scrolling",
            summary: "A row of cards wider than the screen, scrolled sideways."
        ) { HorizontalScrollStory() },
        Story(
            "scrolling.reader", "ScrollViewReader",
            height: 300,
            summary: "Scrolling from code: to a row by its id, animated."
        ) { ScrollReaderStory() },
        Story(
            "scrolling.phase", "Scroll phases",
            height: 300,
            summary: "What is moving a scroll view, told as it changes: the reader's finger, the coast after they let go, an animated scroll from code, or nothing."
        ) {
            if #available(iOS 18.0, macOS 15.0, *) { ScrollPhaseStory() }
        },
    ])
}

// story: scrolling.vertical
struct VerticalScrollStory: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(1 ... 100, id: \.self) { row in
                    Text("Row \(row)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.blue.opacity(row % 2 == 0 ? 0.08 : 0.16))
                        .cornerRadius(8)
                }
            }
        }
    }
}
// end story

// story: scrolling.horizontal
struct HorizontalScrollStory: View {
    private let colors: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(colors.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 14)
                        .fill(LinearGradient(colors: [colors[index], colors[index].opacity(0.6)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 120, height: 90)
                        .overlay(Text("Card \(index + 1)").foregroundColor(.white).bold())
                }
            }
        }
        .frame(height: 100)
    }
}
// end story

// story: scrolling.reader
struct ScrollReaderStory: View {
    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 8) {
                HStack {
                    Button("Top") { withAnimation { proxy.scrollTo(1, anchor: .top) } }
                    Button("Row 25") { withAnimation { proxy.scrollTo(25, anchor: .top) } }
                    Button("Bottom") { withAnimation { proxy.scrollTo(50, anchor: .bottom) } }
                }
                .buttonStyle(.bordered)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(1 ... 50, id: \.self) { row in
                            Text("Row \(row)")
                                .padding(.vertical, 4)
                                .id(row)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}
// end story

// story: scrolling.phase
@available(iOS 18.0, macOS 15.0, *)
struct ScrollPhaseStory: View {
    @State private var phase = ScrollPhase.idle
    @State private var changes = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Phase: " + String(describing: phase)).font(.headline)
                Spacer()
                Text("\(changes) changes").foregroundColor(phase.isScrolling ? .blue : .secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(1 ... 50, id: \.self) { row in
                        Text("Row \(row)").padding(.vertical, 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollPhaseChange { _, newPhase in
                phase = newPhase
                changes += 1
            }
        }
    }
}
// end story
