// Shapes and color: the built-in shapes, strokes, paths, gradients,
// materials, colors, and effects.

import SwiftUI

extension StoryCatalog {
    static let shapes = StoryArea(id: "shapes", title: "Shapes and Color", symbol: "circle.square", stories: [
        Story(
            "shapes.basic", "Shapes",
            summary: "The built-in shapes, filled. A shape takes all the space it is offered; a frame sizes it."
        ) { BasicShapesStory() },
        Story(
            "shapes.stroke", "Strokes",
            summary: "A shape's outline: its width, dashes and caps, and part of it trimmed away, as a progress ring is."
        ) { StrokesStory() },
        Story(
            "shapes.path", "Path and Shape",
            summary: "A shape of your own: a path drawn in the rectangle it is given, filled and stroked like the built-in ones."
        ) { PathStory() },
        Story(
            "shapes.gradients", "Gradients",
            summary: "Colors blended along a line, out from a point, and around a centre."
        ) { GradientsStory() },
        Story(
            "shapes.colors", "Colors",
            summary: "The system colors, which adapt to light and dark appearance, and colors of your own."
        ) { ColorsStory() },
        Story(
            "shapes.materials", "Materials",
            summary: "Translucent backgrounds that blur what is behind them."
        ) { MaterialsStory() },
        Story(
            "shapes.effects", "Shadows and effects",
            summary: "A shadow under a view, a blur over it, its opacity, and a shape it is clipped to."
        ) { EffectsStory() },
        Story(
            "shapes.mask", "Masks",
            summary: "A view shown only where its mask is drawn (mask): a gradient cut to the largest circle its frame holds, and one shown across part of its width, the mask aligned to its leading edge."
        ) { MaskStory() },
    ])
}

// story: shapes.basic
struct BasicShapesStory: View {
    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.red).frame(width: 50, height: 50)
            RoundedRectangle(cornerRadius: 12).fill(Color.orange).frame(width: 50, height: 50)
            Circle().fill(Color.green).frame(width: 50, height: 50)
            Capsule().fill(Color.blue).frame(width: 80, height: 40)
            Ellipse().fill(Color.purple).frame(width: 70, height: 44)
        }
    }
}
// end story

// story: shapes.stroke
struct StrokesStory: View {
    @State private var progress = 0.7

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Circle().stroke(Color.blue, lineWidth: 4).frame(width: 56, height: 56)
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 3, dash: [8, 4]))
                    .frame(width: 80, height: 56)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 56, height: 56)
            }
            Slider(value: $progress)
        }
    }
}
// end story

// story: shapes.path
struct PathStory: View {
    struct Wave: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.midY), control: CGPoint(x: rect.width * 0.25, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.midY), control: CGPoint(x: rect.width * 0.75, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    var body: some View {
        HStack(spacing: 20) {
            Wave().fill(Color.blue.opacity(0.6)).frame(width: 160, height: 70)
            Triangle().fill(Color.orange).frame(width: 60, height: 60)
            Triangle().stroke(Color.red, lineWidth: 3).frame(width: 60, height: 60)
        }
    }
}
// end story

// story: shapes.gradients
struct GradientsStory: View {
    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 14)
                .fill(LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 90, height: 90)
            Circle()
                .fill(RadialGradient(colors: [.yellow, .orange, .red], center: .center, startRadius: 4, endRadius: 45))
                .frame(width: 90, height: 90)
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
                .frame(width: 90, height: 90)
        }
    }
}
// end story

// story: shapes.colors
struct ColorsStory: View {
    private let system: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown, .gray]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(system.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 4).fill(system[index]).frame(height: 32)
                }
            }
            HStack(spacing: 8) {
                Circle().fill(Color(red: 0.2, green: 0.5, blue: 0.9)).frame(width: 32, height: 32)
                Circle().fill(Color.blue.opacity(0.5)).frame(width: 32, height: 32)
                Circle().fill(Color.blue.opacity(0.2)).frame(width: 32, height: 32)
                Circle().fill(Color.accentColor).frame(width: 32, height: 32)
                Text("Primary").foregroundColor(.primary)
                Text("Secondary").foregroundColor(.secondary)
            }
        }
    }
}
// end story

// story: shapes.materials
struct MaterialsStory: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [.pink, .orange, .yellow], startPoint: .leading, endPoint: .trailing)
            HStack(spacing: 10) {
                Text("Ultra thin").padding(10).background(.ultraThinMaterial)
                Text("Regular").padding(10).background(.regularMaterial)
                Text("Thick").padding(10).background(.thickMaterial)
            }
            .font(.footnote)
        }
        .frame(height: 100)
        .cornerRadius(14)
    }
}
// end story

// story: shapes.effects
struct EffectsStory: View {
    var body: some View {
        HStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .frame(width: 70, height: 70)
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 5)
            Text("Blur")
                .font(.title)
                .blur(radius: 2)
            Circle().fill(Color.blue).frame(width: 60, height: 60).opacity(0.4)
            LinearGradient(colors: [.green, .blue], startPoint: .top, endPoint: .bottom)
                .frame(width: 70, height: 70)
                .clipShape(Capsule())
        }
        .padding(10)
    }
}
// end story

// story: shapes.mask
struct MaskStory: View {
    var body: some View {
        HStack(spacing: 16) {
            Rectangle()
                .fill(LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 140, height: 100)
                .mask { Circle() }
            Rectangle()
                .fill(LinearGradient(colors: [.blue, .green], startPoint: .leading, endPoint: .trailing))
                .frame(width: 140, height: 100)
                .mask(alignment: .leading) { RoundedRectangle(cornerRadius: 16).frame(width: 90) }
        }
    }
}
// end story
