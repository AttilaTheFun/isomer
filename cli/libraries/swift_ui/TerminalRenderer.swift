// The terminal renderer: renders the resolved tree as styled text into an
// ANSI character grid — Isomer for CLI applications. A self-drawing
// renderer in spirit (there are no platform components to map to), so it
// receives the pre-expanded drawn chrome (`semanticNavigation = false`):
// navigation bars, tab bars, and toggles arrive as ordinary drawn views and
// render like everything else.
//
// Layout is a simple integer-cell flow: text wraps at the available width,
// stacks flow their children (spacers and greedy children absorb leftover
// cells), padding maps any non-zero inset to one cell, and vertical scrolls
// clip to the viewport. Interaction is keyboard-driven (see TerminalApp):
// Tab / arrows move focus between tappable nodes, Return activates, and
// printable keys edit a focused text field.

#if !canImport(WASILibc)

/// One styled character cell.
struct TerminalCell {
    var character: Character = " "
    var fg: Color?
    var bold = false
    var inverted = false
}

/// The character grid plus ANSI serialization.
struct TerminalCanvas {
    let width: Int
    let height: Int
    var cells: [TerminalCell]

    init(width: Int, height: Int) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        cells = Array(repeating: TerminalCell(), count: self.width * self.height)
    }

    mutating func put(_ x: Int, _ y: Int, _ character: Character, fg: Color?, bold: Bool, inverted: Bool) {
        guard x >= 0, x < width, y >= 0, y < height else { return }
        cells[y * width + x] = TerminalCell(
            character: character, fg: fg, bold: bold, inverted: inverted)
    }

    /// Serialize with per-cell ANSI SGR (reset-per-change; terminals are fast).
    func ansi() -> String {
        var out = ""
        out.reserveCapacity(width * height * 4)
        for y in 0 ..< height {
            var lastCode = ""
            for x in 0 ..< width {
                let cell = cells[y * width + x]
                var code = "\u{1B}[0"
                if cell.bold { code += ";1" }
                if cell.inverted { code += ";7" }
                if let fg = cell.fg {
                    code += ";38;2;\(Int(fg.red * 255));\(Int(fg.green * 255));\(Int(fg.blue * 255))"
                }
                code += "m"
                if code != lastCode {
                    out += code
                    lastCode = code
                }
                out.append(cell.character)
            }
            out += "\u{1B}[0m\n"
        }
        return out
    }
}

/// A focusable interactive node: a tappable region or a text field.
struct TerminalFocusable {
    let node: RenderNode
    var isTextField: Bool {
        if case .textField = node.kind { return true }
        return false
    }
}

package final class TerminalRenderer: TreeRenderer {
    /// A terminal is a whole surface, but `installRootView` marks embedded —
    /// both are fine here (the "embedding" is the surrounding shell).
    public let supportedModes: Set<IntegrationMode> = [.embedded, .app]

    /// No platform components to map semantic chrome to: take the drawn
    /// expansion (bars and controls as ordinary views).
    public let semanticNavigation = false

    public var columns = 80
    public var rows = 24
    /// Focus index into the frame's focusable list (cycled by TerminalApp).
    public var focusIndex = 0
    private(set) var focusables: [TerminalFocusable] = []
    let output: (String) -> Void

    public init(output: @escaping (String) -> Void = { Swift.print($0, terminator: "") }) {
        self.output = output
    }

    @MainActor
    public func render(tree: RenderNode) {
        expandDrawnChrome(tree)
        focusables = []
        collectFocusables(tree)
        if focusIndex >= focusables.count { focusIndex = max(0, focusables.count - 1) }
        var canvas = TerminalCanvas(width: columns, height: rows)
        var context = DrawContext(
            focused: focusables.isEmpty ? nil : focusables[focusIndex].node)
        _ = draw(tree, into: &canvas, x: 0, y: 0, w: columns, h: rows, ctx: &context)
        // Home the cursor and repaint (no full clear: avoids flicker).
        output("\u{1B}[H" + canvas.ansi())
    }

    // MARK: - Interaction surface (driven by TerminalApp)

    func focusNext(_ delta: Int) {
        guard !focusables.isEmpty else { return }
        focusIndex = (focusIndex + delta + focusables.count) % focusables.count
    }

    func activateFocused() {
        guard focusables.indices.contains(focusIndex) else { return }
        focusables[focusIndex].node.tapAction?()
    }

    /// Route a typed character (or backspace) into a focused text field.
    /// Returns true when consumed.
    func type(_ character: Character, backspace: Bool) -> Bool {
        guard focusables.indices.contains(focusIndex) else { return false }
        let node = focusables[focusIndex].node
        guard case .textField = node.kind, let get = node.textGet, let set = node.textSet else {
            return false
        }
        var value = get()
        if backspace {
            if !value.isEmpty { value.removeLast() }
        } else {
            value.append(character)
        }
        set(value)
        return true
    }

    private func collectFocusables(_ node: RenderNode) {
        if node.tapAction != nil {
            focusables.append(TerminalFocusable(node: node))
        }
        if case .textField = node.kind, node.textSet != nil {
            focusables.append(TerminalFocusable(node: node))
        }
        for child in node.children { collectFocusables(child) }
        for child in node.background { collectFocusables(child) }
        for child in node.overlay { collectFocusables(child) }
    }

    // MARK: - Measure

    struct DrawContext {
        var focused: RenderNode?
        var fgOverride: Color?
        var inverted = false
    }

    /// Natural (unflexed) size in cells at a width budget.
    func measure(_ node: RenderNode, maxW: Int) -> (w: Int, h: Int) {
        let pad = padCells(node)
        let innerW = max(1, maxW - pad.l - pad.r)
        var size: (w: Int, h: Int)
        switch node.kind {
        case .text(let string):
            let lines = wrap(string, width: innerW, limit: node.lineLimit)
            size = (lines.map(\.count).max() ?? 0, lines.count)
        case .divider:
            size = (innerW, 1)
        case .spacer:
            size = (0, 0)
        case .textField:
            size = (max(12, min(innerW, 32)), 1)
        case .image:
            size = (2, 1)
        case .progress:
            size = (3, 1)
        case .shape, .gradient:
            size = (2, 1)
        case .slider:
            size = (12, 1)
        case .stack(let axis):
            let spacing = axis == .horizontal ? (cellSpacing(node)) : 0
            var w = 0
            var h = 0
            for child in node.children {
                let s = measure(child, maxW: innerW)
                switch axis {
                case .horizontal:
                    w += s.w + (w > 0 && s.w > 0 ? spacing : 0)
                    h = max(h, s.h)
                case .vertical:
                    w = max(w, s.w)
                    h += s.h
                case .depth:
                    w = max(w, s.w)
                    h = max(h, s.h)
                }
            }
            size = (w, h)
        case .scroll:
            var w = 0
            var h = 0
            for child in node.children {
                let s = measure(child, maxW: innerW)
                w = max(w, s.w)
                h += s.h
            }
            size = (w, h)
        default:
            // box / hostView / geometry: contain children (stacked layers).
            var w = 0
            var h = 0
            for child in node.children {
                let s = measure(child, maxW: innerW)
                w = max(w, s.w)
                h = max(h, s.h)
            }
            size = (w, h)
        }
        if let fixed = node.fixedWidth { size.w = Int(fixed / 8) }
        if let fixed = node.fixedHeight { size.h = max(1, Int(fixed / 16)) }
        return (min(size.w + pad.l + pad.r, maxW), size.h + pad.t + pad.b)
    }

    // MARK: - Draw

    /// Draws `node` into the rect; returns the height actually used.
    @discardableResult
    func draw(
        _ node: RenderNode, into canvas: inout TerminalCanvas,
        x: Int, y: Int, w: Int, h: Int, ctx: inout DrawContext
    ) -> Int {
        guard w > 0, h > 0 else { return 0 }
        var ctx = ctx
        if node.tapAction != nil || isTextField(node) {
            if let focused = ctx.focused, focused === node { ctx.inverted = true }
        }
        // A colored background fill tints the region's ink (cell-region bg
        // fills read poorly; selection highlights invert instead).
        if let fill = firstFill(node.background), fill.alpha > 0.12 {
            ctx.inverted = ctx.inverted || node.tapAction != nil
        }

        let pad = padCells(node)
        let ix = x + pad.l
        let iy = y + pad.t
        let iw = max(0, w - pad.l - pad.r)
        let ih = max(0, h - pad.t - pad.b)
        var used = 0

        switch node.kind {
        case .text(let string):
            let color = ctx.fgOverride ?? node.color
            let bold = node.font.weight.value >= 600
            let lines = wrap(string, width: max(iw, 1), limit: node.lineLimit)
            for (row, line) in lines.enumerated() where row < ih {
                for (col, character) in line.enumerated() where col < iw {
                    canvas.put(ix + col, iy + row, character, fg: color, bold: bold, inverted: ctx.inverted)
                }
            }
            used = min(lines.count, ih)
        case .divider:
            for col in 0 ..< iw {
                canvas.put(ix + col, iy, "─", fg: Color.separator, bold: false, inverted: false)
            }
            used = 1
        case .textField:
            let value = node.textGet?() ?? ""
            var shown = value.isEmpty ? placeholderText(node) : value
            let fieldW = max(iw, 4)
            if shown.count > fieldW - 2 { shown = String(shown.suffix(fieldW - 2)) }
            canvas.put(ix, iy, "[", fg: Color.secondary, bold: false, inverted: ctx.inverted)
            for (col, character) in shown.enumerated() {
                canvas.put(
                    ix + 1 + col, iy, character,
                    fg: value.isEmpty ? Color.secondary : node.color,
                    bold: false, inverted: ctx.inverted)
            }
            canvas.put(ix + fieldW - 1, iy, "]", fg: Color.secondary, bold: false, inverted: ctx.inverted)
            used = 1
        case .image:
            canvas.put(ix, iy, "🖼", fg: nil, bold: false, inverted: false)
            used = 1
        case .progress:
            for (col, character) in "◐◓◑".enumerated() where col < iw {
                canvas.put(ix + col, iy, character, fg: Color.secondary, bold: false, inverted: false)
            }
            used = 1
        case .shape, .gradient, .slider:
            let fill = shapeFill(node) ?? Color.accentColor
            let width = min(iw, max(2, measure(node, maxW: iw).w))
            for col in 0 ..< width {
                canvas.put(ix + col, iy, "█", fg: fill, bold: false, inverted: false)
            }
            used = 1
        case .stack(let axis):
            used = drawStack(node, axis: axis, into: &canvas, x: ix, y: iy, w: iw, h: ih, ctx: &ctx)
        case .scroll:
            // Viewport-clipped content (v1: top-anchored, no scroll offset).
            for child in node.children {
                used = draw(child, into: &canvas, x: ix, y: iy, w: iw, h: ih, ctx: &ctx)
            }
            used = min(used, ih)
        default:
            // box / hostView / other containers: layers in one rect.
            for child in node.children {
                used = max(used, draw(child, into: &canvas, x: ix, y: iy, w: iw, h: ih, ctx: &ctx))
            }
            for overlay in node.overlay {
                _ = draw(overlay, into: &canvas, x: ix, y: iy, w: iw, h: ih, ctx: &ctx)
            }
        }
        return min(used + pad.t + pad.b, h)
    }

    private func drawStack(
        _ node: RenderNode, axis: StackAxis, into canvas: inout TerminalCanvas,
        x: Int, y: Int, w: Int, h: Int, ctx: inout DrawContext
    ) -> Int {
        switch axis {
        case .vertical:
            var cursor = 0
            // Distribute leftover rows to greedy children/spacers.
            let naturals = node.children.map { measure($0, maxW: w) }
            let naturalTotal = naturals.map(\.h).reduce(0, +)
            let flexible = node.children.filter { isVerticallyGreedy($0) }.count
            let leftover = max(0, h - naturalTotal)
            let bonus = flexible > 0 ? leftover / flexible : 0
            for (index, child) in node.children.enumerated() {
                guard cursor < h else { break }
                var budget = naturals[index].h
                if isVerticallyGreedy(child) { budget += bonus }
                budget = min(budget, h - cursor)
                let used = draw(child, into: &canvas, x: x, y: y + cursor, w: w, h: max(budget, 0), ctx: &ctx)
                cursor += max(used, isVerticallyGreedy(child) ? budget : used)
            }
            return min(cursor, h)
        case .horizontal:
            let spacing = cellSpacing(node)
            let naturals = node.children.map { measure($0, maxW: w) }
            let naturalTotal = naturals.map(\.w).reduce(0, +)
                + spacing * max(0, node.children.count - 1)
            let flexible = node.children.filter { isHorizontallyGreedy($0) }.count
            let leftover = max(0, w - naturalTotal)
            let bonus = flexible > 0 ? leftover / flexible : 0
            var cursor = 0
            var tallest = 0
            for (index, child) in node.children.enumerated() {
                guard cursor < w else { break }
                var budget = naturals[index].w
                if isHorizontallyGreedy(child) { budget += bonus }
                budget = min(budget, w - cursor)
                let used = draw(child, into: &canvas, x: x + cursor, y: y, w: max(budget, 0), h: h, ctx: &ctx)
                tallest = max(tallest, used)
                cursor += budget + (index < node.children.count - 1 ? spacing : 0)
            }
            return min(tallest, h)
        case .depth:
            var used = 0
            for child in node.children {
                used = max(used, draw(child, into: &canvas, x: x, y: y, w: w, h: h, ctx: &ctx))
            }
            return used
        }
    }

    // MARK: - Helpers

    private func isTextField(_ node: RenderNode) -> Bool {
        if case .textField = node.kind { return true }
        return false
    }

    private func isVerticallyGreedy(_ node: RenderNode) -> Bool {
        if case .spacer = node.kind { return true }
        return node.expandsHeight
    }

    private func isHorizontallyGreedy(_ node: RenderNode) -> Bool {
        if case .spacer = node.kind { return true }
        return node.expandsWidth
    }

    private func padCells(_ node: RenderNode) -> (l: Int, r: Int, t: Int, b: Int) {
        (
            node.padding.leading > 0 ? max(1, Int(node.padding.leading / 8)) : 0,
            node.padding.trailing > 0 ? max(1, Int(node.padding.trailing / 8)) : 0,
            node.padding.top > 6 ? 1 : 0,
            node.padding.bottom > 6 ? 1 : 0
        )
    }

    private func cellSpacing(_ node: RenderNode) -> Int {
        (node.stackSpacing ?? 8) > 0 ? 1 : 0
    }

    private func wrap(_ string: String, width: Int, limit: Int?) -> [[Character]] {
        guard width > 0 else { return [] }
        var lines: [[Character]] = []
        for rawLine in string.split(separator: "\n", omittingEmptySubsequences: false) {
            var current: [Character] = []
            for word in rawLine.split(separator: " ", omittingEmptySubsequences: false) {
                let characters = Array(word)
                if current.isEmpty {
                    current = Array(characters.prefix(width))
                } else if current.count + 1 + characters.count <= width {
                    current.append(" ")
                    current.append(contentsOf: characters)
                } else {
                    lines.append(current)
                    current = Array(characters.prefix(width))
                }
            }
            lines.append(current)
        }
        if let limit, lines.count > limit { lines = Array(lines.prefix(limit)) }
        return lines
    }

    private func placeholderText(_ node: RenderNode) -> String {
        if case .textField(let placeholder) = node.kind { return placeholder }
        return ""
    }

    private func firstFill(_ nodes: [RenderNode]) -> Color? {
        for node in nodes {
            if let fill = shapeFill(node) { return fill }
            if let fill = firstFill(node.children) { return fill }
        }
        return nil
    }

    private func shapeFill(_ node: RenderNode) -> Color? {
        if case .shape(_, let fill, _) = node.kind { return fill }
        return nil
    }
}

#endif
