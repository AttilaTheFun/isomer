// Gestures: taps, drags, magnification and hover.

import SwiftUI

extension StoryCatalog {
    static let gestures = StoryArea(id: "gestures", title: "Gestures", symbol: "hand.draw", stories: [
        Story(
            "gestures.tap", "Taps", apis: [".onTapGesture(count:perform:)", ".contentShape(_:)"],
            summary: "Single and double taps on any view; a content shape makes its empty space tappable too."
        ) { TapStory() },
        Story(
            "gestures.drag", "DragGesture", apis: ["DragGesture()", ".gesture(_:)", ".onChanged(_:)", ".onEnded(_:)"],
            summary: "A view that follows the finger or pointer, and springs back when let go."
        ) { DragStory() },
        Story(
            "gestures.magnify", "MagnifyGesture", apis: ["MagnifyGesture()", "MagnifyGesture.Value.magnification"],
            summary: "A pinch that scales a view, on a touch screen or a trackpad."
        ) { MagnifyStory() },
        Story(
            "gestures.hover", "Hover", apis: [".onHover(perform:)"],
            summary: "Whether the pointer is over a view: on the Mac, the web and Windows, and with a mouse or trackpad on iPad and Android."
        ) { HoverStory() },
    ])
}

// story: gestures.tap
struct TapStory: View {
    @State private var taps = 0
    @State private var doubleTaps = 0

    var body: some View {
        HStack(spacing: 16) {
            Text("Tap: \(taps)")
                .frame(width: 130, height: 70)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(12)
                .onTapGesture { taps += 1 }
            HStack {
                Text("Double tap: \(doubleTaps)")
                Spacer()
            }
            .padding()
            .frame(width: 170, height: 70)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTaps += 1 }
        }
    }
}
// end story

// story: gestures.drag
struct DragStory: View {
    @State private var offset = CGSize.zero

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.secondary.opacity(0.1))
            Circle()
                .fill(Color.purple)
                .frame(width: 60, height: 60)
                .offset(x: offset.width, y: offset.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in offset = value.translation }
                        .onEnded { _ in withAnimation(.spring) { offset = .zero } }
                )
        }
        .frame(height: 180)
    }
}
// end story

// story: gestures.magnify
struct MagnifyStory: View {
    @State private var scale = 1.0
    @State private var settled = 1.0

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo")
                .font(.system(size: 60))
                .scaleEffect(scale)
                .frame(height: 140)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in scale = settled * value.magnification }
                        .onEnded { _ in settled = scale }
                )
            Text("Scale \(String(format: "%.2f", scale))×")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }
}
// end story

// story: gestures.hover
struct HoverStory: View {
    @State private var hovering = false

    var body: some View {
        Text(hovering ? "The pointer is over me" : "Point at me")
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(hovering ? Color.green.opacity(0.3) : Color.secondary.opacity(0.1))
            .cornerRadius(12)
            .onHover { hovering = $0 }
    }
}
// end story
