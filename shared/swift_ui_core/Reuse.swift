// Subtree reuse: SwiftUI's rule that a view whose inputs have not changed is
// not re-evaluated. A composite view (an app's `struct: View`) whose stored
// properties equal last frame's, under the same environment and context,
// with no state below it written since, hands back the subtree it built
// last time instead of running its body again — so a streaming update to one
// row of a long list rebuilds that row, not the list.
//
// What makes a subtree reusable is decided while it builds, conservatively:
//   • every built-in view in it builds purely (`_ReusableBuild`): its node is
//     a function of its inputs, the environment and the context stacks. Views
//     that read or register runtime state (navigation, tabs, presentations,
//     tasks, `onChange`, remote images, …) don't conform, and building one
//     marks the build volatile, which no enclosing view can be reused across;
// A view whose own inputs cannot be compared (closures, class references,
// bindings) is simply rebuilt each frame; views inside it can still be reused.
// The root view always rebuilds.

/// A built-in view that says whether building it this time is pure. The
/// default is yes; `_ModifiedView` and the animation modifiers decide per use.
protocol _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool
}

extension _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { true }
}

extension Text: _ReusableBuild {}
extension Color: _ReusableBuild {}
extension VStack: _ReusableBuild {}
extension HStack: _ReusableBuild {}
extension ZStack: _ReusableBuild {}
extension LazyVStack: _ReusableBuild {}
extension LazyHStack: _ReusableBuild {}
extension Spacer: _ReusableBuild {}
extension Divider: _ReusableBuild {}
extension ProgressView: _ReusableBuild {}
extension Button: _ReusableBuild {}
extension _StackScopedView: _ReusableBuild {}
extension _EnvironmentModifier: _ReusableBuild {}
extension _TaggedView: _ReusableBuild {}
extension AnyView: _ReusableBuild {}
extension GeometryReader: _ReusableBuild {}
extension Image: _ReusableBuild {}
extension _ShapeView: _ReusableBuild {}
extension _GradientShapeView: _ReusableBuild {}
extension Rectangle: _ReusableBuild {}
extension RoundedRectangle: _ReusableBuild {}
extension Circle: _ReusableBuild {}
extension Capsule: _ReusableBuild {}
extension LinearGradient: _ReusableBuild {}
extension RadialGradient: _ReusableBuild {}
extension AngularGradient: _ReusableBuild {}

extension _ModifiedView: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { pure }
}

/// A share link's node is its item and label, under the button style (part
/// of the reuse context).
extension ShareLink: _ReusableBuild {}

/// `.onChange` compares its value when it builds, against the one stored at
/// its path (kept while the app runs); a subtree reused unchanged has no
/// change to report, as SwiftUI's does not when it skips a body.
extension _OnChangeView: _ReusableBuild {}

/// `.task` runs from its node's appearance (a reused node keeps its own),
/// and its id is one of the inputs compared.
extension _TaskModifier: _ReusableBuild {}

/// Views that register what a container reads after building its content
/// (a title, toolbar items, a search field, a column width): their
/// registrations are made again when a view around them is reused
/// (`registerFrameEffect`), so they build purely.
extension _NavigationTitleView: _ReusableBuild {}
extension _NavigationSubtitleView: _ReusableBuild {}
extension _ToolbarTitleDisplayModeView: _ReusableBuild {}
extension _ToolbarView: _ReusableBuild {}
extension ToolbarItem: _ReusableBuild {}
extension ToolbarItemGroup: _ReusableBuild {}
extension ToolbarSpacer: _ReusableBuild {}
extension DefaultToolbarItem: _ReusableBuild {}
extension _ColumnWidthView: _ReusableBuild {}
extension _RegisterSearch: _ReusableBuild {}

/// A safe-area inset is its two parts, stacked.
extension _SafeAreaInsetView: _ReusableBuild {}

/// A scroll view's build is its content's (where it is scrolled to is the
/// host's, and the encoder reads a scroll afresh every pass).
extension ScrollView: _ReusableBuild {}

/// On hosts with native navigation a stack's build is its content's and its
/// state's: a push or a pop marks it changed, and what it clears, takes and
/// registers each build is made again when a view around it is reused. A
/// split view's likewise (its bindings are tracked, its columns' width and
/// selection are registrations, a re-tap marks it changed). The drawn ones
/// animate their transitions in the core: built every frame.
extension NavigationStack: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { Renderer.hostRendersNavigation }
}
extension NavigationSplitView: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { Renderer.hostRendersNavigation }
}

/// A link is its label with a tap that pushes onto its stack (the same
/// stack while the link is reused).
extension NavigationLink: _ReusableBuild {}

/// A list's build depends on the rows the host shows: a report that needs
/// rows built, the rest of a page built a few a frame, and a scroll request
/// mark the list's state changed (`#window`), so the views around it are
/// rebuilt then and reused otherwise. Its other registrations (a sidebar's
/// selection, its cached cells) are made again when they are reused.
extension List: _ReusableBuild {}

/// A text field's node reads its text when it is encoded (the encoder
/// flattens a field afresh every pass), so a reused one shows the current
/// text; the rest is its inputs and the environment.
extension TextField: _ReusableBuild {}
extension TextEditor: _ReusableBuild {}

/// A file or photo picker while closed is its child, as a presentation is.
extension _PickerRequest: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { !isPresented.wrappedValue }
}

/// A presentation while closed is its child; open, it registers what it
/// presents with every build. Reading `isPresented` counts as a binding
/// read, so a view holding a binding to it from above is rebuilt as before.
extension _PresentationModifier: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool { !isPresented.wrappedValue }
}

/// Interpolated modifiers are pure while their own value is not animating:
/// their value is then their target. One that is animating is marked changed
/// each frame (`Runtime.buildFrameTree`), so the views around it are built
/// again then; before, any animation anywhere (a chat's reveal) made every
/// such modifier, and every view holding one, rebuild each frame.
extension _AnimatableEnvModifier: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool {
        !Runtime.shared.animator.isAnimating(at: ctx.path)
    }
}

extension _AnimatableBoxModifier: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool {
        !Runtime.shared.animator.isAnimating(at: ctx.path)
    }
}

/// A per-frame registration (`registerFrameEffect`), kept to be made again.
struct _FrameEffect {
    let run: @MainActor () -> Void
    /// Read by no container: the build's own bookkeeping.
    let local: Bool
}

/// One reusable subtree: the view and what it was built under, the node it
/// built, and the reusable views built inside it (kept alive while it is).
struct _BuildCacheEntry {
    let view: Any
    let env: EnvironmentValues
    let context: String
    let navigationLevel: Int
    let navigation: ObjectIdentifier?
    let node: RenderNode
    var inner: [String]
    /// The per-frame registrations its build made (a navigation title,
    /// toolbar items, a URL handler, …), made again when it is reused.
    var effects: [_FrameEffect]
    /// The state outside it that it read through bindings: it is rebuilt
    /// when any of it changes.
    var bindingDependencies: Set<String>
}

extension Runtime {
    /// Marks the build in progress as reading or registering runtime state:
    /// no view around it is reused.
    func markBuildVolatile() { buildVolatility &+= 1 }

    /// Makes a registration the frame's build expects (a navigation title,
    /// toolbar items, a search field, a URL handler: what a container reads
    /// after building its content, cleared each frame): now, and again
    /// whenever a view built around it is reused instead of built, so a
    /// built-in view that only registers builds purely. `local`: what it
    /// registers is the build's own bookkeeping, read by no container (a
    /// list's cells kept); any other reaches the views above it, and a view
    /// holding one is not built again alone (InPlace.swift).
    @MainActor
    func registerFrameEffect(local: Bool = false, _ effect: @escaping @MainActor () -> Void) {
        effect()
        if !buildEffectStack.isEmpty { buildEffectStack[buildEffectStack.count - 1].append(_FrameEffect(run: effect, local: local)) }
    }

    /// A reused entry's registrations, made again, and kept with the views
    /// being built around it.
    @MainActor
    func replayFrameEffects(_ effects: [_FrameEffect]) {
        guard !effects.isEmpty else { return }
        for effect in effects { effect.run() }
        if !buildEffectStack.isEmpty { buildEffectStack[buildEffectStack.count - 1] += effects }
    }

    /// The registrations a composite's build made, handed to the one around
    /// it (whose reuse makes them too).
    func popFrameEffects() -> [_FrameEffect] {
        let effects = buildEffectStack.removeLast()
        if !effects.isEmpty, !buildEffectStack.isEmpty { buildEffectStack[buildEffectStack.count - 1] += effects }
        return effects
    }

    /// Called when state at `key` ("<view path>#<property>") changes: the
    /// view that owns it, and every view around it, rebuild next frame.
    func stateDidChange(key: String) {
        dirtyStateKeys.insert(key)
    }

    /// The context stacks' tops descendants read while building: part of
    /// what a reused subtree must have been built under.
    func reuseContext() -> String {
        if let reuseContextCache { return reuseContextCache }
        var s = ""
        s += textAlignmentStack.last.map { "\($0)" } ?? "-"; s += "|"
        s += buttonStyleStack.last.map { "\($0)" } ?? "-"; s += "|"
        s += controlSizeStack.last.map { "\($0)" } ?? "-"; s += "|"
        s += buttonBorderShapeStack.last.map { "\($0)" } ?? "-"; s += "|"
        s += labelStyleStack.last.map { "\($0)" } ?? "-"; s += "|"
        s += pickerStyleStack.last ?? "-"; s += "|"
        s += tabViewStyleStack.last ?? "-"; s += "|"
        s += "\(tabCustomizationStack.count)"
        reuseContextCache = s
        return s
    }

    /// Whether state owned by the view at `path`, or by any view below it,
    /// was written since the last frame.
    func hasDirtyState(under path: String) -> Bool {
        guard !buildDirtyKeys.isEmpty else { return false }
        for key in buildDirtyKeys {
            if let next = _byteAfterPrefix(key, path), next == UInt8(ascii: "/") || next == UInt8(ascii: "#") { return true }
        }
        return false
    }

    /// Keeps a reused entry, and the reusable entries inside it, for the next
    /// frame.
    func touchBuildCache(_ path: String) {
        guard buildCacheTouched.insert(path).inserted, let entry = buildCache[path] else { return }
        for inner in entry.inner { touchBuildCache(inner) }
    }

    /// Records a reusable entry built (or reused) inside the view building
    /// now, so reusing that view keeps it alive.
    func noteInnerCacheEntry(_ path: String) {
        guard !buildCacheInnerStack.isEmpty else { return }
        buildCacheInnerStack[buildCacheInnerStack.count - 1].append(path)
    }

    /// Frame start: the state written since the last build is what this
    /// build must not reuse across.
    func beginReuseFrame() {
        _bindingReadKeys.removeAll(keepingCapacity: true)
        buildDirtyKeys = dirtyStateKeys
        dirtyStateKeys = []
        buildCacheTouched.removeAll(keepingCapacity: true)
    }

    /// Frame end: entries no view reached this frame are gone. A partial
    /// frame (InPlace.swift) reached only the views it built: nothing goes.
    func endReuseFrame(partial: Bool = false) {
        if !partial {
            if buildCache.count != buildCacheTouched.count {
                buildCache = buildCache.filter { buildCacheTouched.contains($0.key) }
            }
            if listCells.count != listCellsTouched.count {
                listCells = listCells.filter { listCellsTouched.contains($0.key) }
            }
            // Sites whose node is gone, once they add up.
            if rebuildSites.count > rebuildSitesKept * 2 + 256 {
                rebuildSites = rebuildSites.filter { $0.value.node != nil }
                rebuildSitesKept = rebuildSites.count
            }
        }
        listCellsTouched.removeAll(keepingCapacity: true)
        buildDirtyKeys = []
    }

    /// Forget every reusable subtree (a new root, a hot reload, a restart).
    func resetBuildCache() {
        buildCache = [:]
        rebuildSites = [:]
        stateReaders = [:]
        compositeStateReads = [:]
        keysReadOutsideBuild = []
        treeVolatile = true
        lastRootEnv = nil
        buildCacheTouched = []
        dirtyStateKeys = []
        buildDirtyKeys = []
        listVisibleRows = [:]
        listBuiltRows = [:]
        listRowCounts = [:]
        listRowPaths = [:]
        listVisibleAnchor = [:]
        multiRowViewPaths = []
        listCells = [:]
        listCellsTouched = []
        listRowTargets = [:]
        appearanceRowPaths = [:]
    }
}

/// Builds a composite view, reusing last frame's subtree when its inputs,
/// environment and context are unchanged and nothing below it changed.
@MainActor
func buildCompositeReusing(_ view: any View, ctx: inout BuildContext) -> RenderNode {
    if let node = reusedSubtree(for: view, ctx: ctx) { return node }
    _frameLogBuilt(view, ctx: ctx)
    let build = beginCompositeBuild(view, ctx: ctx)
    var sub = ctx.descend(typeName(view))
    // Its body, and the build of what it returned (a ForEach's rows), with
    // the observable properties they read tracked (ObservationSupport).
    let node = _trackingObservation(at: ctx.path) { buildNode(view: view.body, ctx: &sub) }
    finishCompositeBuild(build, view: view, ctx: ctx, node: node)
    return node
}

/// Last frame's subtree for the composite view at `ctx.path`, when it can be
/// handed back unbuilt.
@MainActor
func reusedSubtree(for view: any View, ctx: BuildContext) -> RenderNode? {
    let runtime = Runtime.shared
    let path = ctx.path
    guard runtime.subtreeReuseEnabled, path != "root", let entry = runtime.buildCache[path],
          type(of: entry.view) == type(of: view),
          entry.navigationLevel == ctx.navigationLevel,
          entry.navigation == ctx.navigation.map(ObjectIdentifier.init),
          !runtime.hasDirtyState(under: path),
          reuseEqual(entry.view, view),
          entry.env._sameForReuse(ctx.env),
          entry.context == runtime.reuseContext(),
          entry.bindingDependencies.isDisjoint(with: runtime.buildDirtyKeys)
    else { return nil }
    // What it read through bindings, for the views around it to depend on.
    _bindingReadKeys += entry.bindingDependencies
    // Handed to the views around it again: what they do to its node now is
    // recorded afresh (InPlace.swift).
    if let site = runtime.rebuildSites[path], site.node === entry.node {
        site.mutators.removeAll()
        site.pinned = false
        entry.node.rebuildSite = site
    }
    runtime.touchBuildCache(path)
    runtime.noteInnerCacheEntry(path)
    runtime.replayFrameEffects(entry.effects)
    runtime.reusedSubtrees &+= 1
    return entry.node
}

/// A composite view's build in progress (`beginCompositeBuild` connects its
/// state; its body is evaluated by the caller).
struct _CompositeBuild {
    let volatility: Int
    let context: String
    /// Identified bindings read before the build (a build that reads one's
    /// value is not reusable: only the binding is compared).
    let bindingReads: Int
    /// When it started (the frame log's timing; 0 when off).
    var started = 0.0
    /// The context stacks it was built in (nil when sites are not kept).
    let stacks: _BuildStacks?
    /// Built as the one view its body came to among a container's
    /// children (InPlace.swift).
    var asPart = false
}

func beginCompositeBuild(_ view: any View, ctx: BuildContext) -> _CompositeBuild {
    let runtime = Runtime.shared
    let build = _CompositeBuild(
        volatility: runtime.buildVolatility,
        context: runtime.subtreeReuseEnabled ? runtime.reuseContext() : "",
        bindingReads: _bindingReadKeys.count,
        started: _frameLogStart(),
        stacks: runtime.keepsRebuildSites ? runtime.buildStacks : nil)
    runtime.buildCacheInnerStack.append([])
    runtime.buildEffectStack.append([])
    runtime.stateReadStack.append([])
    connectDynamicProperties(of: view, path: ctx.path, storage: ctx.storage, env: ctx.env)
    return build
}

/// Ends a composite view's build with the node it produced: kept for reuse
/// when nothing in the build was volatile and the view's inputs compare.
func finishCompositeBuild(_ build: _CompositeBuild, view: any View, ctx: BuildContext, node: RenderNode) {
    let runtime = Runtime.shared
    if build.started != 0 { _frameLogTime(view, started: build.started) }
    let inner = runtime.buildCacheInnerStack.removeLast()
    let effects = runtime.popFrameEffects()
    runtime.noteStateReads(path: ctx.path, runtime.stateReadStack.removeLast())
    if let stacks = build.stacks, ctx.path != "root" {
        // Its node is also the one an inner view's build ended with: that
        // view is built with this one (InPlace.swift).
        if let innerSite = node.rebuildSite, innerSite.node === node, innerSite.path != ctx.path { innerSite.pinned = true }
        let site = _RebuildSite(path: ctx.path, view: view, ctx: ctx, stacks: stacks, asPart: build.asPart,
                                reachesUp: effects.contains { !$0.local }, node: node)
        node.rebuildSite = site
        runtime.rebuildSites[ctx.path] = site
    }
    if runtime.subtreeReuseEnabled, ctx.path != "root",
       runtime.buildVolatility == build.volatility,
       let dependencies = _bindingDependencies(since: build.bindingReads, path: ctx.path),
       _frameLogTypeFact("comparable", type(of: view), { reuseComparable(view) }) {
        node.isReusedSubtreeRoot = true
        runtime.buildCache[ctx.path] = _BuildCacheEntry(
            view: view, env: ctx.env, context: build.context, navigationLevel: ctx.navigationLevel,
            navigation: ctx.navigation.map(ObjectIdentifier.init), node: node, inner: inner, effects: effects,
            bindingDependencies: dependencies)
        runtime.buildCacheTouched.insert(ctx.path)
        runtime.noteInnerCacheEntry(ctx.path)
    } else {
        if runtime.subtreeReuseEnabled {
            _frameLogNotKept(path: ctx.path, volatile: runtime.buildVolatility != build.volatility,
                             bindingRead: _bindingDependencies(since: build.bindingReads, path: ctx.path) == nil)
        }
        // Not reusable itself: what was reusable inside it stays reachable
        // through the views around it.
        for entry in inner { runtime.noteInnerCacheEntry(entry) }
    }
}

/// Ends a composite view's build that produced no single node (a view whose
/// body is several list rows): it is not kept, what was inside it is.
func abandonCompositeBuild(_ build: _CompositeBuild) {
    let runtime = Runtime.shared
    let inner = runtime.buildCacheInnerStack.removeLast()
    _ = runtime.popFrameEffects()
    // Read by a view that is several rows: the view around it reads it.
    let reads = runtime.stateReadStack.removeLast()
    if !runtime.stateReadStack.isEmpty { runtime.stateReadStack[runtime.stateReadStack.count - 1] += reads }
    for entry in inner { runtime.noteInnerCacheEntry(entry) }
}

// MARK: - Comparing inputs

private func equalsSame<T: Equatable>(_ lhs: T, _ rhs: Any) -> Bool {
    guard let rhs = rhs as? T else { return false }
    return lhs == rhs
}

/// Whether two values of a view's inputs are the same, the way SwiftUI
/// compares a view's fields: Equatable values by `==`, other structs, enums
/// and tuples field by field. Closures, class instances and anything else
/// that cannot be compared are never the same (the view rebuilds).
func reuseEqual(_ a: Any, _ b: Any, depth: Int = 0) -> Bool {
    // A struct, by its type's plan (ReusePlan.swift): no reflection.
    if let planned = _plannedReuseEqual(a, b, depth: depth) { return planned }
    if _metadataKind(type(of: a)) == 0x302 { return false }
    // Bindings to the same state (its identity) read and write the same
    // value. (Known by descriptor, before Equatable is asked, which a
    // binding is not: each such question scans the conformances once.)
    if _isBindingType(type(of: a)), let x = a as? _IdentifiedBinding, let y = b as? _IdentifiedBinding {
        guard let identity = x._reuseIdentity else { return false }
        return identity == y._reuseIdentity
    }
    // Property wrappers: `@State` changes arrive as dirty state, and
    // `@Environment` reads the environment compared separately.
    if _isReuseTransparentType(type(of: a)) { return true }
    if let equatable = a as? any Equatable { return equalsSame(equatable, b) }
    #if canImport(Observation)
    // The same `@Observable` model: what the view reads of it is tracked.
    if let same = _sameObservableInstance(a, b) { return same }
    #endif
    guard depth < 8 else { return false }
    let ma = Mirror(reflecting: a)
    let mb = Mirror(reflecting: b)
    switch ma.displayStyle {
    case .struct?, .tuple?, .optional?, .collection?:
        break
    case .enum?:
        // Payload-free cases have no children: compare the case.
        if ma.children.isEmpty, mb.children.isEmpty { return "\(a)" == "\(b)" }
    default:
        return false
    }
    guard ma.children.count == mb.children.count else { return false }
    for (x, y) in zip(ma.children, mb.children) {
        if x.label != y.label || !reuseEqual(x.value, y.value, depth: depth + 1) { return false }
    }
    return true
}

/// Whether a view's inputs can be compared at all (no closures, class
/// instances or bindings among them).
func reuseComparable(_ value: Any, depth: Int = 0) -> Bool {
    if _metadataKind(type(of: value)) == 0x302 { return false }
    if let planned = _plannedReuseComparable(value, depth: depth) { return planned }
    if _isBindingType(type(of: value)), let binding = value as? _IdentifiedBinding { return binding._reuseIdentity != nil }
    if _isReuseTransparentType(type(of: value)) { return true }
    if value is any Equatable { return true }
    #if canImport(Observation)
    if _sameObservableInstance(value, value) != nil { return true }
    #endif
    guard depth < 8 else { return false }
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .struct?, .tuple?, .optional?, .collection?, .enum?:
        return mirror.children.allSatisfy { reuseComparable($0.value, depth: depth + 1) }
    default:
        return false
    }
}

/// Property wrappers whose changes the reuse check sees another way.
protocol _ReuseTransparentProperty {}
extension State: _ReuseTransparentProperty {}
extension Environment: _ReuseTransparentProperty {}

extension EnvironmentValues {
    /// Whether a subtree built under `self` would build the same under
    /// `other`. Closures compare by presence (an `onSubmit` or `dismiss` in
    /// scope comes from the same presentation or field frame to frame);
    /// custom values by `==` when they are Equatable.
    func _sameForReuse(_ other: EnvironmentValues) -> Bool {
        // Not the transaction's animation: a subtree whose inputs, state and
        // environment are otherwise the same has nothing that animation would
        // move (the animator interpolates values whose targets changed, and
        // a view mid-animation makes its build volatile). Compared, every
        // view was rebuilt on each frame in or out of a `withAnimation`, a
        // chat's reveal and settling among them.
        // The same storage: no copy of it was changed since.
        if _storage === other._storage { return true }
        guard font == other.font, foregroundColor == other.foregroundColor, tint == other.tint,
              foregroundColorSet == other.foregroundColorSet, fontSet == other.fontSet,
              labelsHidden == other.labelsHidden, formRow == other.formRow,
              containerAlignment == other.containerAlignment,
              (onSubmit == nil) == (other.onSubmit == nil),
              (refresh == nil) == (other.refresh == nil),
              textFieldStyle == other.textFieldStyle, listStyle == other.listStyle,
              listRowSeparators == other.listRowSeparators,
              listRowInsets == other.listRowInsets, listRowBackground == other.listRowBackground,
              // A view can't be compared: an environment holding one is
              // never taken to be the same.
              listRowBackgroundView == nil, other.listRowBackgroundView == nil,
              scrollIndicatorsHidden == other.scrollIndicatorsHidden,
              scrollContentBackgroundHidden == other.scrollContentBackgroundHidden,
              defaultMinListRowHeight == other.defaultMinListRowHeight,
              scrollDismissesKeyboard == other.scrollDismissesKeyboard,
              scrollBounceBehavior == other.scrollBounceBehavior,
              _isScrollEnabled == other._isScrollEnabled,
              scrollEdgeTop == other.scrollEdgeTop, scrollEdgeBottom == other.scrollEdgeBottom,
              keyboardType == other.keyboardType, autocapitalization == other.autocapitalization,
              autocorrectionDisabled == other.autocorrectionDisabled,
              truncationMode == other.truncationMode, minimumScaleFactor == other.minimumScaleFactor,
              menuIndicatorHidden == other.menuIndicatorHidden,
              textCase == other.textCase, lineSpacing == other.lineSpacing,
              opacity == other.opacity, _isEnabled == other._isEnabled, lineLimit == other.lineLimit,
              lineRange == other.lineRange,
              colorScheme == other.colorScheme,
              horizontalSizeClass == other.horizontalSizeClass,
              verticalSizeClass == other.verticalSizeClass,
              tabIconSize == other.tabIconSize,
              custom.count == other.custom.count, objects.count == other.objects.count
        else { return false }
        for (key, value) in custom {
            guard let theirs = other.custom[key], reuseEqual(value, theirs) else { return false }
        }
        for (key, object) in objects {
            guard let theirs = other.objects[key], theirs === object else { return false }
        }
        return true
    }
}

// Wrappers over state the core cannot see change per view. (Not the
// observed objects: a change to one marks the views observing it, as a
// `@State` write does — Observable.swift.)
extension AppStorage { var _blocksSubtreeReuse: Bool { true } }
// Not `@FocusState`: it is a `@State` underneath (the same storage slot,
// written when the host moves focus), so a change to it marks its view
// changed as any state does; treated as unseen, it made the view holding it
// (a composer) and every view around it rebuild on every frame.

// MARK: - Lazy list rows

/// The rows of a List built this frame: around what the host shows, and
/// any row a scroll request is after.
struct _ListBuildWindow {
    let ranges: [ClosedRange<Int>]
    let extra: Set<Int>
    /// Rows in the ranges left for a later frame (see `listNewRowsPerFrame`).
    var deferred: Set<Int> = []
    func contains(_ index: Int) -> Bool {
        extra.contains(index) || (ranges.contains { $0.contains(index) } && !deferred.contains(index))
    }
}

/// A List row's cell as built last frame, and what it was built from.
struct _ListCell {
    let content: RenderNode?
    let placeholder: Bool
    let selectable: Bool
    let selected: Bool
    let hidesSeparator: Bool
    let cell: RenderNode
}

extension Runtime {
    /// Rows beyond what the host shows that are built too, so a scroll
    /// finds them ready.
    static let listOverscan = 100
    /// How near the edge of the built rows the shown ones may come before
    /// the list is built again: a rebuild is a whole render, so it should
    /// come seldom while scrolling (tall rows cross many rows a fling).
    static let listRebuildMargin = 30
    /// Rows built at each end of a list the host has not reported on yet
    /// (a chat opens at its end).
    static let listInitialRows = 30
    /// Rows a frame builds that the last frame did not, beyond those on
    /// screen: a page of earlier rows put in above the reader would otherwise
    /// all be built in one frame (the overscan's worth of new rows, whole
    /// messages laid out), and that frame came late. The rest follow in the
    /// next frames, nearest first; they are off screen meanwhile.
    static let listNewRowsPerFrame = 24

    /// Which of a list's rows to build this frame (`rowPaths`: each row's
    /// place in the list's content).
    func listBuildWindow(list: String, rowPaths: [String]) -> _ListBuildWindow {
        let count = rowPaths.count
        guard count > 0 else { return _ListBuildWindow(ranges: [], extra: []) }
        var ranges: [ClosedRange<Int>]
        // A report that saw the whole list (a thread still loading: its
        // placeholder and status rows) says nothing about where a longer one
        // is shown: it is built as it opens, at both ends.
        if let visible = listVisibleRows[list], let shown = listRowCounts[list],
           count > shown, visible.lowerBound == 0, visible.upperBound >= shown - 1 {
            listVisibleRows[list] = nil
            listVisibleAnchor[list] = nil
            listEpochs[list, default: 0] += 1
        }
        // What the host showed, where its top row is now: rows loaded above
        // move it down; rows that are not these rows at all (another
        // conversation in the same pane) leave nothing to follow, and the
        // list is built as it opens, at both ends.
        if var visible = listVisibleRows[list], let anchor = listVisibleAnchor[list] {
            let at = visible.lowerBound < count && rowPaths[visible.lowerBound] == anchor
                ? visible.lowerBound : rowPaths.firstIndex(of: anchor)
            if let at {
                visible = at...(at + visible.count - 1)
                listVisibleRows[list] = visible
            } else {
                listVisibleRows[list] = nil
                listVisibleAnchor[list] = nil
                listEpochs[list, default: 0] += 1
            }
        }
        var deferred: Set<Int> = []
        if let visible = listVisibleRows[list] {
            let lower = max(0, min(visible.lowerBound, count - 1) - Runtime.listOverscan)
            let upper = min(count - 1, visible.upperBound + Runtime.listOverscan)
            ranges = [lower...max(lower, upper)]
            // Off screen and not built last frame: a few a frame.
            let built = listBuiltPaths[list] ?? []
            let shown = min(visible.lowerBound, count - 1)...min(max(visible.upperBound, visible.lowerBound), count - 1)
            var fresh: [Int] = []
            for index in lower...max(lower, upper) where !shown.contains(index) && !built.contains(rowPaths[index]) {
                fresh.append(index)
            }
            if fresh.count > Runtime.listNewRowsPerFrame {
                fresh.sort { distance($0, to: shown) < distance($1, to: shown) }
                deferred = Set(fresh[Runtime.listNewRowsPerFrame...])
                // The rest next frame: the list builds again then.
                stateDidChange(key: list + "#window")
                requestFrame()
            }
        } else {
            let head = 0...min(count - 1, Runtime.listInitialRows - 1)
            let tail = max(0, count - Runtime.listInitialRows)...(count - 1)
            // A list that opens at its end (a chat) builds its end alone:
            // its first rows are far off screen, and a row there that loads
            // more when it appears (an earlier page) would load on opening.
            ranges = listsAnchoredAtBottom.contains(list) ? [tail] : [head, tail]
        }
        // A scroll request for a row's `ForEach` id builds that row, for the
        // few frames the host takes to act on it.
        var extra: Set<Int> = []
        if let request = pendingScroll {
            if request.tick != scrollRequestSeen.tick {
                scrollRequestSeen = (request.tick, 0)
            }
            scrollRequestSeen.frames += 1
            if scrollRequestSeen.frames <= 8 {
                let marker = "/fe-" + request.target
                let known = listRowTargets[list]?[request.target]
                for (index, path) in rowPaths.enumerated() where path.hasSuffix(marker) || path == known {
                    extra.insert(index)
                }
            }
        }
        listBuiltRows[list] = ranges
        listRowCounts[list] = count
        if listRowPaths[list] != rowPaths {
            if let old = listRowPaths[list] {
                for path in old { listRowIndex[path] = nil }
            }
            for (index, path) in rowPaths.enumerated() { listRowIndex[path] = (list, index) }
            appearanceRowPaths.removeAll(keepingCapacity: true)
        }
        listRowPaths[list] = rowPaths
        var builtPaths: Set<String> = []
        for range in ranges {
            for index in range where !deferred.contains(index) { builtPaths.insert(rowPaths[index]) }
        }
        listBuiltPaths[list] = builtPaths
        return _ListBuildWindow(ranges: ranges, extra: extra, deferred: deferred)
    }

    /// The lists with a row for `target` (a `ForEach` id, or a view's `.id`
    /// in a row) that they have not built.
    func listsMissingScrollTarget(_ target: String) -> [String] {
        let marker = "/fe-" + target
        return listRowPaths.compactMap { list, paths in
            let known = listRowTargets[list]?[target]
            guard let path = paths.first(where: { $0.hasSuffix(marker) || $0 == known }) else { return nil }
            return (listBuiltPaths[list] ?? []).contains(path) ? nil : list
        }
    }

    /// Whether the list at `list` has the row the pending scroll request is
    /// for (worked out once per request and row count): only that list is
    /// handed the request, so the others' encoding stays cached.
    func listHoldsScrollTarget(_ list: String) -> Bool {
        guard let request = pendingScroll else { return false }
        let rows = listRowCounts[list]
        if let memo = scrollTargetMemo[list], memo.tick == request.tick, memo.rows == rows { return memo.holds }
        let marker = "/fe-" + request.target
        let known = listRowTargets[list]?[request.target]
        let holds = (listRowPaths[list] ?? []).contains { $0.hasSuffix(marker) || $0 == known }
        scrollTargetMemo[list] = (request.tick, rows, holds)
        return holds
    }

    private func distance(_ index: Int, to range: ClosedRange<Int>) -> Int {
        index < range.lowerBound ? range.lowerBound - index : index - range.upperBound
    }

    /// The host shows rows `first,last` of the list: rebuild when that
    /// comes near the edge of what was built.
    func listWindowReported(list: String, value: String) {
        let parts = value.split(separator: ",")
        guard parts.count >= 2, let first = Int(parts[0]), let last = Int(parts[1]), first <= last else { return }
        // A host that says which build it saw ("first,last,rows"): a report
        // about rows since replaced (a thread's loading rows, reported after
        // its transcript arrived) would place the new rows where the old
        // ones were.
        if parts.count >= 3, let rows = Int(parts[2]), rows != listRowCounts[list] { return }
        listVisibleRows[list] = first...last
        if let paths = listRowPaths[list], first < paths.count { listVisibleAnchor[list] = paths[first] }
        // Rows come on screen and leave it as the reader scrolls: their
        // onAppear/onDisappear now, without a render.
        reconcileAppearances()
        let margin = Runtime.listRebuildMargin
        // The margin stops at the list's ends: at the bottom of a chat there
        // is nothing further to build.
        let lastRow = (listRowCounts[list] ?? Int.max) - 1
        let covered = (listBuiltRows[list] ?? []).contains {
            $0.lowerBound <= max(0, first - margin) && min(lastRow, last + margin) <= $0.upperBound
        }
        if !covered {
            // The list builds the rows now near what is shown (the views
            // around it are not reused across that).
            stateDidChange(key: list + "#window")
            requestFrame()
        }
    }
}

/// An `AsyncImage` reads its image's load status only while loading: once
/// the image is ready (which it stays), or when the host draws it itself
/// (the plain form, a vector or animated format), its node depends on its
/// inputs alone, and rows holding it can be reused.
extension AsyncImage: _ReusableBuild {
    func _buildsPurely(_ ctx: BuildContext) -> Bool {
        guard let url, makeContent != nil, makePlaceholder != nil else { return true }
        let source = url.absoluteString
        if isNativeImageFormat(source) { return true }
        if case .ready = Runtime.shared.host?.imageInfo(source, isRemote: true) ?? .loading { return true }
        return false
    }
}

/// When `path` runs on past `prefix` (byte for byte), the byte after it;
/// nil otherwise. Compares the UTF-8 buffers directly: build paths are long
/// and share long prefixes.
func _byteAfterPrefix(_ path: String, _ prefix: String) -> UInt8? {
    var path = path
    var prefix = prefix
    return path.withUTF8 { p -> UInt8? in
        prefix.withUTF8 { q -> UInt8? in
            guard p.count > q.count else { return nil }
            var i = 0
            while i < q.count {
                if p[i] != q[i] { return nil }
                i += 1
            }
            return p[q.count]
        }
    }
}

/// The last `count` components of a build path ("a/b/c", 2: "b/c"), found
/// in its UTF-8 bytes: split by Characters, a long path took a wasm
/// interpreter over a millisecond (the frame log's names of paths).
func _pathTail(_ path: String, _ count: Int) -> String {
    var path = path
    return path.withUTF8 { bytes -> String in
        var seen = 0
        var i = bytes.count
        while i > 0 {
            i -= 1
            guard bytes[i] == UInt8(ascii: "/") else { continue }
            seen += 1
            if seen == count { return String(decoding: UnsafeBufferPointer(rebasing: bytes[(i + 1)...]), as: UTF8.self) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

extension RenderNode {
    /// A List whose scroll is anchored at its bottom (`defaultScrollAnchor`):
    /// remembered by the list's path, for how its rows are first built.
    @MainActor
    func noteListAnchor() {
        guard isList, let path = identityPath, let anchor = scrollAnchor else { return }
        if anchor.y == 1 { Runtime.shared.listsAnchoredAtBottom.insert(path) }
    }
}
