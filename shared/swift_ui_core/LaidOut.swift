// The views a laid-out tree holds where a test can find them: a node's
// frame (`layoutTree`), with what it is and what it says. The headless head
// reports them (IsomerLayoutServer: shared/wire/layout.proto); the driver's
// protocol stays frameless.

import Foundation

/// One view of a laid-out tree.
package struct LaidOutView: Sendable {
    /// text, button, textField, image, scroll, slider, progress, view (one
    /// with an identifier and nothing else), or a host view's kind.
    package let kind: String
    /// A text's string; a button's accessibility label, else the texts it
    /// holds; a field's label or placeholder.
    package let label: String
    package let identifier: String
    /// In the window, in points.
    package let frame: CGRect
    package let depth: Int
    /// 0 the window's own; 1 the first presented layer (a sheet, an alert), …
    package let layer: Int
}

/// The views of `root`, laid out (its frames set): a parent before what it
/// holds. Hidden ones (`.accessibilityHidden`, fully transparent) and what
/// they hold are left out.
@MainActor
package func laidOutViews(_ root: RenderNode, layer: Int = 0) -> [LaidOutView] {
    var views: [LaidOutView] = []
    func texts(_ node: RenderNode) -> [String] {
        if case .text(let string) = node.kind { return [string] }
        return node.children.flatMap(texts)
    }
    func visit(_ node: RenderNode, depth: Int) {
        if node.accessibilityHidden || node.opacity <= 0 { return }
        let identifier = node.accessibilityIdentifier ?? ""
        var kind: String?
        var label = node.accessibilityLabel ?? ""
        switch node.kind {
        case .text(let string):
            kind = "text"
            if label.isEmpty { label = string }
        case .textField(let placeholder):
            kind = "textField"
            if label.isEmpty { label = placeholder }
        case .image:
            kind = "image"
        case .scroll:
            kind = "scroll"
        case .slider:
            kind = "slider"
        case .progress:
            kind = "progress"
        case .hostView(let spec):
            kind = spec.kind
        default:
            break
        }
        if kind == nil, node.tapAction != nil {
            kind = "button"
            if label.isEmpty { label = texts(node).joined(separator: " ") }
        }
        if kind == nil, !identifier.isEmpty { kind = "view" }
        if let kind {
            views.append(LaidOutView(kind: kind, label: label, identifier: identifier,
                                     frame: node.frame, depth: depth, layer: layer))
        }
        for child in node.children { visit(child, depth: depth + 1) }
    }
    visit(root, depth: 0)
    return views
}
