// The headless head: what an app built headless renders through when no
// remote head is drawing it. It renders without rendering: each frame laid
// out as the self-drawing renderer lays it out (its drawn chrome, measured and
// placed: Runtime.layoutTree), and nothing drawn. Its encoding installs the
// tree's handlers and fires `onAppear`, as a component-system renderer's
// does. Tests read its layout through the IsomerLayoutServer it serves
// (layout.proto, HeadlessServer.layout); the driver reads the tree as the app
// means it, as on every self-drawing renderer, frameless.

internal import IsomerSwiftUI
internal import IsomerWire
internal import SwiftUI
import Foundation

@MainActor
final class HeadlessHead: TreeRenderer {
    /// The one bound, while no remote head is.
    static var current: HeadlessHead?

    /// Drawn chrome, as the self-drawing renderer has it: the layout a test
    /// reads is that renderer's.
    let semanticNavigation = false
    let supportedModes: Set<IntegrationMode> = [.app, .embedded]

    private let encoder = FlatTreeEncoder()
    /// The last frame's views, the window's and the presented layers'.
    private var views: [LaidOutView] = []

    init() {
        encoder.semantic = true
    }

    func render(tree: RenderNode) {
        let runtime = Runtime.shared
        let reports = runtime.layoutTree(root: tree)
        var views = laidOutViews(tree)
        for (index, layer) in runtime.layoutPresentations().enumerated() {
            views += laidOutViews(layer, layer: index + 1)
        }
        self.views = views
        _ = encoder.encodePatch(root: tree)
        runtime.installTreeHandlers(encoder.handlers)
        runtime.fireTreeAppearances(encoder.appearances, disappearances: encoder.disappearances)
        for report in reports { report() }
    }

    /// The layout as it stands, as layout.proto has it.
    var layout: Wire_Layout {
        var layout = Wire_Layout()
        layout.width = Double(Runtime.shared.width)
        layout.height = Double(Runtime.shared.height)
        layout.items = views.map { view in
            var item = Wire_LaidOut()
            item.kind = view.kind
            item.label = view.label
            item.identifier = view.identifier
            item.x = Double(view.frame.minX)
            item.y = Double(view.frame.minY)
            item.width = Double(view.frame.width)
            item.height = Double(view.frame.height)
            item.depth = Int32(view.depth)
            item.layer = Int32(view.layer)
            return item
        }
        return layout
    }
}
