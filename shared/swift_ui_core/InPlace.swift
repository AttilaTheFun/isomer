// Building one view again in place. A frame whose changes are all state
// that views own (a `@State` write, an observed model's change, a list's
// window) builds again only the views owning that state, each where it
// stands in last frame's tree, instead of the tree from its root down to
// them. SwiftUI re-evaluates only the bodies whose dependencies changed;
// the core built every view above a change (most of them reused, but each
// one on the way down built, and those holding closures rebuilt whole). In
// Visor each step of a chat's reveal rebuilt the app's root, its split view
// and the sidebar's chrome: 80 of each 100 ms.
//
// Each composite's build is kept as a rebuild site: its view, the context
// it was built in (path, environment, navigation, the style stacks, the
// split column) and the node it built. A partial frame:
//   - finds, for each key written, the nearest site at or above the view
//     owning it that can be built alone;
//   - builds each such site again from its view and context (views inside
//     it are reused as in any build);
//   - makes again what the modifiers around it did to its node in place
//     (an `.onAppear`, an `.id`, a frame's flags), recorded as they ran;
//   - puts the new node where the old one was in last frame's tree, marks
//     the nodes above it changed (`contentEpoch`, for the encoder's cached
//     flattenings), and adds what it read, kept and registered to the
//     cached views above it (whose subtree it now is).
// A frame in which nothing was written (or only state of views that are
// gone) builds nothing: last frame's tree is this frame's.
// A site can be built alone when nothing about it reaches outside it:
//   - no registration in it is read by a container above it (a title, a
//     toolbar item, a URL handler: `registerFrameEffect`'s, unless local);
//   - no view around it changed its node in a way that cannot be made again
//     (a list's row environment: `pinRebuildSite`), and its node is not also
//     an enclosing view's;
//   - its node's kind and size behaviour come out the same (what the
//     containers above it read while they were built).
// And a frame is partial only when nothing else could have changed: no
// build in the tree read runtime state (a volatile build is redone every
// frame, which a partial frame would skip), the root's environment is the
// same (colour scheme, scene phase), the renderer keeps the tree as given
// (component-system renderers: the self-drawing one expands chrome into
// it) and no navigation transition is running. Otherwise, or when a check
// fails partway, the whole tree is built, as before.
//
// With `ISO_VERIFY_PARTIAL` in the host's environment (or
// `verifyPartialFrames` set), each partial frame is followed by a whole
// build of the same changes, and a difference between the two trees is
// logged ("[partial] differs …") and counted (`partialMismatches`).

/// A composite view's last build, to build it again alone.
final class _RebuildSite {
    let path: String
    let view: any View
    let ctx: BuildContext
    let stacks: _BuildStacks
    /// Built as the one view its body came to among a container's children
    /// (`appendChildren`), not through `buildNode`.
    let asPart: Bool
    /// A registration in its build reaches the views above it.
    let reachesUp: Bool
    weak var node: RenderNode?
    /// What the modifiers around it did to its node in place after it was
    /// built (or reused), in order: made again on a new node.
    var mutators: [_NodeMutator] = []
    /// A view around it changed its node in a way not made again, or its
    /// node is an enclosing view's too: it is built with what is around it.
    var pinned = false

    init(path: String, view: any View, ctx: BuildContext, stacks: _BuildStacks, asPart: Bool, reachesUp: Bool, node: RenderNode) {
        self.path = path
        self.view = view
        self.ctx = ctx
        self.stacks = stacks
        self.asPart = asPart
        self.reachesUp = reachesUp
        self.node = node
    }
}

/// A modifier that changed its child's node in place (`_ModifiedView`).
struct _NodeMutator {
    let configure: @MainActor (RenderNode, inout BuildContext) -> RenderNode
    let ctx: BuildContext
}

/// What a build reads besides its `BuildContext`: the style stacks and the
/// split view column being built.
struct _BuildStacks {
    let tabViewStyle: [String]
    let pickerStyle: [String]
    let buttonStyle: [ButtonStyleOption]
    let controlSize: [ControlSize]
    let buttonBorderShape: [ButtonBorderShape]
    let textAlignment: [TextAlignment]
    let labelStyle: [LabelStyleOption]
    let tabCustomization: [Binding<TabViewCustomization>?]
    let splitColumn: String?
    let compactSplitBack: (() -> Void)?
}

extension RenderNode {
    /// A view around this node changes it in a way a view built alone would
    /// not have made again: the composite that built it is not built alone.
    func pinRebuildSite() {
        rebuildSite?.pinned = true
    }
}

extension Runtime {
    var buildStacks: _BuildStacks {
        get {
            _BuildStacks(
                tabViewStyle: tabViewStyleStack, pickerStyle: pickerStyleStack, buttonStyle: buttonStyleStack,
                controlSize: controlSizeStack, buttonBorderShape: buttonBorderShapeStack,
                textAlignment: textAlignmentStack, labelStyle: labelStyleStack,
                tabCustomization: tabCustomizationStack, splitColumn: splitColumnBuilding,
                compactSplitBack: compactSplitBack)
        }
        set {
            tabViewStyleStack = newValue.tabViewStyle
            pickerStyleStack = newValue.pickerStyle
            buttonStyleStack = newValue.buttonStyle
            controlSizeStack = newValue.controlSize
            buttonBorderShapeStack = newValue.buttonBorderShape
            textAlignmentStack = newValue.textAlignment
            labelStyleStack = newValue.labelStyle
            tabCustomizationStack = newValue.tabCustomization
            splitColumnBuilding = newValue.splitColumn
            compactSplitBack = newValue.compactSplitBack
        }
    }

    /// Whether the view at `path` may still be in the tree: its site's node
    /// is alive (or sites are not kept, or a build is under way, or it is the
    /// root or a view whose body is several rows, which have none). A change
    /// a view that is gone observed marks nothing: marked, it had the views
    /// still above its place built again.
    func viewMayBeLive(_ path: Substring) -> Bool {
        !keepsRebuildSites || buildingFrame || path == "root" || rebuildSites[String(path)]?.node != nil
            || multiRowViewPaths.contains(String(path))
    }

    /// Whether builds keep their sites (partial frames possible at all).
    var keepsRebuildSites: Bool {
        partialFramesEnabled && subtreeReuseEnabled && Renderer.hostRendersNavigation
    }

    /// The sites to build again alone this frame, outermost first; nil when
    /// the frame is to be built whole.
    func planPartialFrame(rootEnv: EnvironmentValues) -> [_RebuildSite]? {
        // (The size class is worked out from the width as it is read.)
        guard keepsRebuildSites, retainedTree != nil, !wholeFrameRequested, !treeVolatile, !navTransitionActive,
              let last = lastRootEnv, last.scenePhase == rootEnv.scenePhase, last._sameForReuse(rootEnv),
              lastCompactWidth == compactWidth
        else {
            notePartialRefused(retainedTree == nil || lastRootEnv == nil ? nil
                : wholeFrameRequested ? "asked for" : treeVolatile ? "a volatile build"
                : navTransitionActive ? "a transition" : "the root's environment")
            return nil
        }
        var chosen: [String: _RebuildSite] = [:]
        for key in dirtyStateKeys {
            // State of a view that is gone (a task of a closed chat): its
            // place is built again when it is shown again.
            let owner = key.lastIndex(of: "#").map { String(key[..<$0]) } ?? key
            if let site = rebuildSites[owner], site.node == nil { continue }
            // A `@State`: the views whose builds read it, as SwiftUI updates
            // them, not the view owning it (a composer's draft, passed down
            // as a binding, rebuilt the chat around it on every keystroke).
            // One that no build read changes nothing built (a field shows
            // its own text live).
            if stateKeys.contains(key), !keysReadOutsideBuild.contains(key) {
                for reader in stateReaders[key] ?? [] {
                    if let gone = rebuildSites[reader], gone.node == nil { continue }
                    guard reader != "root", let site = rebuildSite(atOrAbove: reader) else {
                        notePartialRefused("no site for \(_pathTail(reader, 2)), a reader")
                        return nil
                    }
                    chosen[site.path] = site
                }
                continue
            }
            guard let site = rebuildSite(owning: key) else {
                notePartialRefused("no site for \(_pathTail(key, 2))")
                return nil
            }
            chosen[site.path] = site
        }
        // The outermost: a site inside another is built with it.
        let sites = chosen.values.filter { site in
            !chosen.keys.contains { $0 != site.path && _byteAfterPrefix(site.path, $0) == UInt8(ascii: "/") }
        }
        return sites.sorted { $0.path < $1.path }
    }

    /// The nearest site at or above the view owning `key` ("<path>#<name>")
    /// that can be built alone; nil when there is none below the root.
    private func rebuildSite(owning key: String) -> _RebuildSite? {
        guard let hash = key.lastIndex(of: "#") else { return rebuildSite(atOrAbove: key) }
        return rebuildSite(atOrAbove: String(key[..<hash]))
    }

    /// The nearest site at or above the view at `start` that can be built
    /// alone.
    private func rebuildSite(atOrAbove start: String) -> _RebuildSite? {
        var path = Substring(start)
        while !path.isEmpty, path != "root" {
            if let site = rebuildSites[String(path)], site.node != nil, !site.pinned, !site.reachesUp {
                return site
            }
            guard let slash = path.lastIndex(of: "/") else { return nil }
            path = path[..<slash]
        }
        return nil
    }

    /// A composite's build read these states (its own reads, not those of
    /// the views built inside it): it is their reader until it builds again.
    func noteStateReads(path: String, _ reads: [String]) {
        let new = Set(reads)
        let old = compositeStateReads[path] ?? []
        guard new != old else { return }
        for key in old.subtracting(new) {
            stateReaders[key]?.remove(path)
            if stateReaders[key]?.isEmpty == true { stateReaders[key] = nil }
        }
        for key in new.subtracting(old) { stateReaders[key, default: []].insert(path) }
        compositeStateReads[path] = new.isEmpty ? nil : new
    }

    private func notePartialRefused(_ reason: @autoclosure () -> String?) {
        guard let log = frameLog, let reason = reason() else { return }
        log.partial = "whole: " + reason
    }

    /// Builds `sites` again where they stand in `tree`. False when one could
    /// not be built alone after all (the frame is then built whole).
    @MainActor
    func buildInPlace(_ sites: [_RebuildSite], in tree: RenderNode) -> Bool {
        if sites.isEmpty { frameLog?.inPlace = ["nothing"] }
        let outside = buildStacks
        defer { buildStacks = outside }
        for site in sites {
            guard let old = site.node, let trail = _trail(to: old, in: tree), let parent = trail.last else {
                frameLog?.partial = "whole: \(typeName(site.view)) not in the tree"
                return false
            }
            buildStacks = site.stacks
            var ctx = site.ctx
            // The frame's transaction, unless a modifier above chose another.
            if !ctx.env.animationChosen { ctx.env.animation = transactionAnimation }
            buildCache[site.path] = nil
            buildCacheInnerStack.append([])
            buildEffectStack.append([])
            let readsBefore = _bindingReadKeys.count
            var node = _buildCompositeAlone(site.view, ctx: &ctx, asPart: site.asPart)
            if let built = node {
                for mutator in site.mutators {
                    var mctx = mutator.ctx
                    if mutator.configure(built, &mctx) !== built { node = nil; break }
                }
            }
            let effects = buildEffectStack.removeLast()
            let inner = buildCacheInnerStack.removeLast()
            let reads = Array(_bindingReadKeys[min(readsBefore, _bindingReadKeys.count)...])
            guard let node else {
                frameLog?.partial = "whole: \(typeName(site.view)) came to another node"
                return false
            }
            if effects.contains(where: { !$0.local }) {
                frameLog?.partial = "whole: \(typeName(site.view)) registers for a view above it"
                return false
            }
            guard _sameLayout(old, node) else {
                frameLog?.partial = "whole: \(typeName(site.view)) changed kind or size behaviour"
                return false
            }
            // The views around it are as they were: what they did to its node
            // holds for the next time it is built alone.
            if let fresh = node.rebuildSite, fresh.node === node { fresh.mutators = site.mutators }
            _replace(old, with: node, in: parent)
            for above in trail { above.contentEpoch &+= 1 }
            // The cached views above it hold its subtree now: what it read
            // through bindings, the cached views in it and its registrations
            // (local ones) are theirs too. One that read a binding of unknown
            // state makes them rebuild when next reached.
            let unknownRead = reads.contains("")
            var prefix = Substring(site.path)
            while let slash = prefix.lastIndex(of: "/") {
                prefix = prefix[..<slash]
                let path = String(prefix)
                guard var entry = buildCache[path] else { continue }
                if unknownRead {
                    buildCache[path] = nil
                    continue
                }
                entry.bindingDependencies.formUnion(reads)
                entry.inner += inner
                entry.effects += effects
                buildCache[path] = entry
            }
            frameLog?.inPlace.append(typeName(site.view))
        }
        return true
    }
}

/// Builds a composite view (not reusing it), as `buildCompositeReusing` or a
/// container's `appendChildren` does; nil when a body that was one view
/// among a container's children comes to several now.
@MainActor
func _buildCompositeAlone(_ view: any View, ctx: inout BuildContext, asPart: Bool) -> RenderNode? {
    _frameLogBuilt(view, ctx: ctx)
    var build = beginCompositeBuild(view, ctx: ctx)
    build.asPart = asPart
    var sub = ctx.descend(typeName(view))
    guard asPart else {
        let node = _trackingObservation(at: ctx.path) { buildNode(view: view.body, ctx: &sub) }
        finishCompositeBuild(build, view: view, ctx: ctx, node: node)
        return node
    }
    var parts: [RenderNode] = []
    _trackingObservation(at: ctx.path) { appendChildren(of: view.body, ctx: &sub, into: &parts) }
    guard parts.count == 1 else {
        abandonCompositeBuild(build)
        return nil
    }
    if parts[0].buildPath == nil { parts[0].buildPath = sub.path }
    finishCompositeBuild(build, view: view, ctx: ctx, node: parts[0])
    return parts[0]
}

/// The nodes from `root` down to the parent of `target` (root first); nil
/// when `target` is not in the tree.
func _trail(to target: RenderNode, in root: RenderNode) -> [RenderNode]? {
    var trail: [RenderNode] = []
    func visit(_ node: RenderNode) -> Bool {
        trail.append(node)
        for child in node.children where child === target || visit(child) { return true }
        for child in node.background where child === target || visit(child) { return true }
        for child in node.overlay where child === target || visit(child) { return true }
        for child in node.mask where child === target || visit(child) { return true }
        if let content = node.navigationContent, content === target || visit(content) { return true }
        trail.removeLast()
        return false
    }
    return root !== target && visit(root) ? trail : nil
}

/// Puts `new` where `old` is among `parent`'s children.
func _replace(_ old: RenderNode, with new: RenderNode, in parent: RenderNode) {
    if let i = parent.children.firstIndex(where: { $0 === old }) { parent.children[i] = new }
    if let i = parent.background.firstIndex(where: { $0 === old }) { parent.background[i] = new }
    if let i = parent.overlay.firstIndex(where: { $0 === old }) { parent.overlay[i] = new }
    if let i = parent.mask.firstIndex(where: { $0 === old }) { parent.mask[i] = new }
    if parent.navigationContent === old { parent.navigationContent = new }
}

/// Whether two nodes are the same to the containers above them, which read
/// them while they were built: their kind, how they size, and what a list
/// reads of its rows. Compared field by field: described (the case through
/// `Mirror`, each value as text), the comparison cost a keystroke's partial
/// frame more than the view it built.
func _sameLayout(_ a: RenderNode, _ b: RenderNode) -> Bool {
    a.kind.caseIndex == b.kind.caseIndex
        && a.expandsWidth == b.expandsWidth && a.expandsHeight == b.expandsHeight
        && a.fixedWidth == b.fixedWidth && a.fixedHeight == b.fixedHeight
        && a.minWidth == b.minWidth && a.minHeight == b.minHeight
        && a.maxWidth == b.maxWidth && a.maxHeight == b.maxHeight
        && a.spacerAxis == b.spacerAxis && a.scrollTarget == b.scrollTarget
        && a.ownsNavigation == b.ownsNavigation && a.hidesRowSeparator == b.hidesRowSeparator
        && a.isRowPlaceholder == b.isRowPlaceholder && a.isList == b.isList
}

// MARK: - Verifying partial frames

/// The tree as text, every field of each node that differs from a new
/// node's, children indented under it: two builds of the same frame read
/// the same. (What layout and the encoder keep on nodes is left out.)
func _describeTree(_ root: RenderNode) -> String {
    var lines: [String] = []
    func visit(_ node: RenderNode, _ indent: String, _ role: String) {
        var line = indent + role
        for field in Mirror(reflecting: node).children {
            guard let label = field.label, !_describeSkipped.contains(label) else { continue }
            let value = _describeField(field.value)
            if _describeDefaults[label] != value { line += " \(label)=\(value)" }
        }
        lines.append(line)
        let deeper = indent + "  "
        for child in node.children { visit(child, deeper, "") }
        for child in node.background { visit(child, deeper, "bg ") }
        for child in node.overlay { visit(child, deeper, "ov ") }
        for child in node.mask { visit(child, deeper, "mask ") }
        if let content = node.navigationContent { visit(content, deeper, "nav ") }
    }
    visit(root, "", "")
    return lines.joined(separator: "\n")
}

/// A field as text; a host view's parameters in key order (a dictionary's
/// order is its own, two equal ones printing differently).
private func _describeField(_ value: Any) -> String {
    if let kind = value as? RenderNode.Kind, case .hostView(let spec) = kind {
        let params = spec.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        return "hostView(\(spec.id) \(spec.kind) [\(params)] \(spec.value) \(spec.options) \(spec.onChange == nil ? "" : "onChange"))"
    }
    return String(describing: value)
}

private let _describeSkipped: Set<String> = [
    "children", "background", "overlay", "navigationContent", "rebuildSite", "contentEpoch",
    "isReusedSubtreeRoot", "frame", "measuredChildSizes", "scrollContentSize",
]

nonisolated(unsafe) private var _describeDefaultsMade: [String: String]?
private var _describeDefaults: [String: String] {
    if let made = _describeDefaultsMade { return made }
    var made: [String: String] = [:]
    for field in Mirror(reflecting: RenderNode(kind: .box)).children {
        if let label = field.label { made[label] = String(describing: field.value) }
    }
    _describeDefaultsMade = made
    return made
}

/// What decides which of a list's rows a build builds.
struct _ListWindowState {
    let visible: [String: ClosedRange<Int>]
    let anchors: [String: String]
    let built: [String: [ClosedRange<Int>]]
    let builtPaths: [String: Set<String>]
    let counts: [String: Int]
    let paths: [String: [String]]
    let epochs: [String: Int]
    let scrollSeen: (tick: Int, frames: Int)
}

extension Runtime {
    var listWindowState: _ListWindowState {
        get {
            _ListWindowState(visible: listVisibleRows, anchors: listVisibleAnchor, built: listBuiltRows,
                             builtPaths: listBuiltPaths, counts: listRowCounts, paths: listRowPaths,
                             epochs: listEpochs, scrollSeen: scrollRequestSeen)
        }
        set {
            listVisibleRows = newValue.visible
            listVisibleAnchor = newValue.anchors
            listBuiltRows = newValue.built
            listBuiltPaths = newValue.builtPaths
            listRowCounts = newValue.counts
            listRowPaths = newValue.paths
            listEpochs = newValue.epochs
            scrollRequestSeen = newValue.scrollSeen
        }
    }

    /// A partial frame's tree was not the whole build's: logged with where.
    func notePartialMismatch(whole: String, partial: String, sites: [_RebuildSite]) {
        partialMismatches &+= 1
        let a = whole.split(separator: "\n", omittingEmptySubsequences: false)
        let b = partial.split(separator: "\n", omittingEmptySubsequences: false)
        var at = 0
        while at < min(a.count, b.count), a[at] == b[at] { at += 1 }
        let names = sites.map { typeName($0.view) }.joined(separator: ", ")
        let line = { (lines: [Substring]) in at < lines.count ? String(lines[at].prefix(600)) : "(end)" }
        host?.log("[partial] differs (in place: \(names)) at node \(at):\n  whole:   \(line(a))\n  partial: \(line(b))")
    }
}
