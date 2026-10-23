// Layout: stacks, frames and spacers, padding and backgrounds, grids,
// GeometryReader and ViewThatFits.

import SwiftUI

extension StoryCatalog {
    static let layout = StoryArea(id: "layout", title: "Layout", symbol: "square.grid.2x2", stories: [
        Story(
            "layout.stacks", "Stacks", apis: ["HStack(alignment:spacing:content:)", "VStack(alignment:spacing:content:)", "ZStack(alignment:content:)"],
            summary: "Views side by side, one above another, and layered, aligned and spaced."
        ) { StacksStory() },
        Story(
            "layout.frames", "Frames and spacers", apis: [".frame(width:height:alignment:)", ".frame(maxWidth:alignment:)", "Spacer()", "Divider()"],
            summary: "A view's size, fixed or as wide as it may be; space that pushes its neighbours apart; a line between them."
        ) { FramesStory() },
        Story(
            "layout.decoration", "Padding, background, overlay", apis: [".padding(_:)", ".padding(_:_:)", ".background(_:)", ".overlay(alignment:content:)", ".cornerRadius(_:)"],
            summary: "Space around a view, a view behind it, and a view in front of it at an alignment."
        ) { DecorationStory() },
        Story(
            "layout.grid", "Grid", apis: ["Grid(alignment:horizontalSpacing:verticalSpacing:content:)", "GridRow"],
            summary: "Rows of cells whose columns line up, sized by their widest cell."
        ) { GridStory() },
        Story(
            "layout.lazygrid", "LazyVGrid", apis: ["LazyVGrid(columns:spacing:content:)", "GridItem(.adaptive(minimum:))", "GridItem(.flexible())"],
            summary: "As many columns as fit, each at least a width, filled row by row."
        ) { LazyGridStory() },
        Story(
            "layout.geometry", "GeometryReader", apis: ["GeometryReader", "GeometryProxy.size"],
            summary: "The size a view is offered, read to lay out its content in proportion."
        ) { GeometryStory() },
        Story(
            "layout.thatfits", "ViewThatFits", apis: ["ViewThatFits(in:content:)"],
            summary: "The first of several layouts that fits the space: a row when there is room, a column when there is not."
        ) { ThatFitsStory() },
    ])
}

// story: layout.stacks
struct StacksStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .bottom, spacing: 8) {
                RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 40, height: 60)
                RoundedRectangle(cornerRadius: 6).fill(Color.green).frame(width: 40, height: 30)
                RoundedRectangle(cornerRadius: 6).fill(Color.blue).frame(width: 40, height: 45)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("VStack, trailing")
                Text("aligned").font(.caption)
            }
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10).fill(Color.purple.opacity(0.25)).frame(width: 140, height: 80)
                Circle().fill(Color.purple).frame(width: 28, height: 28).padding(6)
            }
        }
    }
}
// end story

// story: layout.frames
struct FramesStory: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("width 160, height 44")
                .frame(width: 160, height: 44)
                .background(Color.orange.opacity(0.3))
            Text("maxWidth: .infinity, leading")
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.2))
            Divider()
            HStack {
                Text("Leading")
                Spacer()
                Text("Trailing")
            }
            HStack {
                Spacer()
                Text("Centred by two spacers")
                Spacer()
            }
            .background(Color.green.opacity(0.2))
        }
    }
}
// end story

// story: layout.decoration
struct DecorationStory: View {
    var body: some View {
        HStack(spacing: 16) {
            Text("Padded")
                .padding()
                .background(Color.yellow.opacity(0.4))
                .cornerRadius(10)
            Text("Horizontal")
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.teal.opacity(0.35)))
            Image(systemName: "bell")
                .font(.title)
                .padding(10)
                .overlay(alignment: .topTrailing) {
                    Circle().fill(Color.red).frame(width: 12, height: 12)
                }
        }
    }
}
// end story

// story: layout.grid
struct GridStory: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
            GridRow {
                Text("Planet").bold()
                Text("Moons").bold()
                Text("Day").bold()
            }
            GridRow {
                Text("Earth")
                Text("1")
                Text("24 h")
            }
            GridRow {
                Text("Mars")
                Text("2")
                Text("24.6 h")
            }
            GridRow {
                Text("Jupiter")
                Text("95")
                Text("9.9 h")
            }
        }
    }
}
// end story

// story: layout.lazygrid
struct LazyGridStory: View {
    private let colors: [Color] = [.red, .orange, .yellow, .green, .mint, .teal, .cyan, .blue, .indigo, .purple, .pink, .brown]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 10) {
            ForEach(colors.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 10)
                    .fill(colors[index])
                    .frame(height: 64)
                    .overlay(Text("\(index + 1)").font(.headline).foregroundColor(.white))
            }
        }
    }
}
// end story

// story: layout.geometry
struct GeometryStory: View {
    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
                    .frame(width: proxy.size.width * 0.6)
                    .overlay(Text("60%").foregroundColor(.white))
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.4))
                    .overlay(Text("\(Int(proxy.size.width)) pt wide").font(.caption))
            }
        }
        .frame(height: 56)
    }
}
// end story

// story: layout.thatfits
struct ThatFitsStory: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            choice.frame(width: 320, alignment: .leading)
            choice.frame(width: 110, alignment: .leading)
        }
    }

    private var choice: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Button("Accept") {}.buttonStyle(.borderedProminent)
                Button("Decline") {}.buttonStyle(.bordered)
            }
            VStack(alignment: .leading) {
                Button("Accept") {}.buttonStyle(.borderedProminent)
                Button("Decline") {}.buttonStyle(.bordered)
            }
        }
    }
}
// end story
