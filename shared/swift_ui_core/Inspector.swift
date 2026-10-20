// `.inspector(isPresented:content:)` — Apple's trailing inspector pane. At
// regular width the inspector is a ~300pt column on the trailing edge of the
// view it's applied to (e.g. a split view's detail column); at compact width
// it presents as a sheet, and so on a short window too (a phone in
// landscape, under 500pt tall: wide enough for two columns, a third left the
// detail between them too narrow to use). Component-system hosts receive the regular form as
// a plain horizontal stack (content | divider | inspector), so no host work
// is needed; the sheet form rides the existing presentation machinery.

extension View {
    // Apple shipped this in iOS 17 / macOS 14, so it is spelled that way
    // here too: on Apple the rules must be Apple's, whichever renderer is
    // drawing. The attribute names only Apple's platforms, so the `*` case
    // covers the ones we implement ourselves and it costs them nothing. A
    // feature compiled against Isomer's frameworks on an Apple platform
    // (ISOMER_COMPILED_FEATURE) has Isomer's on every OS: there it is not.
    #if !ISOMER_COMPILED_FEATURE
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
    #endif
    nonisolated public func inspector<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        _InspectorView(child: self, isPresented: isPresented, makeContent: content)
    }
}

struct _InspectorView<Child: View, Content: View> {
    let child: Child
    let isPresented: Binding<Bool>
    let makeContent: () -> Content

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension _InspectorView: _PrimitiveView {
    @MainActor
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let roomForColumn = !Runtime.shared.compactWidth && Runtime.shared.height >= 500
        if roomForColumn {
            var childCtx = ctx.descend("inspected")
            let childNode = buildNode(view: child, ctx: &childCtx)
            guard isPresented.wrappedValue else { return childNode }
            let childBox = RenderNode.box(child: childNode)
            childBox.expandsWidth = true
            childBox.expandsHeight = true

            var paneCtx = ctx.descend("inspector")
            Runtime.shared.inspectorWidthHint = nil
            let paneNode = buildNode(view: makeContent(), ctx: &paneCtx)
            let pane = RenderNode.box(child: paneNode)
            // `.inspectorColumnWidth` on the pane's content, else 300pt.
            pane.fixedWidth = Runtime.shared.inspectorWidthHint.map { CGFloat($0) } ?? 300
            Runtime.shared.inspectorWidthHint = nil
            pane.expandsHeight = true
            pane.alignment = .topLeading
            pane.background = [RenderNode(kind: .shape(.rectangle, fill: Color.barBackground, stroke: nil))]

            let divider = RenderNode(kind: .shape(.rectangle, fill: Color.separator, stroke: nil))
            divider.fixedWidth = 1
            divider.expandsHeight = true

            let row = RenderNode(kind: .stack(.horizontal))
            row.stackSpacing = 0
            row.expandsWidth = true
            row.expandsHeight = true
            row.children = [childBox, divider, pane]
            return row
        }
        // Compact (or short): a sheet over the inspected view. Its content
        // sees a compact width, as an inspector's sheet always has one on
        // Apple's platforms: an app keys its sheet chrome on it (Visor's
        // Details title and Done button).
        let content = makeContent
        var sub = ctx.descend("inspected")
        return buildNode(view: child.sheet(isPresented: isPresented) {
            content().environment(\.horizontalSizeClass, .compact)
        }, ctx: &sub)
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension _InspectorView: View {}
