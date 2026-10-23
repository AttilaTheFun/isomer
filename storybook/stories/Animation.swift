// Animation: explicit and implicit animation, transforms and transitions.

import SwiftUI

extension StoryCatalog {
    static let animation = StoryArea(id: "animation", title: "Animation", symbol: "wand.and.stars", stories: [
        Story(
            "animation.explicit", "withAnimation",
            summary: "A state change made inside withAnimation: every view it changes moves there over time."
        ) { ExplicitAnimationStory() },
        Story(
            "animation.implicit", "Animating a value",
            summary: "A view that animates whenever one value changes, however it changes."
        ) { ImplicitAnimationStory() },
        Story(
            "animation.transforms", "Transforms",
            summary: "A view rotated, scaled and moved without changing its layout."
        ) { TransformsStory() },
        Story(
            "animation.transition", "Transitions",
            summary: "How a view arrives and leaves when it is added and removed."
        ) { TransitionStory() },
    ])
}

// story: animation.explicit
struct ExplicitAnimationStory: View {
    @State private var moved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(moved ? "Back" : "Move") {
                withAnimation(.easeInOut(duration: 0.6)) { moved.toggle() }
            }
            .buttonStyle(.bordered)
            RoundedRectangle(cornerRadius: 12)
                .fill(moved ? Color.orange : Color.blue)
                .frame(width: moved ? 140 : 60, height: 60)
                .offset(x: moved ? 120 : 0)
            Text("Hello, animation!")
                .opacity(moved ? 1 : 0)
        }
    }
}
// end story

// story: animation.implicit
struct ImplicitAnimationStory: View {
    @State private var big = false

    var body: some View {
        HStack(spacing: 30) {
            Circle()
                .fill(Color.pink)
                .frame(width: 50, height: 50)
                .scaleEffect(big ? 1.6 : 1)
                .animation(.spring, value: big)
            Button(big ? "Shrink" : "Grow") { big.toggle() }
                .buttonStyle(.bordered)
        }
        .frame(height: 90)
    }
}
// end story

// story: animation.transforms
struct TransformsStory: View {
    @State private var angle = 30.0
    @State private var scale = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 40) {
                Image(systemName: "airplane")
                    .font(.system(size: 40))
                    .rotationEffect(.degrees(angle))
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green)
                    .frame(width: 40, height: 40)
                    .scaleEffect(scale)
                Text("Offset")
                    .offset(x: 10, y: -10)
            }
            .frame(height: 80)
            Text("Rotation \(Int(angle))°")
            Slider(value: $angle, in: 0 ... 360)
            Text("Scale \(String(format: "%.1f", scale))×")
            Slider(value: $scale, in: 0.5 ... 1.5)
        }
    }
}
// end story

// story: animation.transition
struct TransitionStory: View {
    @State private var shown = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(shown ? "Hide" : "Show") {
                withAnimation { shown.toggle() }
            }
            .buttonStyle(.bordered)
            HStack(spacing: 12) {
                if shown {
                    Text("Fades").padding(10).background(Color.blue.opacity(0.2)).cornerRadius(8)
                        .transition(.opacity)
                    Text("Slides").padding(10).background(Color.green.opacity(0.2)).cornerRadius(8)
                        .transition(.move(edge: .leading))
                    Text("Scales").padding(10).background(Color.orange.opacity(0.2)).cornerRadius(8)
                        .transition(.scale)
                }
            }
            .frame(height: 44)
        }
    }
}
// end story
