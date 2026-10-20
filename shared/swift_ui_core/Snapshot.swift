// Test/tooling entry point: render a single view once through the real
// build → layout → draw pipeline against any `HostBridge`. A recording host can
// then capture the emitted draw list for deterministic snapshot tests (see
// tests/snapshot), with no GPU or browser involved.

/// Builds `view`, lays it out in `width`×`height`, and draws it through `host`.
/// State is fresh each call (isolated). Returns the laid-out root for callers
/// that want to inspect frames.
package import IsomerSwiftUI

@discardableResult
@MainActor
package func renderViewOnce(
    _ view: any View,
    width: Double,
    height: Double,
    host: HostBridge
) -> Void {
    let storage = StateStorage()
    var ctx = BuildContext(path: "root", env: EnvironmentValues(), storage: storage)
    let root = buildNode(view: view, ctx: &ctx)

    let layoutCtx = LayoutContext(
        measureText: { text, font, wrapWidth in
            host.measureText(text, fontSize: font.size, weight: font.weight.value, wrapWidth: wrapWidth.map { Double($0) })
        },
        imageInfo: { source, isRemote in
            host.imageInfo(source, isRemote: isRemote)
        }
    )

    let size = measure(root, proposal: ProposedSize(width: width, height: height), ctx: layoutCtx)
    let screen = CGRect(x: 0, y: 0, width: width, height: height)
    let frame = alignedRect(size: size, container: screen, alignment: .center)
    place(root, in: frame, ctx: layoutCtx)

    let pass = RenderPass(host: host)
    host.beginFrame(width: width, height: height)
    draw(root, pass: pass)
    host.endFrame()
}
