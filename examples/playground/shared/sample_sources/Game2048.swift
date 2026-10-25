// 2048 — a swipe-to-merge tile game. Swipe the board (the tiles that can
// move follow your finger, the blocked ones stretch a little, then the move
// commits when you let go); merged tiles slide into place and a new tile
// slides in from the edge you swiped away from. Exercises GeometryReader
// layout, drag gestures, `withAnimation` with animated offsets/scales,
// navigation chrome and `.ignoresSafeArea()`. Shared by the example apps
// (a catalog entry) and the Playground (a project template).

import SwiftUI

enum Direction { case up, down, left, right }

/// One tile on the board. `merging` tiles are the losers of a merge: they
/// slide under the surviving tile and are removed once the slide finishes.
/// `entering` marks a freshly spawned tile still off the board's edge.
struct Tile: Identifiable {
    let id: Int
    var row: Int
    var col: Int
    var value: Int
    var merging = false
    var entering: Direction? = nil
}

struct Game2048Screen: View {
    @State private var tiles: [Tile] = []
    @State private var nextID = 0
    @State private var score = 0
    @State private var best = 0
    @State private var spawnNumber = 0
    @State private var gameOver = false
    @State private var won = false
    /// The live drag translation along the locked axis (moving tiles follow it).
    @State private var dragOffset = CGSize.zero
    /// The axis locked by the first movement of a swipe (until the finger lifts).
    @State private var dragHorizontal: Bool? = nil
    /// The move the current drag would make, and the tiles it would move;
    /// the rest stay put and stretch a little against the pull.
    @State private var previewDirection: Direction? = nil
    @State private var movingIDs: Set<Int> = []

    private let cream = Color(red: 0.97, green: 0.95, blue: 0.90)
    private let boardColor = Color(red: 0.73, green: 0.67, blue: 0.60)
    private let emptyColor = Color(red: 0.80, green: 0.75, blue: 0.68)
    private let gap: CGFloat = 8

    var body: some View {
        ZStack {
            cream.ignoresSafeArea()
            GeometryReader { geometry in
                let boardSize = max(200, min(geometry.size.width - 32, geometry.size.height - 120))
                let tileSize = (boardSize - gap * 5) / 4
                VStack(spacing: 20) {
                    scoreRow
                    board(boardSize: boardSize, tileSize: tileSize)
                    Text("Swipe the board to merge tiles.")
                        .font(.caption)
                        .foregroundColor(Color(red: 0.48, green: 0.42, blue: 0.36))
                }
                .padding(.top, 16)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
        }
        .navigationTitle("2048")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: resetGame) {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("New game")
            }
        }
        .onAppear { if tiles.isEmpty { resetGame() } }
    }

    // MARK: - Board

    private func board(boardSize: CGFloat, tileSize: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10).fill(boardColor)
            ForEach(0..<16, id: \.self) { index in
                RoundedRectangle(cornerRadius: 7)
                    .fill(emptyColor)
                    .frame(width: tileSize, height: tileSize)
                    .offset(x: origin(index % 4, tileSize), y: origin(index / 4, tileSize))
            }
            // Losers of a merge first, so the surviving tile draws on top.
            ForEach(tiles.filter { $0.merging }) { tile in tileView(tile, tileSize: tileSize) }
            ForEach(tiles.filter { !$0.merging }) { tile in tileView(tile, tileSize: tileSize) }
            if gameOver {
                endCard(title: "Game over", message: "No more moves left.", boardSize: boardSize)
            } else if won {
                endCard(title: "You made 2048!", message: "Keep going for a higher score.", boardSize: boardSize)
            }
        }
        .frame(width: boardSize, height: boardSize)
        .cornerRadius(10) // clips tiles that follow the finger past the edge
        .gesture(
            DragGesture(minimumDistance: 6)
                .onChanged { value in
                    // The first movement locks the axis for the whole swipe;
                    // the tiles that can move follow the finger a little way
                    // (enough to feel the move before it commits).
                    let dx = value.translation.width
                    let dy = value.translation.height
                    let horizontal = dragHorizontal ?? (abs(dx) > abs(dy))
                    dragHorizontal = horizontal
                    let along = horizontal ? dx : dy
                    let direction: Direction = horizontal ? (along > 0 ? .right : .left) : (along > 0 ? .down : .up)
                    if direction != previewDirection {
                        previewDirection = direction
                        movingIDs = plan(direction).movingIDs
                    }
                    let limit = tileSize * 0.35
                    let clamped = max(-limit, min(limit, along))
                    dragOffset = horizontal ? CGSize(width: clamped, height: 0) : CGSize(width: 0, height: clamped)
                }
                .onEnded { value in
                    let horizontal = dragHorizontal ?? true
                    let along = horizontal ? value.translation.width : value.translation.height
                    let direction: Direction? = abs(along) < 20 ? nil
                        : horizontal ? (along > 0 ? .right : .left) : (along > 0 ? .down : .up)
                    dragHorizontal = nil
                    withAnimation(.easeOut(duration: 0.16)) {
                        dragOffset = .zero
                        previewDirection = nil
                        movingIDs = []
                        if let direction { move(direction, tileSize: tileSize) }
                    }
                }
        )
    }

    private func origin(_ index: Int, _ tileSize: CGFloat) -> CGFloat {
        gap + CGFloat(index) * (tileSize + gap)
    }

    private func tileView(_ tile: Tile, tileSize: CGFloat) -> some View {
        // A spawned tile starts one cell beyond the edge it enters from.
        var x = origin(tile.col, tileSize)
        var y = origin(tile.row, tileSize)
        var width = tileSize
        var height = tileSize
        switch tile.entering {
        case .left: x += tileSize + gap
        case .right: x -= tileSize + gap
        case .up: y += tileSize + gap
        case .down: y -= tileSize + gap
        case nil: break
        }
        if let direction = previewDirection {
            if movingIDs.contains(tile.id) || tile.merging {
                x += dragOffset.width
                y += dragOffset.height
            } else {
                // A blocked tile leans into the pull: it stretches a little
                // toward the swipe (its far edge stays put) and thins across.
                let limit = tileSize * 0.35
                let progress = min(1, max(abs(dragOffset.width), abs(dragOffset.height)) / limit)
                let stretch = tileSize * 0.08 * progress
                let squeeze = tileSize * 0.04 * progress
                switch direction {
                case .left: x -= stretch; width += stretch; height -= squeeze; y += squeeze / 2
                case .right: width += stretch; height -= squeeze; y += squeeze / 2
                case .up: y -= stretch; height += stretch; width -= squeeze; x += squeeze / 2
                case .down: height += stretch; width -= squeeze; x += squeeze / 2
                }
            }
        }
        return TileFace(value: tile.value, size: tileSize, width: width, height: height)
            .scaleEffect(tile.entering == nil ? 1 : 0.6)
            .opacity(tile.entering == nil ? 1 : 0.4)
            .offset(x: x, y: y)
    }

    // MARK: - Score row

    private var scoreRow: some View {
        HStack(spacing: 16) {
            ScoreBox(title: "SCORE", value: score)
            ScoreBox(title: "BEST", value: best)
        }
        .padding(.horizontal, 16)
    }

    private func endCard(title: String, message: String, boardSize: CGFloat) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.title2.weight(.black)).foregroundColor(Color(red: 0.30, green: 0.23, blue: 0.16))
            Text(message).font(.subheadline).multilineTextAlignment(.center)
                .foregroundColor(Color(red: 0.38, green: 0.31, blue: 0.23))
            HStack(spacing: 10) {
                if won { Button("Keep going") { won = false }.buttonStyle(.bordered) }
                Button("New game", action: resetGame).buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: boardSize - 48)
        .background(Color(red: 0.97, green: 0.94, blue: 0.87))
        .cornerRadius(16)
        .shadow(radius: 8)
        .offset(x: 24, y: boardSize / 2 - 70)
    }

    // MARK: - Rules

    private func resetGame() {
        tiles = []
        score = 0
        spawnNumber = 0
        gameOver = false
        won = false
        spawn(from: nil)
        spawn(from: nil)
    }

    private func value(at row: Int, _ col: Int) -> Int {
        tiles.first { !$0.merging && $0.row == row && $0.col == col }?.value ?? 0
    }

    /// Slides and merges every line toward `direction`. Survivors move to
    /// their new cells (and double), merge losers move under them and are
    /// dropped once the slide has played; then a tile spawns from the far edge.
    /// The board after a move in `direction` (merges applied, losers marked
    /// `merging`), whether anything moved, the points gained, and the ids of
    /// the tiles that change cells — the drag preview uses the last one.
    private func plan(_ direction: Direction) -> (tiles: [Tile], moved: Bool, gained: Int, movingIDs: Set<Int>) {
        var updated = tiles.filter { !$0.merging }
        var moved = false
        var gained = 0
        var movingIDs = Set<Int>()
        for lineIndex in 0..<4 {
            // The tile ids along this line, nearest the destination edge first.
            var line: [Int] = []
            for position in 0..<4 {
                let (row, col): (Int, Int)
                switch direction {
                case .left: (row, col) = (lineIndex, position)
                case .right: (row, col) = (lineIndex, 3 - position)
                case .up: (row, col) = (position, lineIndex)
                case .down: (row, col) = (3 - position, lineIndex)
                }
                if let index = updated.firstIndex(where: { $0.row == row && $0.col == col }) {
                    line.append(index)
                }
            }
            var target = 0
            var index = 0
            while index < line.count {
                let current = line[index]
                let (row, col) = cell(direction, lineIndex, target)
                if index + 1 < line.count, updated[line[index + 1]].value == updated[current].value {
                    let partner = line[index + 1]
                    updated[current].value *= 2
                    gained += updated[current].value
                    updated[partner].merging = true
                    if updated[partner].row != row || updated[partner].col != col {
                        moved = true
                        movingIDs.insert(updated[partner].id)
                    }
                    updated[partner].row = row
                    updated[partner].col = col
                    index += 2
                } else {
                    index += 1
                }
                if updated[current].row != row || updated[current].col != col {
                    moved = true
                    movingIDs.insert(updated[current].id)
                }
                updated[current].row = row
                updated[current].col = col
                target += 1
            }
        }
        return (updated, moved, gained, movingIDs)
    }

    private func move(_ direction: Direction, tileSize: CGFloat) {
        guard !gameOver else { return }
        let (updated, moved, gained, _) = plan(direction)
        guard moved || gained > 0 else { return }
        tiles = updated
        score += gained
        if score > best { best = score }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            tiles.removeAll { $0.merging }
        }
        spawn(from: direction)
        if tiles.contains(where: { $0.value >= 2048 }) && !won { won = true }
        if !canMove() { gameOver = true }
    }

    private func cell(_ direction: Direction, _ lineIndex: Int, _ position: Int) -> (Int, Int) {
        switch direction {
        case .left: return (lineIndex, position)
        case .right: return (lineIndex, 3 - position)
        case .up: return (position, lineIndex)
        case .down: return (3 - position, lineIndex)
        }
    }

    /// Adds a tile on a free cell. After a move it enters from the edge
    /// opposite the move (the side the tiles vacated) and slides into place.
    private func spawn(from direction: Direction?) {
        var free: [(Int, Int)] = []
        for row in 0..<4 {
            for col in 0..<4 where value(at: row, col) == 0 { free.append((row, col)) }
        }
        guard !free.isEmpty else { return }
        let picked = free[(spawnNumber * 7 + score) % free.count]
        let entering: Direction?
        switch direction {
        case .left: entering = .right
        case .right: entering = .left
        case .up: entering = .down
        case .down: entering = .up
        case nil: entering = nil
        }
        let id = nextID
        nextID += 1
        tiles.append(Tile(id: id, row: picked.0, col: picked.1,
                          value: spawnNumber % 7 == 6 ? 4 : 2, entering: entering))
        spawnNumber += 1
        if entering != nil {
            // Let the tile render off-edge once, then slide it in.
            Task { @MainActor in
                withAnimation(.easeOut(duration: 0.2)) {
                    if let index = tiles.firstIndex(where: { $0.id == id }) { tiles[index].entering = nil }
                }
            }
        }
    }

    private func canMove() -> Bool {
        for row in 0..<4 {
            for col in 0..<4 {
                let v = value(at: row, col)
                if v == 0 { return true }
                if row < 3 && value(at: row + 1, col) == v { return true }
                if col < 3 && value(at: row, col + 1) == v { return true }
            }
        }
        return false
    }
}

struct ScoreBox: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(spacing: 2) {
            Text(title).font(.caption2.weight(.bold)).foregroundColor(Color(red: 0.93, green: 0.89, blue: 0.83))
            Text("\(value)").font(.title3.weight(.bold)).foregroundColor(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(red: 0.55, green: 0.49, blue: 0.42))
        .cornerRadius(10)
    }
}

struct TileFace: View {
    let value: Int
    let size: CGFloat
    var width: CGFloat? = nil
    var height: CGFloat? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(tileColor)
            Text("\(value)")
                .font(.system(size: value < 128 ? 28 : (value < 1024 ? 23 : 18), weight: .black, design: .rounded))
                .foregroundColor(value <= 4 ? Color(red: 0.45, green: 0.38, blue: 0.31) : .white)
        }
        .frame(width: width ?? size, height: height ?? size)
    }

    private var tileColor: Color {
        switch value {
        case 2: return Color(red: 0.93, green: 0.89, blue: 0.82)
        case 4: return Color(red: 0.92, green: 0.84, blue: 0.70)
        case 8: return Color(red: 0.94, green: 0.68, blue: 0.45)
        case 16: return Color(red: 0.95, green: 0.57, blue: 0.37)
        case 32: return Color(red: 0.94, green: 0.45, blue: 0.34)
        case 64: return Color(red: 0.91, green: 0.34, blue: 0.27)
        case 128: return Color(red: 0.93, green: 0.76, blue: 0.35)
        case 256: return Color(red: 0.91, green: 0.70, blue: 0.25)
        case 512: return Color(red: 0.88, green: 0.63, blue: 0.18)
        case 1024: return Color(red: 0.78, green: 0.50, blue: 0.14)
        default: return Color(red: 0.55, green: 0.35, blue: 0.16)
        }
    }
}
