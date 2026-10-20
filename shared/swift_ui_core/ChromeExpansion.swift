// Drawn-chrome expansion for the self-drawing path.
//
// The build produces ONE canonical tree for every renderer: framework chrome
// (nav/tab bars, search fields, toggles, pickers, menus, date pickers, media
// surfaces, images) is always emitted as semantic `hostView` nodes — the form
// component systems consume. `Runtime.drawTree` calls `expandDrawnChrome`
// before layout to replace those nodes with their drawn implementations, so
// the display list draws all chrome itself (identically on every GPU
// backend) without the core ever asking the renderer what it is.
//
// Expansion rebuilds each drawn view with a `BuildContext` rooted at the
// spec's stable id, so path-keyed `@State` inside drawn chrome (an open
// popup, a stepper) survives across frames exactly as it did when the chrome
// was built inline.

@MainActor
func expandDrawnChrome(_ node: RenderNode) {
    for (index, child) in node.children.enumerated() {
        if case .hostView(let spec) = child.kind {
            switch spec.kind {
            case "image":
                // Straight kind swap: the draw pass decodes SVG/GIF stills at
                // the GPU layer; no native <img> element exists here.
                child.kind = .image(
                    source: spec.value,
                    isRemote: spec.value.hasPrefix("http"),
                    resizable: true,
                    fit: true
                )
                continue
            default:
                if let view = drawnChromeView(for: spec) {
                    node.children[index] = drawnSubtree(view, spec: spec, replacing: child)
                    continue
                }
            }
        }
        expandDrawnChrome(child)
    }
}

/// The drawn implementation of a semantic chrome spec, or nil for specs the
/// host owns natively (maps via `drawHostView`, app-authored representables).
private func drawnChromeView(for spec: HostViewSpec) -> (any View)? {
    let value = spec.value
    let onChange = spec.onChange
    switch spec.kind {
    case "toggle":
        return DrawnToggle(on: value == "1", onToggle: { onChange?(value == "1" ? "0" : "1") })
    case "navbar":
        let split = { (key: String) -> [String] in
            (spec.params[key] ?? "").split(separator: "\n").map(String.init)
        }
        let disabled = { (key: String) -> Set<Int> in
            Set((spec.params[key] ?? "").split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                .filter { $0.element == "1" }.map(\.offset))
        }
        return DrawnNavBar(
            title: spec.params["title"] ?? "",
            showsBack: spec.params["back"] == "1",
            leading: split("leading"),
            trailing: split("trailingItems"),
            leadingDisabled: disabled("leadingDisabled"),
            trailingDisabled: disabled("trailingDisabled"),
            onBack: { onChange?("back") },
            onLeading: { onChange?("leading:\($0)") },
            onTrailing: { onChange?("trailingItem:\($0)") }
        )
    case "tabbar":
        var items: [WindowsTabItem] = []
        var index = 0
        while let label = spec.params["label\(index)"] {
            items.append(WindowsTabItem(label: label, icon: spec.params["icon\(index)"] ?? ""))
            index += 1
        }
        return DrawnTabBar(
            items: items,
            selected: Int(value) ?? 0,
            onSelect: { onChange?(String($0)) }
        )
    case "search":
        return DrawnSearchField(spec: SearchSpec(
            prompt: spec.params["prompt"] ?? "",
            get: { value },
            set: { onChange?($0) }
        ))
    case "picker":
        let selected = Int(value) ?? 0
        if spec.params["style"] == "segmented" {
            return DrawnSegmented(options: spec.options, selectedIndex: selected, onSelect: { onChange?(String($0)) })
        }
        let label = spec.options.indices.contains(selected)
            ? spec.options[selected] : (spec.params["title"] ?? "")
        return DrawnPopUpList(
            label: label,
            accented: false,
            rows: spec.options,
            selectedIndex: selected,
            onSelect: { onChange?(String($0)) }
        )
    case "menu":
        // Options carry the label at index 0; actions are 1-based.
        return DrawnPopUpList(
            label: spec.params["label"] ?? "Menu",
            accented: true,
            rows: Array(spec.options.dropFirst()),
            selectedIndex: nil,
            onSelect: { onChange?(String($0 + 1)) }
        )
    case "datepicker":
        return DrawnDatePicker(
            title: spec.params["title"] ?? "",
            isoValue: value,
            onChange: { onChange?($0) }
        )
    case "webview", "video":
        return DrawnMediaPlaceholder(kind: spec.kind, url: value)
    default:
        return nil
    }
}

/// Builds the drawn view and carries over the layout the site put on the
/// semantic node (fixed frame, expansion, opacity, identity), so the drawn
/// subtree occupies exactly the slot the host view would have.
@MainActor
private func drawnSubtree(
    _ view: any View, spec: HostViewSpec, replacing node: RenderNode
) -> RenderNode {
    var env = EnvironmentValues()
    env.colorScheme = Runtime.shared.colorScheme
    var ctx = BuildContext(
        path: spec.id + "#drawn", env: env, storage: Runtime.shared.storage)
    let subtree = buildNode(view: AnyView(view), ctx: &ctx)
    if let width = node.fixedWidth { subtree.fixedWidth = width }
    if let height = node.fixedHeight { subtree.fixedHeight = height }
    if node.expandsWidth { subtree.expandsWidth = true }
    if node.expandsHeight { subtree.expandsHeight = true }
    if node.opacity != 1 { subtree.opacity *= node.opacity }
    if let identity = node.identityPath { subtree.identityPath = identity }
    return subtree
}

/// The drawn switch (track + knob), shared iOS-style across GPU backends;
/// previously built inline by `Toggle.makeNode` under the drawn branch.
struct DrawnToggle {
    let on: Bool
    let onToggle: () -> Void

    typealias Body = Never
    var body: Never { fatalError("primitive view") }
}

extension DrawnToggle: _PrimitiveView {
    func makeNode(_ ctx: inout BuildContext) -> RenderNode {
        let trackColor: Color = on ? .green : Color(white: 0, opacity: 0.12)
        let knobOffset: CGFloat = on ? 20 : 2

        let track = RenderNode(kind: .shape(.capsule, fill: trackColor, stroke: nil))
        track.fixedWidth = 51
        track.fixedHeight = 31

        let knob = RenderNode(kind: .shape(.circle, fill: .white, stroke: nil))
        knob.fixedWidth = 27
        knob.fixedHeight = 27

        let knobBox = RenderNode.box(child: knob)
        knobBox.padding = EdgeInsets(top: 2, leading: knobOffset, bottom: 2, trailing: 0)
        knobBox.alignment = .topLeading

        let zstack = RenderNode(kind: .stack(.depth))
        zstack.stackAlignment = .topLeading
        zstack.children = [track, knobBox]

        let switchBox = RenderNode.box(child: zstack)
        switchBox.tapAction = onToggle
        return switchBox
    }
}


// The view conformances, in extensions: declared on the type itself they
// would make the whole type main-actor isolated (see `View`).
extension DrawnToggle: View {}
