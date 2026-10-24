// The runtime drives the render loop: build node tree -> layout -> emit a
// draw list through the platform's `HostBridge`.

/// Implemented once per platform (wasm imports, JNI calls, ...). All
/// coordinates are in logical points; the host applies display scaling.
import Foundation
package import IsomerSwiftUI

// The host's interface is IsomerSwiftUI's (`HostBridge`, `HostColor`,
// `ImageStatus`): a host's, not Apple's. The runtime draws with SwiftUI's
// colours and hands them to the host resolved for the scheme in effect.
extension HostBridge {
    func fillRect(_ rect: CGRect, cornerRadius: Double, color: Color) {
        fillRect(rect, cornerRadius: cornerRadius, color: color.hostColor)
    }

    func strokeRect(_ rect: CGRect, cornerRadius: Double, lineWidth: Double, color: Color) {
        strokeRect(rect, cornerRadius: cornerRadius, lineWidth: lineWidth, color: color.hostColor)
    }

    func drawShadow(_ rect: CGRect, cornerRadius: Double, color: Color, radius: Double, x: Double, y: Double) {
        drawShadow(rect, cornerRadius: cornerRadius, color: color.hostColor, radius: radius, x: x, y: y)
    }

    func drawText(_ text: String, in rect: CGRect, fontSize: Double, weight: Int, color: Color) {
        drawText(text, in: rect, fontSize: fontSize, weight: weight, color: color.hostColor)
    }
}

extension Color {
    /// The colour as a host draws it, in the scheme in effect.
    var hostColor: HostColor {
        HostColor(red: red, green: green, blue: blue, opacity: alpha, name: systemName)
    }
}

/// A scrollable area registered during the draw pass (topmost last).
struct ScrollRegion {
    let rect: CGRect
    let path: String
    let axis: StackAxis
    let contentLength: CGFloat
    let viewportLength: CGFloat
    /// The scroll's `onScrollPhaseChange` handlers.
    var phaseHandlers: [(key: String, handler: @MainActor (ScrollPhase, ScrollGeometry?, CGVector?) -> Void)] = []
}

struct SliderRegion {
    let rect: CGRect
    let path: String
    let set: (Double) -> Void
}

struct DragRegion {
    let rect: CGRect
    let gesture: DragGesture
}

struct TapRegion {
    let rect: CGRect
    let action: () -> Void
    let feedback: PressFeedback
    /// Stable id so the host can reuse one feedback element across frames.
    let id: String
}

struct TextFieldRegion {
    let rect: CGRect
    let path: String
    let get: () -> String
    let set: (String) -> Void
    let fontSize: Double
}

/// Mutable per-frame output of the draw pass.
final class RenderPass {
    let host: HostBridge
    var tapRegions: [TapRegion] = []
    var scrollRegions: [ScrollRegion] = []
    var sliderRegions: [SliderRegion] = []
    var dragRegions: [DragRegion] = []
    var textFieldRegions: [TextFieldRegion] = []
    var hostViews: [(spec: HostViewSpec, frame: CGRect)] = []
    /// Ids of host views the renderer drew inline (`drawHostView` returned
    /// true, e.g. SwiftMap tile scenes): kept in `hostViews` for regions and
    /// handlers, but excluded from the native host-view sync — a host that
    /// materializes unknown kinds would otherwise overlay (and swallow
    /// pointer events over) the drawn content.
    var hostDrawnViewIDs: Set<String> = []
    var lifecycle: [String: (appear: (() -> Void)?, disappear: (() -> Void)?)] = [:]
    /// Set when something on screen needs continuous re-rendering (a running
    /// animation, an indeterminate spinner).
    var wantsContinuousRender = false

    /// Effective clip rects (already intersected) for the current draw position,
    /// so tap regions can be clipped to their scroll container (correct
    /// hit-testing + press feedback that doesn't bleed past the viewport).
    var clipStack: [CGRect] = []
    var currentClip: CGRect? { clipStack.last }
    func pushClipRect(_ rect: CGRect) {
        clipStack.append(currentClip?.clipped(to: rect) ?? rect)
    }
    func popClipRect() {
        if !clipStack.isEmpty { clipStack.removeLast() }
    }

    init(host: HostBridge) {
        self.host = host
    }
}

package final class Runtime {
    public static let shared: Runtime = {
        let runtime = Runtime()
        // What a host outside Isomer's SwiftUI drives it through.
        MainActor.assumeIsolated { IsomerRuntime.connection = runtime }
        return runtime
    }()

    public var host: HostBridge?
    var makeRootView: (() -> any View)?
    let storage = StateStorage()
    var width: Double = 0
    var height: Double = 0
    var tapRegions: [TapRegion] = []
    var scrollRegions: [ScrollRegion] = []
    var sliderRegions: [SliderRegion] = []
    var dragRegions: [DragRegion] = []
    var textFieldRegions: [TextFieldRegion] = []
    var scrollOffsets: [String: CGFloat] = [:]
    /// Host-measured GeometryReader container sizes, keyed by the reader's
    /// ".geo" tree id (component-system renderers report them as events;
    /// see TreeEncoder). Sizes persist across frames; stale ids are inert.
    var geometrySizes: [String: CGSize] = [:]
    /// Where each reader is in the window, as its host reports it (with its
    /// size: "<w>x<h>@<x>,<y>"), for `frame(in: .global)`.
    var geometryOrigins: [String: CGPoint] = [:]

    /// A geometry reader's report, kept by its id: "<w>x<h>", and where its
    /// host knows it the reader's place in the window, "<w>x<h>@<x>,<y>".
    func recordGeometry(id: String, value: String) {
        let halves = value.split(separator: "@", maxSplits: 1)
        let parts = halves[0].split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return }
        geometrySizes[id] = CGSize(width: w, height: h)
        if halves.count == 2 {
            let place = halves[1].split(separator: ",")
            if place.count == 2, let x = Double(place[0]), let y = Double(place[1]) {
                geometryOrigins[id] = CGPoint(x: x, y: y)
            }
        }
    }
    /// `.tabViewStyle` values in effect during the build (innermost last);
    /// TabView.makeNode reads the top (TabContent.swift).
    var tabViewStyleStack: [String] = [] { didSet { reuseContextCache = nil } }
    /// `.pickerStyle` names in effect during the build (innermost last).
    var pickerStyleStack: [String] = [] { didSet { reuseContextCache = nil } }
    /// `.buttonStyle` / `.controlSize` / `.buttonBorderShape` scopes.
    var buttonStyleStack: [ButtonStyleOption] = [] { didSet { reuseContextCache = nil } }
    var controlSizeStack: [ControlSize] = [] { didSet { reuseContextCache = nil } }
    var buttonBorderShapeStack: [ButtonBorderShape] = [] { didSet { reuseContextCache = nil } }
    /// `.multilineTextAlignment` / `.labelStyle` scopes.
    var textAlignmentStack: [TextAlignment] = [] { didSet { reuseContextCache = nil } }
    var labelStyleStack: [LabelStyleOption] = [] { didSet { reuseContextCache = nil } }
    /// `.tabViewCustomization` bindings in effect during the build.
    var tabCustomizationStack: [Binding<TabViewCustomization>?] = [] { didSet { reuseContextCache = nil } }
    /// Where `@AppStorage` keeps what names no store of its own: the
    /// standard suite, as Apple's (a test gives it a suite of its own).
    package var appStorageDefaults: UserDefaults = .standard
    /// `.navigationSplitViewColumnWidth` hint set while a split-view column
    /// builds; the split view resets it per column and reads it after.
    var columnWidthHint: Double?
    /// Its min and max, when it gave them.
    var columnWidthBounds: (min: Double?, max: Double?)?
    /// Which NavigationSplitView column is building ("sidebar" / "content"),
    /// so a `List(selection:)` inside can report its current selection…
    var splitColumnBuilding: String?
    /// …here (the value, nil = no selection; compared, not described: a
    /// description of an app's own type is made by reflection, and each
    /// frame of a sidebar made one).
    var splitSelectionSnapshot: AnyHashable?
    /// Clears the selection of the List a split column being built holds
    /// (what returning past that column does in a compact split).
    var splitSelectionClearer: (() -> Void)?
    /// Per split view + column: the last selection seen, and a tick that
    /// advances when a column's selection CHANGES to a value — compact hosts
    /// move to the next pane on it (a row tap or a programmatic selection,
    /// the way SwiftUI's split view shows the detail on a phone).
    var splitSelections: [String: AnyHashable?] = [:]
    /// A tap on a List row that was already selected (see `List(selection:)`):
    /// the next split build advances even though the selection is unchanged.
    var splitReselectRequested = false
    var splitAdvanceTicks: [String: Int] = [:]
    var splitAdvanceTargets: [String: String] = [:]
    /// Self-drawing hosts at compact width: which column each split view
    /// shows ("sidebar" / "content" / "detail"); advances on selection, and
    /// the shown column's bar gets a Back to the previous one.
    var drawnSplitColumn: [String: String] = [:]
    /// Set while a compact split view builds a column that has a previous
    /// column to go back to: the column's root NavigationStack shows Back.
    var compactSplitBack: (() -> Void)?
    /// `.toolbar(removing: .sidebarToggle)` was applied while a split view's
    /// sidebar column built (consumed by the enclosing split view).
    var sidebarToggleRemoved = false
    /// `.inspectorColumnWidth` seen while an inspector pane's content built.
    var inspectorWidthHint: Double?
    /// Internal TabView selection (used when no `selection:` binding is given).
    var tabSelection: [String: Int] = [:]
    /// Internal DisclosureGroup expansion (when no `isExpanded:` binding given).
    var disclosureExpanded: [String: Bool] = [:]
    /// Effective color scheme for this frame (read by `Color` resolution). Set
    /// each frame from the system preference, overridden by `.preferredColorScheme`.
    public var colorScheme: ColorScheme = .light
    /// Device pixels per point, set by the host (`@Environment(\.displayScale)`).
    public var displayScale: CGFloat = 1
    /// Pictures whose bytes went to the host at their first draw (a host
    /// that does not decode off the main thread; see `Image(_:scale:label:)`).
    var handedImages: Set<String> = []
    /// Pictures' bytes for a host with no image channel of its own (a
    /// reactor's, HotBridge): they ride the tree once, on the first image
    /// node that shows them (param "imageData"), and the host keeps them
    /// by source.
    public var inlineImages: [String: [UInt8]] = [:]
    /// `.preferredColorScheme` seen during this build (nil = follow the
    /// system); navigation levels pass it to hosts so native chrome (title,
    /// status bar) matches the app's own colors.
    public var preferredColorScheme: ColorScheme?
    /// Scene phase reported by the host (`setScenePhase`), exposed to the app
    /// as `@Environment(\.scenePhase)`.
    var scenePhase: ScenePhase = .active
    /// `.onOpenURL` handlers registered during the current build.
    var openURLHandlers: [(URL) -> Void] = []
    /// External URLs delivered before handlers were registered (`openURL(external:)`).
    var pendingExternalURLs: [String] = []
    /// The `WindowGroup` title, reported to the host once via `platformCommand`.
    var windowTitle = ""
    /// Last value sent per platform-command key (modifiers re-send each build;
    /// the host only hears changes).
    package var sentPlatformCommands: [String: String] = [:]
    /// Each text field's selection on both sides of the host, by the field's
    /// place in the tree (TextSelection.swift's FieldSelectionState).
    package var fieldSelections: [String: FieldSelectionState] = [:]

    /// Sends a platform command to the host once per distinct value
    /// (`.platformCommand` in SwiftUIExtensions, the window title, …).
    package func sendPlatformCommand(_ key: String, _ value: String) {
        guard sentPlatformCommands[key] != value else { return }
        sentPlatformCommands[key] = value
        host?.platformCommand(key, value)
    }
    /// System (host) color-scheme preference.
    var systemColorScheme: ColorScheme = .light

    /// The host reports the system appearance here (each platform bridge maps
    /// its native signal — `prefers-color-scheme` on the web, trait/appearance
    /// changes on native hosts, `uiMode` on Android — to this one entry
    /// point). Re-renders on change; `.preferredColorScheme` still overrides
    /// per frame.
    public func setSystemColorScheme(dark: Bool) {
        let scheme: ColorScheme = dark ? .dark : .light
        guard systemColorScheme != scheme else { return }
        systemColorScheme = scheme
        setNeedsRender()
    }

    /// The size classes the host's system reports (`setHostSizeClasses`):
    /// an iPhone held sideways is compact wide however wide it is (874
    /// points on an iPhone 17), as its trait collection says, and a Plus or
    /// Max one regular. Nil where the host says nothing: worked out from the
    /// size then (compact below 700 points wide).
    package var hostHorizontalSizeClass: UserInterfaceSizeClass?
    package var hostVerticalSizeClass: UserInterfaceSizeClass?

    /// Whether the width is compact: the host's horizontal size class, or
    /// the 700-point rule. What split views collapse and inspectors become
    /// sheets by, as `horizontalSizeClass` reads it.
    package var compactWidth: Bool {
        hostHorizontalSizeClass.map { $0 == .compact } ?? (width < 700)
    }

    /// The host reports its system's size classes here (Apple's WasmView
    /// from SwiftUI's own environment). A change builds every view afresh,
    /// as SwiftUI's trait change does: a view reused as it was would keep
    /// the size class it was built with.
    public func setHostSizeClasses(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
        guard horizontal != hostHorizontalSizeClass || vertical != hostVerticalSizeClass else { return }
        hostHorizontalSizeClass = horizontal
        hostVerticalSizeClass = vertical
        resetBuildCache()
        setNeedsRender()
    }
    /// Last scheme reported to the host (to avoid redundant calls).
    var reportedColorScheme: ColorScheme = .light
    /// Implicit-animation interpolation state, keyed by view path + property.
    let animator = Animator()
    /// The transaction animation set by the current `withAnimation` (consumed by
    /// the next build).
    var transactionAnimation: Animation?
    /// Last values observed by `.animation(_:value:)`, keyed by view path.
    var animationValues: [String: any Equatable] = [:]
    /// Previous values observed by `.onChange(of:)`, keyed by view path.
    var onChangeStore: [String: Any] = [:]
    /// Actions queued during the build (e.g. `.onChange`) to run after the
    /// frame, so they may mutate state and trigger a follow-up render.
    var deferredActions: [() -> Void] = []
    /// `.onChange` actions queued by the build in progress: run before its
    /// frame is drawn (`renderFrame`).
    var onChangeActions: [() -> Void] = []
    /// Inside `renderFrame`'s build passes.
    var buildingFrame = false
    /// The tree is being handed to the renderer, which builds a
    /// GeometryReader's content as it encodes it: an `.onChange` queued then
    /// runs after the hand-over, with the frame's other deferred actions.
    var renderingTree = false
    /// `.task(id:)` ids by build path (a change restarts the task).
    var taskIDs: [String: AnyEquatableBox] = [:]
    /// The latest `ScrollViewProxy.scrollTo`: every ScrollView carries it on
    /// the wire (`scrollTo=<id>|<tick>|<anchor>[|a]`); the host that finds
    /// the `.id` inside itself scrolls there, eased when the request was made
    /// inside `withAnimation` ("a"), at once otherwise, as SwiftUI's proxy
    /// does. The tick makes repeats distinct.
    var pendingScroll: (target: String, anchor: String, tick: Int, animated: Bool)?

    // MARK: Shutdown

    /// Tasks the framework started for views (`.task {}` / `.task(id:)`),
    /// keyed so a finished one drops out. Cancelled together on `shutdown()`.
    private var liveTasks: [Int: Task<Void, Never>] = [:]
    private var nextTaskID = 0
    /// Set by `shutdown()`: renders stop, timers are dropped, and new view
    /// tasks are born cancelled.
    public private(set) var isShuttingDown = false

    /// Starts a view task the runtime can cancel on shutdown.
    @discardableResult
    func spawnTask(priority: TaskPriority, _ action: @escaping @Sendable () async -> Void) -> Int {
        nextTaskID += 1
        let id = nextTaskID
        // On the main actor, where the runtime's tables are kept: the action
        // runs as the actor it was written in, and its entry is dropped here
        // after it. (Nonisolated, the closure ran on the global executor, a
        // pool of guest threads in a threaded reactor, and dropped the entry
        // there while the main thread wrote the table: the table's tasks
        // were released twice, and a guest thread trapped destroying one.)
        let task = Task(priority: priority) { @MainActor [weak self] in
            await action()
            self?.liveTasks[id] = nil
        }
        if isShuttingDown { task.cancel() }
        liveTasks[id] = task
        return id
    }

    /// The task each view's `.task` started, by the view's build path.
    private var viewTasks: [String: Int] = [:]

    /// Starts a view's task, cancelling the one it had (its id changed).
    func startViewTask(key: String, priority: TaskPriority, _ action: @escaping @Sendable () async -> Void) {
        if let running = viewTasks[key] { liveTasks[running]?.cancel() }
        viewTasks[key] = spawnTask(priority: priority, action)
    }

    /// Cancels a view's task: the view disappeared. The task stays counted
    /// until it returns (cancellation is cooperative).
    func endViewTask(key: String) {
        if let running = viewTasks.removeValue(forKey: key) { liveTasks[running]?.cancel() }
    }

    /// View tasks still running (suspended at an await, or not yet drained).
    public var pendingTaskCount: Int { liveTasks.count }

    /// Graceful shutdown, driven by the host: cancels every view task so
    /// each unwinds at its next suspension point, and stops rendering. The host keeps draining the job queue until
    /// `pendingTaskCount` is zero (or its deadline passes and it tears the
    /// instance down regardless). A task blocked on a service that never
    /// answers stays pending — that is what the host's deadline is for.
    public func shutdown() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        for task in liveTasks.values { task.cancel() }
    }
    var needsRender = false
    /// Whether a frame now has anything to do: state has changed, or an
    /// animation or a transition is in motion. A host that
    /// renders after every event or every run of async work asks this first
    /// (a scroll's reports and a timer's wake changed nothing to build).
    public var wantsFrame: Bool {
        needsRender || animator.isAnimating || navTransitionActive
    }
    var measureCache: [String: CGSize] = [:]

    // Pointer-gesture state (tap vs drag-scroll vs slider disambiguation).
    var pointerIsDown = false
    var pointerStart = CGPoint.zero
    var pointerLast = CGPoint.zero
    var isDragScrolling = false
    var dragScrollPath: String?
    var dragScrollAxis: StackAxis = .vertical
    /// Host-drawn map nodes (kind "map" with an onChange handler): drag pans
    /// and the wheel zooms, routed as "pan:"/"zoom:" commands to the handler.
    var mapRegions: [(id: String, rect: CGRect)] = []
    /// The map node owning the current drag (engaged past the tap slop,
    /// exactly like drag-scrolling, so taps on overlaid controls still fire).
    var mapDragID: String?
    var pressedTap: TapRegion?
    /// Region whose host press-feedback is currently shown (so it can be released).
    var activePressFeedback: TapRegion?
    var activeSlider: SliderRegion?
    var activeDrag: DragRegion?
    var dragStartPoint = CGPoint.zero
    /// A horizontal-swipe drag waiting to see if the gesture is horizontal (then
    /// it engages) or vertical (then it yields to scrolling). See `swipeGesture`.
    var pendingHorizontalDrag: DragRegion?

    // Inertial ("flick") scrolling: a smoothed drag velocity (points/sec) is
    // captured on release and decays over time, so scrolling glides like a
    // native scroll view instead of stopping dead.
    var dragVelocity: CGFloat = 0
    var pointerLastTime: Double = 0
    var scrollVelocity: [String: CGFloat] = [:]
    var flingLastTime: Double = 0
    /// Scrolls the wheel last moved, by path, and when: idle once it has
    /// been still a while.
    var wheelScrolls: [String: Double] = [:]

    /// Edge overscroll distance (logical points) for a native scroller: + pulls
    /// the content down past the top, − pulls it up past the bottom. The host's
    /// EdgeEffect provides the value and its spring-back each frame.
    var overscrollOffsets: [String: CGFloat] = [:]
    /// A `.searchable` registered during the current build (consumed by the
    /// NavigationStack, which renders the search field).
    var pendingSearch: SearchSpec?

    public func nativeOverscroll(path: String, amount: Double) {
        let v = CGFloat(amount)
        if (overscrollOffsets[path] ?? 0) == v { return }
        if v == 0 { overscrollOffsets[path] = nil } else { overscrollOffsets[path] = v }
        setNeedsRender()
    }

    /// Navigation stacks built this frame (innermost/last visible appended
    /// last), so the system back button can pop the right one.
    var navigationStates: [NavigationState] = []
    /// Set during a build while a push/pop transition is animating, so the
    /// render loop keeps stepping it.
    var navTransitionActive = false
    /// Dismiss action for the topmost presentation this frame, if any.
    var topPresentationDismiss: (() -> Void)?

    /// Handle a platform back gesture/button. Dismisses a presented sheet/alert,
    /// else pops the innermost navigation stack. Returns false when there is
    /// nothing to handle (so the host can perform its default back).
    public func handleBackButton() -> Bool {
        if let dismiss = topPresentationDismiss {
            dismiss()
            return true
        }
        for nav in navigationStates.reversed() where !nav.stack.isEmpty {
            nav.pop()
            return true
        }
        return false
    }

    // Text-input focus.
    var focusedFieldPath: String?
    var focusedFieldSet: ((String) -> Void)?

    // Native host-view change handlers, keyed by host-view id.
    var hostViewHandlers: [String: (String) -> Void] = [:]

    // Presentations (sheet/alert/popover) registered during the build pass,
    // drawn screen-wide on top after the root.
    var pendingPresentations: [PendingPresentation] = []

    // Lifecycle bookkeeping: paths on screen last frame -> their
    // onDisappear handlers.
    var aliveLifecycle: [String: (() -> Void)?] = [:]

    @MainActor
    public func installApp<A: App>(_ app: A) {
        let scene = primitiveScene(app.body)
        windowTitle = scene.windowTitle
        makeRootView = { scene.makeRootView() }
    }

    /// Host an arbitrary root view (for incremental adoption: embedding a
    /// isomer view inside an existing host app rather than running a whole
    /// `@main App`). See `IsomerHostingController`.
    public func installRootView(_ make: @escaping () -> any View) {
        makeRootView = make
        resetBuildCache()
        // Embedding a isomer view inside someone else's hierarchy is the
        // `.embedded` integration; a whole-window `@main App` leaves the default
        // `.app`. `start` enforces that the bound renderer supports it.
        Renderer.integrationMode = .embedded
        if host != nil { setNeedsRender() }
    }

    @MainActor
    public func start(host: HostBridge, width: Double, height: Double) {
        // A self-drawing renderer (SwiftGPU) owns the whole surface, so it
        // cannot be embedded in a host's view hierarchy; component-system
        // renderers support either mode. Fail loudly on a misconfiguration.
        precondition(
            Renderer.current.supportedModes.contains(Renderer.integrationMode),
            "\(type(of: Renderer.current)) does not support \(Renderer.integrationMode) integration "
                + "(it supports \(Renderer.current.supportedModes.map(\.description).sorted()))")
        self.host = host
        self.width = width
        self.height = height
        resetBuildCache()
        renderFrame()
    }

    @MainActor
    public func resize(width: Double, height: Double) {
        // The size classes come from the size: a resize across them (a host
        // that starts the app before it knows its size, an iPad window made
        // narrow) changes what views build, as SwiftUI's trait change does.
        let compactBefore = compactWidth, landscapeBefore = self.height < self.width
        self.width = width
        self.height = height
        measureCache = [:]
        if compactBefore != compactWidth || (hostVerticalSizeClass == nil && compactWidth && landscapeBefore != (height < width)) {
            // Every view is built afresh: one reused as it was would keep
            // the size class it was built with (the size classes are read
            // from the width, so no view's inputs look changed).
            resetBuildCache()
            setNeedsRender()
            renderFrame()
            return
        }
        // A resize changes only the layout input, not the semantic tree, so
        // skip the rebuild and re-run the renderer on the retained tree. The
        // self-drawing path relays it out + redraws at the new size (and
        // rebuilds any GeometryReader subtree during that layout); a
        // component-system renderer re-serializes the identical tree (the
        // host relays out natively either way). Rebuild only before the first
        // frame, when nothing is retained yet.
        if let tree = retainedTree {
            renderingTree = true
            Renderer.current.render(tree: tree)
            renderingTree = false
            // What the hand-over queued (a reader's `.onChange` at the new
            // size) runs in the next frame.
            if !deferredActions.isEmpty { requestFrame() }
        } else {
            renderFrame()
        }
    }

    /// Asks for a frame that builds the whole tree: for a change the runtime
    /// cannot see per view (a value of the app's own it shows, changed
    /// outside any state). State writes, observed objects and the host's
    /// events on the tree ask through `requestFrame`, and their frames build
    /// only the views they changed (InPlace.swift).
    public func setNeedsRender() {
        wholeFrameRequested = true
        requestFrame()
    }

    /// Asks for a frame; what changed is marked where it is.
    func requestFrame() {
        if !needsRender, !isShuttingDown {
            needsRender = true
            // Within a frame's build passes the frame schedules what is left.
            if !buildingFrame { host?.scheduleRender() }
        }
    }

    /// One build of the app's tree for this frame.
    @MainActor
    private func buildFrameTree(_ makeRootView: () -> any View) -> RenderNode {
        if !partialSettingsChecked {
            partialSettingsChecked = true
            if host?.hostValue("env:ISO_VERIFY_PARTIAL") != nil { verifyPartialFrames = true }
            if host?.hostValue("env:ISO_PARTIAL") == "0" { partialFramesEnabled = false }
        }
        // A value mid-animation moves each frame: the view it is in builds
        // again (the rest are reused).
        for key in animator.animatingKeys { stateDidChange(key: key) }
        // The scheme the last whole build resolved holds while its views
        // (a `.preferredColorScheme` among them) are not built again.
        var rootEnv = EnvironmentValues()
        rootEnv.colorScheme = systemColorScheme == lastSystemColorScheme ? colorScheme : systemColorScheme
        rootEnv.scenePhase = scenePhase
        frameLogBegin()
        // Only the views whose state changed, where they stand (InPlace.swift).
        if let tree = retainedTree, let sites = planPartialFrame(rootEnv: rootEnv) {
            let written = dirtyStateKeys
            let volatility = buildVolatility
            let lists = verifyPartialFrames ? listWindowState : nil
            beginReuseFrame()
            if buildInPlace(sites, in: tree) {
                treeVolatile = buildVolatility != volatility
                endReuseFrame(partial: true)
                partialFrameCount &+= 1
                frameLogEnd()
                if verifyPartialFrames {
                    // The same changes built whole, to compare with: what the
                    // frame shows is that build's.
                    let partial = _describeTree(tree)
                    dirtyStateKeys.formUnion(written)
                    // From the lists' windows as the frame found them (a page
                    // of new rows is built a few a frame).
                    if let lists { listWindowState = lists }
                    frameLogBegin()
                    let whole = buildWholeFrameTree(makeRootView)
                    let expected = _describeTree(whole)
                    if partial != expected { notePartialMismatch(whole: expected, partial: partial, sites: sites) }
                    return whole
                }
                transactionAnimation = nil
                return tree
            }
            frameLog?.inPlace = []
            // Built whole after all, with the same changes.
            dirtyStateKeys.formUnion(buildDirtyKeys)
            buildDirtyKeys = []
        }
        return buildWholeFrameTree(makeRootView)
    }

    /// The whole tree, from the root down (views unchanged reused).
    @MainActor
    private func buildWholeFrameTree(_ makeRootView: () -> any View) -> RenderNode {
        wholeFrameRequested = false
        // Per-build registrations reset so they don't accumulate.
        pendingPresentations = []
        openURLHandlers = []
        navigationStates = []
        pendingSearch = nil
        navTransitionActive = false
        // Base scheme for the frame; `.preferredColorScheme` may override
        // during the build below.
        colorScheme = systemColorScheme
        preferredColorScheme = nil
        lastSystemColorScheme = systemColorScheme
        var rootEnv = EnvironmentValues()
        rootEnv.animation = transactionAnimation
        rootEnv.colorScheme = colorScheme
        rootEnv.scenePhase = scenePhase
        lastRootEnv = rootEnv
        lastCompactWidth = compactWidth
        var ctx = BuildContext(path: "root", env: rootEnv, storage: storage)
        let volatility = buildVolatility
        beginReuseFrame()
        defer { endReuseFrame() }
        let root = buildNode(view: makeRootView(), ctx: &ctx)
        treeVolatile = buildVolatility != volatility
        // The tree a later pass of this frame builds in place into.
        retainedTree = root
        frameLogEnd()
        // The transaction only applies to the build it triggered.
        transactionAnimation = nil
        return root
    }

    func layoutContext() -> LayoutContext {
        LayoutContext(
            measureText: { [weak self] text, font, wrapWidth in
                self?.cachedMeasure(text: text, font: font, wrapWidth: wrapWidth) ?? .zero
            },
            imageInfo: { [weak self] source, isRemote in
                self?.host?.imageInfo(source, isRemote: isRemote) ?? .loading
            }
        )
    }

    /// Monotonic time of the current frame (seconds); read by animations.
    var animationTime: Double = 0

    /// Event handlers registered by the tree serializer for the bound
    /// component-system renderer, keyed by node id (see Renderer.swift).
    var treeHandlers: [String: (String) -> Void] = [:]
    /// Set by a field's key handler when an `.onKeyPress` action took the
    /// key (read back by `keyPressEvent`).
    var keyPressHandled = false

    /// Node ids whose onAppear already fired under a component-system renderer.
    var treeAppearedIDs: Set<String> = []

    /// The last semantic tree `renderFrame` built. The build (running the
    /// app's `body` closures) is size-independent — no view reads the
    /// container size at build time, and `GeometryReader` builds its content
    /// at *layout* time (see Layout.swift). So a pure resize can reuse this
    /// tree and re-run only the renderer (for the self-drawing path: layout +
    /// draw, which re-invokes any GeometryReader build at the new size)
    /// instead of rebuilding the whole hierarchy. Refreshed every frame.
    var retainedTree: RenderNode?

    // Subtree reuse (Reuse.swift).
    /// Bumped by every build that reads or registers runtime state; a view
    /// whose build saw it move is not reused.
    var buildVolatility = 0
    /// State written since the last build ("<view path>#<property>").
    var dirtyStateKeys: Set<String> = []
    /// The state written before the build in progress started.
    var buildDirtyKeys: Set<String> = []
    /// Reusable subtrees by view path.
    var buildCache: [String: _BuildCacheEntry] = [:]
    var buildCacheTouched: Set<String> = []
    var buildCacheInnerStack: [[String]] = []
    /// The per-frame registrations made while each composite in progress
    /// builds (Reuse.swift, `registerFrameEffect`).
    var buildEffectStack: [[_FrameEffect]] = []
    /// The split views built (on hosts with native navigation), by path:
    /// a re-tap of a sidebar's selected row marks them changed.
    var splitViewPaths: Set<String> = []
    /// `listHoldsScrollTarget`'s answers, by list.
    var scrollTargetMemo: [String: (tick: Int, rows: Int?, holds: Bool)] = [:]
    /// Off: every view rebuilds every frame (for comparison and bisecting).
    public var subtreeReuseEnabled = true
    // Building views again alone (InPlace.swift).
    /// The composite views' last builds, by path.
    var rebuildSites: [String: _RebuildSite] = [:]
    /// The views observing each `ObservableObject` (Observable.swift).
    /// Which views' builds read each `@State` (InPlace.swift): its keys, the
    /// state each composite's last build read, the reads of the builds in
    /// progress, and the states read where no view's build was running.
    var stateKeys: Set<String> = []
    var stateReaders: [String: Set<String>] = [:]
    var compositeStateReads: [String: Set<String>] = [:]
    var stateReadStack: [[String]] = []
    var keysReadOutsideBuild: Set<String> = []
    var geometryBuildDepth = 0
    /// Off: a frame always builds the tree from its root.
    public var partialFramesEnabled = true
    /// Each partial frame followed by a whole build compared with it.
    public var verifyPartialFrames = false
    /// Partial frames built, and those found to differ from a whole build.
    public internal(set) var partialFrameCount = 0
    public internal(set) var partialMismatches = 0
    /// A build in the current tree read runtime state: it is built whole.
    var treeVolatile = true
    /// `setNeedsRender` asked for the next frame to be built whole.
    var wholeFrameRequested = true
    /// The root environment and system scheme of the last whole build.
    var lastRootEnv: EnvironmentValues?
    var lastSystemColorScheme: ColorScheme?
    var lastCompactWidth = false
    var partialSettingsChecked = false
    /// How many sites were kept after the last pruning of those gone.
    var rebuildSitesKept = 0
    /// Lazy List rows (Reuse.swift): what each list's host last showed, the
    /// rows built for it, and the app views found to be several rows.
    var listVisibleRows: [String: ClosedRange<Int>] = [:]
    var listBuiltRows: [String: [ClosedRange<Int>]] = [:]
    /// The rows (build paths) each list built last frame.
    var listBuiltPaths: [String: Set<String>] = [:]
    /// Each lazy List row's place (its build path -> the list and its index),
    /// for which rows are on screen.
    var listRowIndex: [String: (list: String, index: Int)] = [:]
    /// Each `onScrollGeometryChange`'s last transformed value, by its path.
    var scrollGeometryValues: [String: Any] = [:]
    /// Each `onScrollPhaseChange`'s last phase, and the last geometry its
    /// scroll reported (for a host that sends the phase alone), by its path.
    var scrollPhases: [String: ScrollPhase] = [:]
    var scrollPhaseGeometries: [String: ScrollGeometry] = [:]
    /// Lists anchored at their bottom (a chat), by path: built from their end.
    var listsAnchoredAtBottom: Set<String> = []
    var listRowCounts: [String: Int] = [:]
    /// Each list's rows as last built (their build paths), the row at the
    /// top of what its host last showed, and how many times its rows were
    /// replaced wholesale (another conversation in the same pane): the
    /// window follows that row, and starts afresh when it is gone.
    var listRowPaths: [String: [String]] = [:]
    var listVisibleAnchor: [String: String] = [:]
    public internal(set) var listEpochs: [String: Int] = [:]
    var multiRowViewPaths: Set<String> = []
    var listCells: [String: _ListCell] = [:]
    /// Per list, the row that last held each `.id` (for scroll requests).
    var listRowTargets: [String: [String: String]] = [:]
    /// The scroll request lists last built toward, and for how many frames.
    var scrollRequestSeen: (tick: Int, frames: Int) = (-1, 0)
    var listCellsTouched: Set<String> = []
    /// The context stacks' tops as last described (nil once one changes).
    var reuseContextCache: String?
    /// Subtrees handed back unbuilt so far (a counter for tests and probes).
    public internal(set) var reusedSubtrees = 0
    /// The frame log (FrameLog.swift), when the host asked for one.
    var frameLog: _FrameLog?
    var frameLogChecked = false

    @MainActor
    public func renderFrame() {
        guard !isShuttingDown else { return }
        needsRender = false
        guard let host, let makeRootView else { return }
        animationTime = host.now()

        // One uniform frame for every renderer: build the canonical tree,
        // hand it to the bound renderer, run the frame postlude. The core
        // neither knows nor asks what kind of renderer is bound.
        //
        stepFling(now: animationTime)

        // The `.onChange` actions a build queues run before its frame is
        // drawn, and the state they set is built into the same frame, as
        // SwiftUI does: a frame of the old state in between was seen (a
        // thread flashing empty as its rows came in). A few passes at most;
        // what is still queued then runs after the frame, as other deferred
        // work does.
        buildingFrame = true
        var root = buildFrameTree(makeRootView)
        var passes = 1
        while !onChangeActions.isEmpty && passes < 4 {
            let wanted = needsRender
            needsRender = false
            let actions = onChangeActions
            onChangeActions = []
            for action in actions { action() }
            let changed = needsRender
            needsRender = wanted
            guard changed else { break }
            root = buildFrameTree(makeRootView)
            passes += 1
        }
        buildingFrame = false
        deferredActions.insert(contentsOf: onChangeActions, at: 0)
        onChangeActions = []
        if needsRender { host.scheduleRender() }
        // Retain the freshly built tree so a subsequent resize can re-layout
        // it without re-running these `body` closures.
        retainedTree = root
        // Tell the host about the resolved scheme (set during the build by
        // `.preferredColorScheme`) when it changes.
        if colorScheme != reportedColorScheme {
            reportedColorScheme = colorScheme
            host.setColorScheme(dark: colorScheme == .dark)
        }

        renderingTree = true
        Renderer.current.render(tree: root)
        renderingTree = false

        syncWindowTitle()
        dispatchExternalURLs()
        // Run actions queued during the build (`.onChange`, delivered URLs);
        // they may mutate state, so render again to reflect it.
        if !deferredActions.isEmpty {
            let actions = deferredActions
            deferredActions = []
            for action in actions { action() }
            requestFrame()
        }
        // Keep frames coming while a transition or implicit animation is in
        // motion — every host pumps `scheduleRender` back into `renderFrame`.
        if animator.isAnimating || navTransitionActive {
            host.scheduleRender()
        }
    }

    /// Lay the tree out and draw it through the platform `HostBridge`'s
    /// draw-command surface — the self-drawing renderer's path
    /// (SwiftGPURenderer). Also reconciles native host views, hit-test
    /// regions, lifecycle, and continued-animation scheduling.
    @MainActor
    public func drawTree(root: RenderNode) {
        guard let host else { return }
        // No app build runs in this mode, so resolve the scheme here: the
        // drawn chrome and window background must match the scheme the
        // feature resolved its colors in (`setSystemColorScheme`).
        colorScheme = systemColorScheme
        // Replace semantic chrome host views (nav/tab bars, toggles, pickers,
        // search, media, images) with their drawn implementations before
        // layout — the display list draws all chrome itself.
        expandDrawnChrome(root)
        let layoutCtx = layoutContext()
        let proposal = ProposedSize(width: width, height: height)
        let size = measure(root, proposal: proposal, ctx: layoutCtx)
        let screen = CGRect(x: 0, y: 0, width: width, height: height)
        let frame = alignedRect(size: size, container: screen, alignment: .center)
        place(root, in: frame, ctx: layoutCtx)

        let pass = RenderPass(host: host)
        host.beginFrame(width: width, height: height)
        // Scheme-aware window background behind everything.
        host.fillRect(
            CGRect(x: 0, y: 0, width: width, height: height),
            cornerRadius: 0,
            color: Color.windowBackground
        )
        draw(root, pass: pass)

        // The background's native overlays (recycler lists, native scrollers,
        // navigation/tab bars) float above the GL surface, so a presentation's
        // GL-drawn scrim + panel can't cover them. Record the boundary between
        // background and presentation native views so the background ones are
        // dropped from the native sync while a sheet/alert is up (only the
        // presentation's own native views stay, above the scrim).
        let bgHostViews = pass.hostViews.count

        // Presentations on top: each fills the screen (scrim + panel),
        // animating in with an eased present progress.
        var livePresentations = Set<String>()
        // Index-based: drawn chrome inside a layer (a picker's pop-up list in
        // a sheet) appends its own presentation while this runs, and it must
        // be drawn in the same frame, above the layer that opened it.
        var index = 0
        while index < pendingPresentations.count {
            let presentation = pendingPresentations[index]
            index += 1
            livePresentations.insert(presentation.id)
            let progress = presentationProgress(id: presentation.id)
            if progress < 1 { pass.wantsContinuousRender = true }
            let overlay = buildPresentationNode(
                presentation, screen: CGSize(width: width, height: height), progress: progress
            )
            expandDrawnChrome(overlay)
            _ = measure(overlay, proposal: ProposedSize(width: width, height: height), ctx: layoutCtx)
            place(overlay, in: screen, ctx: layoutCtx)
            draw(overlay, pass: pass)
        }
        topPresentationDismiss = pendingPresentations.last?.dismiss
        presentationStart = presentationStart.filter { livePresentations.contains($0.key) }
        let hasPresentation = !pendingPresentations.isEmpty

        // Drawn press feedback (self-drawing renderers) sits above all content.
        drawPressFeedback(pass)

        // Reconcile native host views (Picker, DatePicker, representables).
        // Behind a presentation, the background's host views are occluded.
        // Views the renderer drew inline (SwiftMap scenes) keep their
        // handlers but stay out of the sync — a materialized native overlay
        // would sit over (and swallow pointer events over) the drawn content.
        hostViewHandlers = [:]
        var hostViewJSON: [String] = []
        for (index, (spec, frame)) in pass.hostViews.enumerated() {
            if hasPresentation && index < bgHostViews { continue }
            if let onChange = spec.onChange {
                hostViewHandlers[spec.id] = onChange
            }
            if pass.hostDrawnViewIDs.contains(spec.id) { continue }
            hostViewJSON.append(hostViewEntryJSON(spec, frame: frame))
        }
        host.syncHostViews("[" + hostViewJSON.joined(separator: ",") + "]")

        // Structured native host-view reconcile for hosts (Windows) that back
        // WebView/Picker/Menu/DatePicker with real native child windows. No-op on
        // hosts that handle these via the JSON above.
        host.beginHostViewSync()
        for (index, (spec, frame)) in pass.hostViews.enumerated() {
            if hasPresentation && index < bgHostViews { continue }
            switch spec.kind {
            case "webview":
                host.syncWebView(id: spec.id, url: spec.value, frame: frame)
            case "picker", "menu", "datepicker":
                host.syncNativeControl(
                    id: spec.id, kind: spec.kind, value: spec.value,
                    options: spec.options, frame: frame)
            default:
                // App-defined native controls (WindowsViewRepresentable "win:…",
                // LinuxViewRepresentable "linux:…").
                if spec.kind.hasPrefix("win:") || spec.kind.hasPrefix("linux:") {
                    host.syncNativeControl(
                        id: spec.id, kind: spec.kind, value: spec.value,
                        options: spec.options, frame: frame)
                }
            }
        }
        host.endHostViewSync()

        host.endFrame()
        tapRegions = pass.tapRegions
        scrollRegions = pass.scrollRegions
        sliderRegions = pass.sliderRegions
        dragRegions = pass.dragRegions
        textFieldRegions = pass.textFieldRegions
        // Host-drawn map nodes take drag-pan and wheel-zoom (see
        // pointerEvent/wheelEvent); commands reach the view's camera binding
        // through its onChange handler.
        mapRegions = pass.hostViews.compactMap { spec, frame in
            spec.kind == "map" && spec.onChange != nil ? (id: spec.id, rect: frame) : nil
        }

        // Focused field disappeared (e.g. navigation) -> end the session.
        if let focused = focusedFieldPath,
           !pass.textFieldRegions.contains(where: { $0.path == focused }) {
            blurTextInput()
        }

        // Lifecycle diffing: fire onAppear for new identities, onDisappear
        // for ones that left the tree.
        var nowAlive: [String: (() -> Void)?] = [:]
        var appeared: [() -> Void] = []
        for (path, handlers) in pass.lifecycle {
            // updateValue, not subscript: assigning .none through the
            // subscript would remove the key entirely.
            nowAlive.updateValue(handlers.disappear, forKey: path)
            if aliveLifecycle.index(forKey: path) == nil, let appear = handlers.appear {
                appeared.append(appear)
            }
        }
        var disappeared: [() -> Void] = []
        for (path, disappear) in aliveLifecycle where nowAlive.index(forKey: path) == nil {
            if let disappear {
                disappeared.append(disappear)
            }
        }
        aliveLifecycle = nowAlive
        for handler in appeared { handler() }
        for handler in disappeared { handler() }

        // Keep animating while a presentation/spinner drawn this pass is in
        // motion (transitions and implicit animations are scheduled by
        // renderFrame's postlude, renderer-independent).
        if pass.wantsContinuousRender {
            host.scheduleRender()
        }
    }


    /// Install the event handlers a tree encoder registered while
    /// serializing (keyed by node id; echoed back through
    /// `hostViewEvent(id:value:)`). Called by component-system renderers
    /// each time they hand a tree to their consumer.
    public func installTreeHandlers(_ handlers: [String: (String) -> Void]) {
        treeHandlers = handlers
    }

    /// Fire lifecycle for nodes newly in the tree (data loads live in
    /// onAppear) and for nodes that have left it (onDisappear; a view's
    /// `.task` is cancelled there); state changes schedule another pass.
    /// `appearances` is the encoder's collected (id, handler) list for the
    /// pass just delivered, `disappearances` the handlers to run when one of
    /// those ids is gone from a later pass.
    public func fireTreeAppearances(_ appearances: [(id: String, appear: () -> Void)],
                                    disappearances: [String: () -> Void] = [:]) {
        treeAppearances = appearances
        treeDisappearanceHandlers = disappearances
        reconcileAppearances()
    }

    /// Appear what is on screen and has not appeared; disappear what has
    /// gone, or scrolled away. A List row is on screen within a screen's
    /// worth of the rows its host shows (as SwiftUI's rows appear as they
    /// come on screen), whatever the List built around it in advance; run
    /// each frame, and as the host reports its rows (no render needed).
    func reconcileAppearances() {
        var seen = Set<String>()
        var appearing: [() -> Void] = []
        for (id, appear) in treeAppearances where appearanceOnScreen(id) {
            seen.insert(id)
            if !treeAppearedIDs.contains(id) {
                treeAppearedIDs.insert(id)
                appearing.append(appear)
            }
        }
        // Gone since the last pass: run what that pass said to run. (The
        // handler kept is the newest one recorded while the node was there.)
        let gone = treeDisappearances.filter { !seen.contains($0.key) }
        treeAppearedIDs = seen
        treeDisappearances = treeDisappearanceHandlers.filter { seen.contains($0.key) }
        for appear in appearing { appear() }
        for (_, disappear) in gone { disappear() }
    }

    /// Whether the node an appearance id names is on screen: not inside a
    /// List row away from what the List's host shows.
    private func appearanceOnScreen(_ id: String) -> Bool {
        guard !listRowIndex.isEmpty else { return true }
        let rowPath: String
        if let known = appearanceRowPaths[id] {
            rowPath = known
        } else {
            rowPath = rowPathOfAppearance(id)
            appearanceRowPaths[id] = rowPath
        }
        guard !rowPath.isEmpty, let row = listRowIndex[rowPath] else { return true }
        guard let visible = listVisibleRows[row.list] else { return true }
        // A screen's worth either side (rows are tall in a chat: at least six).
        let margin = max(visible.count, 6)
        return row.index >= visible.lowerBound - margin && row.index <= visible.upperBound + margin
    }

    /// The List row an appearance id's node is inside (the row's path), or
    /// "" for none: the first of its path's prefixes that is a row.
    private func rowPathOfAppearance(_ id: String) -> String {
        let utf8 = id.utf8
        guard let bar = utf8.firstIndex(of: UInt8(ascii: "|")) else { return "" }
        let start = utf8.index(after: bar)
        var at = start
        while at < utf8.endIndex {
            if utf8[at] == UInt8(ascii: "/") {
                let prefix = String(id[start..<at])
                if listRowIndex[prefix] != nil { return prefix }
            }
            at = utf8.index(after: at)
        }
        let whole = String(id[start...])
        return listRowIndex[whole] != nil ? whole : ""
    }

    /// Each appearance id's List row (`rowPathOfAppearance`), found once
    /// while the lists' rows stay the same: the search allocates and hashes
    /// every prefix of a long path, and ran for every appearance in the
    /// tree on every frame and every row the host reported.
    var appearanceRowPaths: [String: String] = [:]

    /// The last delivered tree's appearances and their onDisappear handlers.
    private var treeAppearances: [(id: String, appear: () -> Void)] = []
    private var treeDisappearanceHandlers: [String: () -> Void] = [:]
    /// The onDisappear handlers of the nodes that have appeared.
    private var treeDisappearances: [String: () -> Void] = [:]

    // MARK: - Animation

    /// Eased present progress (0->1) for a presentation, started on first show.
    var presentationStart: [String: Double] = [:]

    func presentationProgress(id: String, duration: Double = 0.28) -> Double {
        let start = presentationStart[id] ?? animationTime
        presentationStart[id] = start
        let t = min(max((animationTime - start) / duration, 0), 1)
        // easeOut cubic
        let u = 1 - t
        return 1 - u * u * u
    }

    func cachedMeasure(text: String, font: Font, wrapWidth: CGFloat?) -> CGSize {
        let key = "\(text)|\(font.size)|\(font.weight.value)|\(wrapWidth ?? -1)"
        if let cached = measureCache[key] {
            return cached
        }
        guard let host else { return .zero }
        let size = host.measureText(
            text,
            fontSize: font.size,
            weight: font.weight.value,
            wrapWidth: wrapWidth.map { Double($0) }
        )
        measureCache[key] = size
        return size
    }

    // MARK: - Scrolling

    func scrollOffset(for path: String, axis: StackAxis, content: CGSize, viewport: CGSize) -> CGFloat {
        let contentLength = axis == .vertical ? content.height : content.width
        let viewportLength = axis == .vertical ? viewport.height : viewport.width
        let maxOffset = max(0, contentLength - viewportLength)
        let offset = min(max(0, scrollOffsets[path] ?? 0), maxOffset)
        scrollOffsets[path] = offset
        return offset
    }

    /// Advances inertial scrolling by the time elapsed since the last frame,
    /// decaying velocity exponentially and stopping softly at the edges. Uses
    /// the previous frame's `scrollRegions` for bounds.
    func stepFling(now: Double) {
        if !wheelScrolls.isEmpty {
            for (path, at) in wheelScrolls where now - at > 0.15 {
                wheelScrolls[path] = nil
                reportScrollPhase(path, .idle)
            }
            if !wheelScrolls.isEmpty { host?.scheduleRender() }
        }
        guard !scrollVelocity.isEmpty else {
            flingLastTime = now
            return
        }
        let dt = min(0.05, max(0, now - flingLastTime))
        flingLastTime = now
        let tau: CGFloat = 0.35 // velocity time constant (~exponential decay)
        for (path, velocity) in scrollVelocity {
            guard let region = scrollRegions.first(where: { $0.path == path }) else {
                scrollVelocity[path] = nil
                continue
            }
            let maxOffset = max(0, region.contentLength - region.viewportLength)
            var offset = (scrollOffsets[path] ?? 0) + velocity * CGFloat(dt)
            var next = velocity * (1 - min(1, CGFloat(dt) / tau))
            if offset <= 0 {
                offset = 0
                next = 0
            } else if offset >= maxOffset {
                offset = maxOffset
                next = 0
            }
            scrollOffsets[path] = offset
            scrollVelocity[path] = abs(next) < 12 ? nil : next
            if scrollVelocity[path] == nil { reportScrollPhase(path, .idle) }
        }
        if !scrollVelocity.isEmpty {
            host?.scheduleRender()
        }
    }

    func applyScroll(path: String, axis: StackAxis, delta: CGFloat) {
        guard delta != 0 else { return }
        guard let region = scrollRegions.first(where: { $0.path == path }) else { return }
        let maxOffset = max(0, region.contentLength - region.viewportLength)
        let current = scrollOffsets[path] ?? 0
        let updated = min(max(0, current + delta), maxOffset)
        if updated != current {
            scrollOffsets[path] = updated
            setNeedsRender()
        }
    }

    /// `onScrollPhaseChange` on the scroll at `path` (drawn here: the drag,
    /// the fling and the wheel are the runtime's own), with its geometry and
    /// the velocity along its axis, in points a second.
    func reportScrollPhase(_ path: String, _ phase: ScrollPhase, velocity: CGFloat? = nil) {
        guard let region = scrollRegions.first(where: { $0.path == path }), !region.phaseHandlers.isEmpty else { return }
        let offset = scrollOffsets[path] ?? 0
        let vertical = region.axis == .vertical
        let geometry = ScrollGeometry(
            contentOffset: vertical ? CGPoint(x: 0, y: offset) : CGPoint(x: offset, y: 0),
            contentSize: vertical
                ? CGSize(width: region.rect.width, height: region.contentLength)
                : CGSize(width: region.contentLength, height: region.rect.height),
            contentInsets: EdgeInsets(),
            containerSize: region.rect.size)
        let speed = velocity.map { vertical ? CGVector(dx: 0, dy: $0) : CGVector(dx: $0, dy: 0) }
        MainActor.assumeIsolated {
            for entry in region.phaseHandlers { entry.handler(phase, geometry, speed) }
        }
    }

    func scrollRegion(at point: CGPoint, axis preferred: StackAxis?) -> ScrollRegion? {
        // Children register before their ancestors (a scroll node appends
        // itself after drawing its content), so plain order = innermost first.
        for region in scrollRegions where region.rect.contains(point) {
            if let preferred, region.axis != preferred {
                continue
            }
            if region.contentLength > region.viewportLength {
                return region
            }
        }
        return nil
    }

    /// Mouse-wheel / trackpad scrolling. Over a host-drawn map the wheel
    /// zooms about the cursor instead (the camera binding applies the math).
    public func wheelEvent(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        let point = CGPoint(x: x, y: y)
        if let map = mapRegions.reversed().first(where: { $0.rect.contains(point) }),
           let handler = hostViewHandlers[map.id] {
            handler(
                "zoom:\(deltaY),\(x - map.rect.minX),\(y - map.rect.minY)"
                    + ",\(map.rect.width),\(map.rect.height)")
            setNeedsRender()
            return
        }
        let vertical = abs(deltaY) >= abs(deltaX)
        if let region = scrollRegion(at: point, axis: vertical ? .vertical : .horizontal) {
            applyScroll(
                path: region.path,
                axis: region.axis,
                delta: region.axis == .vertical ? deltaY : deltaX
            )
            if !region.phaseHandlers.isEmpty {
                wheelScrolls[region.path] = host?.now() ?? 0
                reportScrollPhase(region.path, .interacting)
                host?.scheduleRender()
            }
        }
    }

    /// kind: 0 = down, 1 = up, 2 = move. Taps fire on `up` within slop;
    /// dragging beyond the slop scrolls the innermost scrollable ancestor;
    /// sliders capture the pointer from `down`.
    public func pointerEvent(kind: Int, x: Double, y: Double) {
        let point = CGPoint(x: x, y: y)
        switch kind {
        case 0:
            pointerIsDown = true
            pointerStart = point
            pointerLast = point
            isDragScrolling = false
            dragScrollPath = nil
            pressedTap = nil
            // Touching down halts any in-flight momentum (native behaviour).
            let coasting = Array(scrollVelocity.keys)
            scrollVelocity.removeAll()
            for path in coasting { reportScrollPhase(path, .idle) }
            dragVelocity = 0
            pointerLastTime = host?.now() ?? 0
            activeSlider = sliderRegions.reversed().first {
                $0.rect.insetBy(dx: -6, dy: -6).contains(point)
            }
            if let slider = activeSlider {
                applySlider(slider, x: point.x)
                return
            }
            activeDrag = nil
            pendingHorizontalDrag = nil
            if let candidate = dragRegions.reversed().first(where: { $0.rect.contains(point) }) {
                // A horizontal swipe waits to see the drag direction before
                // engaging: only a clearly horizontal drag engages it, so taps
                // still fire and vertical drags scroll. A free drag (e.g. the
                // meme caption) engages immediately.
                if candidate.gesture.isHorizontalSwipe {
                    pendingHorizontalDrag = candidate
                } else {
                    activeDrag = candidate
                    dragStartPoint = point
                }
            }
            pressedTap = tapRegions.reversed().first { $0.rect.contains(point) }
            if let tap = pressedTap, tap.feedback != .none, activeDrag == nil {
                showPressFeedback(tap, at: point)
            }

        case 2:
            guard pointerIsDown else { return }
            if let slider = activeSlider {
                applySlider(slider, x: point.x)
                pointerLast = point
                return
            }
            // Resolve a deferred horizontal swipe: engage it once the drag is
            // clearly horizontal; once it's clearly vertical, yield to scrolling.
            if activeDrag == nil, let pending = pendingHorizontalDrag {
                let dx = point.x - pointerStart.x
                let dy = point.y - pointerStart.y
                let threshold = max(pending.gesture.minimumDistance, 8)
                if abs(dx) > abs(dy), abs(dx) > threshold {
                    activeDrag = pending
                    dragStartPoint = pointerStart
                    pendingHorizontalDrag = nil
                    pressedTap = nil
                    releasePressFeedback()
                } else if abs(dy) > abs(dx), abs(dy) > threshold {
                    pendingHorizontalDrag = nil  // a vertical drag → let it scroll
                } else {
                    pointerLast = point
                    return  // still ambiguous; wait for a clearer direction
                }
            }
            if let drag = activeDrag {
                // A drag gesture preempts scroll/tap once it owns the pointer.
                let translation = CGSize(
                    width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y)
                drag.gesture.onChangedAction?(DragGesture.Value(
                    startLocation: dragStartPoint, location: point,
                    translation: translation, predictedEndLocation: point))
                pressedTap = nil
                releasePressFeedback()
                pointerLast = point
                setNeedsRender()
                return
            }
            let totalDx = point.x - pointerStart.x
            let totalDy = point.y - pointerStart.y
            // A drag starting over a host-drawn map pans its camera; engaged
            // past the tap slop (like drag-scroll) so taps on the controls
            // overlaid on the map still fire.
            if mapDragID == nil, !isDragScrolling, abs(totalDx) + abs(totalDy) > 6,
               let map = mapRegions.reversed().first(where: { $0.rect.contains(pointerStart) }) {
                mapDragID = map.id
                pressedTap = nil
                releasePressFeedback()
            }
            if let mapID = mapDragID {
                let deltaX = point.x - pointerLast.x
                let deltaY = point.y - pointerLast.y
                hostViewHandlers[mapID]?("pan:\(deltaX),\(deltaY)")
                pointerLast = point
                setNeedsRender()
                return
            }
            if !isDragScrolling, abs(totalDx) + abs(totalDy) > 6 {
                let vertical = abs(totalDy) >= abs(totalDx)
                if let region = scrollRegion(
                    at: pointerStart,
                    axis: vertical ? .vertical : .horizontal
                ) {
                    isDragScrolling = true
                    dragScrollPath = region.path
                    dragScrollAxis = region.axis
                    pressedTap = nil
                    releasePressFeedback()
                    reportScrollPhase(region.path, .interacting)
                }
            }
            if isDragScrolling, let path = dragScrollPath {
                let delta = dragScrollAxis == .vertical
                    ? pointerLast.y - point.y
                    : pointerLast.x - point.x
                applyScroll(path: path, axis: dragScrollAxis, delta: delta)
                // Track a smoothed velocity (points/sec) for the release fling.
                let now = host?.now() ?? 0
                let dt = now - pointerLastTime
                if dt > 0.0001 {
                    let instantaneous = delta / CGFloat(dt)
                    dragVelocity = dragVelocity * 0.6 + instantaneous * 0.4
                    pointerLastTime = now
                }
            }
            pointerLast = point

        case 1:
            if let drag = activeDrag {
                let translation = CGSize(
                    width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y)
                drag.gesture.onEndedAction?(DragGesture.Value(
                    startLocation: dragStartPoint, location: point,
                    translation: translation, predictedEndLocation: point))
                activeDrag = nil
                pointerIsDown = false
                pressedTap = nil
                releasePressFeedback()
                setNeedsRender()
                return
            }
            // Release with momentum: hand the smoothed velocity to an inertial
            // fling that decays over time (see `stepFling`).
            if isDragScrolling, let path = dragScrollPath, abs(dragVelocity) > 60 {
                scrollVelocity[path] = dragVelocity
                flingLastTime = host?.now() ?? 0
                setNeedsRender()
                reportScrollPhase(path, .decelerating, velocity: dragVelocity)
            } else if isDragScrolling, let path = dragScrollPath {
                reportScrollPhase(path, .idle)
            }
            let wasDragScrolling = isDragScrolling
            let wasMapDragging = mapDragID != nil
            defer {
                pointerIsDown = false
                isDragScrolling = false
                dragScrollPath = nil
                mapDragID = nil
                pressedTap = nil
                activeSlider = nil
                pendingHorizontalDrag = nil
                releasePressFeedback()
            }
            guard activeSlider == nil, !wasDragScrolling, !wasMapDragging else { return }

            // Focus/blur text fields on tap.
            if let field = textFieldRegions.reversed().first(where: { $0.rect.contains(point) }) {
                focusTextField(field)
                return
            }
            if focusedFieldPath != nil {
                blurTextInput()
            }
            guard let tap = pressedTap, tap.rect.contains(point) else {
                return
            }
            tap.action()
            // A tap may mutate plain (non-@State) runtime state such as the
            // TabView selection, so always schedule a frame after handling it.
            setNeedsRender()

        default:
            break
        }
    }

    /// Show press feedback for a region and remember it so it can be
    /// released on lift / cancel. The feedback is drawn into the display
    /// list, identical on every GPU backend (pointer input only reaches the
    /// runtime when chrome is drawn; component-system renderers
    /// render their own).
    func showPressFeedback(_ tap: TapRegion, at point: CGPoint) {
        drawnPresses[tap.id] = DrawnPress(
            rect: tap.rect, point: point,
            style: tap.feedback, start: animationTime, released: false)
        setNeedsRender()
        activePressFeedback = tap
    }

    /// Release any in-flight press feedback (lift, cancel, or drag take-over).
    func releasePressFeedback() {
        guard let tap = activePressFeedback else { return }
        drawnPresses[tap.id]?.released = true
        setNeedsRender()
        activePressFeedback = nil
    }

    /// A drawn press-feedback overlay: a flat highlight held while pressed,
    /// or a ripple radiating from the press point (see drawPressFeedback).
    struct DrawnPress {
        var rect: CGRect
        var point: CGPoint
        var style: PressFeedback
        var start: Double
        var released: Bool
    }

    var drawnPresses: [String: DrawnPress] = [:]

    private func hypotSize(_ dx: CGFloat, _ dy: CGFloat) -> CGFloat {
        (dx * dx + dy * dy).squareRoot()
    }

    /// Draws active press feedback over the content and prunes finished
    /// entries. Ripples animate for 0.45s; highlights hold until release.
    func drawPressFeedback(_ pass: RenderPass) {
        guard let host, !drawnPresses.isEmpty else { return }
        let now = animationTime
        var finished: [String] = []
        for (id, press) in drawnPresses {
            switch press.style {
            case .none:
                finished.append(id)
            case .highlight:
                if press.released {
                    finished.append(id)
                } else {
                    host.fillRect(
                        press.rect, cornerRadius: 8,
                        color: Color(white: 0.47, opacity: 0.18))
                }
            case .ripple:
                let progress = min(1, (now - press.start) / 0.45)
                if progress >= 1 {
                    finished.append(id)
                    continue
                }
                pass.wantsContinuousRender = true
                // A circle radiating from the press point to cover the rect,
                // clipped to the (rounded) region, fading as it grows.
                let reach = max(
                    hypotSize(press.point.x - press.rect.minX, press.point.y - press.rect.minY),
                    max(
                        hypotSize(press.rect.maxX - press.point.x, press.point.y - press.rect.minY),
                        max(
                            hypotSize(press.point.x - press.rect.minX, press.rect.maxY - press.point.y),
                            hypotSize(press.rect.maxX - press.point.x, press.rect.maxY - press.point.y))))
                let radius = reach * progress
                host.pushClip(press.rect, cornerRadius: 8)
                host.fillRect(
                    CGRect(
                        x: press.point.x - radius, y: press.point.y - radius,
                        width: radius * 2, height: radius * 2),
                    cornerRadius: radius,
                    color: Color(white: 0.47, opacity: 0.35 * (1 - progress)))
                host.popClip()
            }
        }
        for id in finished {
            drawnPresses.removeValue(forKey: id)
        }
    }

    func applySlider(_ slider: SliderRegion, x: CGFloat) {
        let fraction = min(max((x - slider.rect.minX) / max(1, slider.rect.width), 0), 1)
        slider.set(fraction)
        setNeedsRender()
    }

    // MARK: - Text input

    func focusTextField(_ field: TextFieldRegion) {
        if focusedFieldPath == field.path { return }
        if focusedFieldPath != nil {
            host?.endTextInput()
        }
        focusedFieldPath = field.path
        focusedFieldSet = field.set
        host?.beginTextInput(field.get(), in: field.rect, fontSize: field.fontSize)
        setNeedsRender()
    }

    func blurTextInput() {
        guard focusedFieldPath != nil else { return }
        focusedFieldPath = nil
        focusedFieldSet = nil
        host?.endTextInput()
        setNeedsRender()
    }

    /// Hosts call these from their native input implementation.
    public func textChanged(_ text: String) {
        focusedFieldSet?(text)
    }

    public func textSubmitted() {
        blurTextInput()
    }

    /// The native input ended on the host side (e.g. it lost focus).
    public func textInputEnded() {
        focusedFieldPath = nil
        focusedFieldSet = nil
        setNeedsRender()
    }

    // MARK: - Native host views

    /// A native widget reported a new value (host -> runtime).
    public func hostViewEvent(id: String, value: String) {
        if let handler = treeHandlers[id] {
            handler(value)
        } else if id.hasSuffix(".geo") {
            // A geometry reader's report that came before the frame that
            // registers its handler (the one it first appears in): kept, not
            // dropped, or a reader measured once is never measured again.
            recordGeometry(id: id, value: value)
        } else {
            hostViewHandlers[id]?(value)
        }
        // A lazy list's report of the rows it shows asks for a render itself,
        // only when they near the edge of what was built: most reports, one
        // per scrolled row, need none.
        if id.hasSuffix(".window") || id.hasSuffix(".geometry") { return }
        requestFrame()
    }
}

/// Serializes one host view (with its laid-out frame) for `syncHostViews`.
func hostViewEntryJSON(_ spec: HostViewSpec, frame: CGRect) -> String {
    var fields: [String] = []
    fields.append("\"id\":\(jsonString(spec.id))")
    fields.append("\"kind\":\(jsonString(spec.kind))")
    fields.append("\"x\":\(num(frame.minX))")
    fields.append("\"y\":\(num(frame.minY))")
    fields.append("\"w\":\(num(frame.width))")
    fields.append("\"h\":\(num(frame.height))")
    fields.append("\"value\":\(jsonString(spec.value))")
    let options = spec.options.map { jsonString($0) }.joined(separator: ",")
    fields.append("\"options\":[\(options)]")
    let params = spec.params
        .map { "\(jsonString($0.key)):\(jsonString($0.value))" }
        .joined(separator: ",")
    fields.append("\"params\":{\(params)}")
    return "{" + fields.joined(separator: ",") + "}"
}

// MARK: - Draw pass

func draw(_ node: RenderNode, pass: RenderPass) {
    // `.allowsHitTesting(false)`: drawn, but the touch targets made inside
    // it are dropped.
    if node.hitTestingDisabled {
        let taps = pass.tapRegions.count, drags = pass.dragRegions.count, sliders = pass.sliderRegions.count
        _draw(node, pass: pass)
        pass.tapRegions.removeSubrange(taps...)
        pass.dragRegions.removeSubrange(drags...)
        pass.sliderRegions.removeSubrange(sliders...)
        return
    }
    _draw(node, pass: pass)
}

/// A node's children in the order they are drawn: by `.zIndex`, the order
/// they were written in among equals.
func _drawOrder(_ children: [RenderNode]) -> [RenderNode] {
    guard children.contains(where: { $0.zIndex != 0 }) else { return children }
    return children.enumerated().sorted { a, b in
        a.element.zIndex != b.element.zIndex ? a.element.zIndex < b.element.zIndex : a.offset < b.offset
    }.map(\.element)
}

private func _draw(_ node: RenderNode, pass: RenderPass) {
    let host = pass.host
    switch node.kind {
    case .box:
        // `.rotationEffect` / `.scaleEffect` push an affine transform about the
        // node's center for the duration of its drawing.
        let transformed = node.rotation != 0 || node.scaleEffect != 1
        if transformed {
            let m = AffineTransform.rotationScale(
                angle: node.rotation, scale: Double(node.scaleEffect),
                cx: Double(node.frame.midX), cy: Double(node.frame.midY))
            host.pushTransform(m.a, m.b, m.c, m.d, m.e, m.f)
        }
        if let shadow = node.shadow {
            host.drawShadow(
                node.frame,
                // Clamp the fully-rounded sentinel (circle/capsule
                // silhouettes) to the resolved size.
                cornerRadius: min(
                    node.cornerRadius,
                    min(node.frame.width, node.frame.height) / 2),
                color: shadow.color.opacity(node.opacity),
                radius: shadow.radius,
                x: shadow.x,
                y: shadow.y
            )
        }
        for background in node.background {
            drawDecoration(background, radius: node.cornerRadius, pass: pass)
        }
        if let action = node.tapAction {
            // Clip the hit region to the enclosing scroll viewport so overflow
            // rows aren't tappable and press feedback stays inside the column.
            let rect = pass.currentClip.map { node.frame.clipped(to: $0) } ?? node.frame
            let id = node.identityPath ?? "tap@\(Int(node.frame.minX)),\(Int(node.frame.minY))"
            pass.tapRegions.append(TapRegion(
                rect: rect, action: action, feedback: node.pressFeedback, id: id))
        }
        if let gesture = node.dragGesture {
            pass.dragRegions.append(DragRegion(rect: node.frame, gesture: gesture))
        }
        if node.hasLifecycle, let path = node.identityPath ?? node.onChangeKeys.first {
            pass.lifecycle[path] = (node.onAppear, node.disappearHandler)
        }
        // A ViewThatFits draws only the candidate its layout chose.
        for (index, child) in node.children.enumerated() where node.fitsAxes == nil || index == node.fitsChosen {
            draw(child, pass: pass)
        }
        for overlay in node.overlay {
            drawDecoration(overlay, radius: node.cornerRadius, pass: pass)
        }
        if transformed { host.popTransform() }

    case .text(let string):
        // A line-limited run is clipped to its capped frame so wrapped overflow
        // lines don't spill past the reserved height.
        let clipped = node.lineLimit != nil
        if clipped { host.pushClip(node.frame, cornerRadius: 0) }
        host.drawText(
            string,
            in: node.frame,
            fontSize: node.font.size,
            weight: node.font.weight.value,
            color: node.color
        )
        if clipped { host.popClip() }

    case .shape(.path(let path), let fill, let stroke):
        // An app's own shape: its rects, rounded rects and ellipses, scaled
        // to the frame. (Subpaths of lines are not filled here yet.)
        for element in path.scaled(to: node.frame).elements {
            let (rect, radius): (CGRect, CGFloat)
            switch element {
            case .rect(let r): (rect, radius) = (r, 0)
            case .roundedRect(let r, let cornerRadius): (rect, radius) = (r, cornerRadius)
            case .ellipse(let r): (rect, radius) = (r, min(r.width, r.height) / 2)
            case .move, .line, .closeSubpath: continue
            }
            if let fill { host.fillRect(rect, cornerRadius: radius, color: fill) }
            if let (color, lineWidth) = stroke { host.strokeRect(rect, cornerRadius: radius, lineWidth: lineWidth, color: color) }
        }

    case .shape(let kind, let fill, let stroke):
        let radius = shapeRadius(kind, frame: node.frame)
        if let fill {
            host.fillRect(node.frame, cornerRadius: radius, color: fill)
        }
        if let (color, lineWidth) = stroke {
            host.strokeRect(node.frame, cornerRadius: radius, lineWidth: lineWidth, color: color)
        }

    case .image(let source, let isRemote, _, let fit):
        switch host.imageInfo(source, isRemote: isRemote) {
        case .ready(let intrinsic):
            let dest = fit
                ? aspectFitRect(intrinsic, in: node.frame)
                : aspectFillRect(intrinsic, in: node.frame)
            host.drawImage(
                source,
                isRemote: isRemote,
                in: dest,
                clip: node.frame,
                cornerRadius: node.imageCornerRadius,
                opacity: node.opacity
            )
        case .loading:
            let r = node.imageCornerRadius > 0 ? node.imageCornerRadius : 8
            host.fillRect(node.frame, cornerRadius: r, color: Color(white: 0, opacity: 0.08))
        case .failed:
            let r = node.imageCornerRadius > 0 ? node.imageCornerRadius : 8
            host.fillRect(node.frame, cornerRadius: r, color: Color(white: 0, opacity: 0.08))
            host.strokeRect(
                node.frame, cornerRadius: r, lineWidth: 1,
                color: Color(white: 0, opacity: 0.2)
            )
        }

    case .divider:
        host.fillRect(node.frame, cornerRadius: 0, color: node.color)

    case .gradient(let shape, let paint):
        host.fillGradient(
            node.frame,
            cornerRadius: shapeRadius(shape, frame: node.frame),
            gradientJSON: paint.json()
        )

    case .hostView(let spec):
        // A host may draw this view's content inline right here (SwiftMap
        // tile scenes under the SwiftGPU renderer); otherwise draw a light
        // placeholder behind the native widget so layout reads correctly
        // before the host-view sync materializes it. Claimed views still
        // register (their onChange takes gesture commands — see mapRegions)
        // but are excluded from the native sync (see hostDrawnViewIDs).
        if host.drawHostView(
            id: spec.id, kind: spec.kind, value: spec.value, params: spec.params,
            in: node.frame
        ) {
            pass.hostDrawnViewIDs.insert(spec.id)
        } else {
            host.fillRect(node.frame, cornerRadius: 6, color: Color(white: 0, opacity: 0.04))
        }
        pass.hostViews.append((spec, node.frame))

    case .textField(let placeholder):
        let focused = Runtime.shared.focusedFieldPath == node.identityPath
        host.fillRect(node.frame, cornerRadius: 6, color: Color.secondaryBackground.opacity(node.opacity))
        host.strokeRect(
            node.frame,
            cornerRadius: 6,
            lineWidth: focused ? 2 : 1,
            color: focused
                ? Color.accentColor.opacity(node.opacity)
                : Color.separator.opacity(node.opacity * 2)
        )
        let value = node.textGet?() ?? ""
        // While focused the host's native input overlay renders the live text.
        if !focused {
            let display = value.isEmpty ? placeholder : node.secureEntry ? String(repeating: "\u{2022}", count: value.count) : value
            let color = value.isEmpty
                ? Color.secondary.opacity(0.6 * node.opacity)
                : Color.primary.opacity(node.opacity)
            let inset = CGRect(
                x: node.frame.minX + 8,
                y: node.frame.minY + (node.frame.height - node.font.size * 1.3) / 2,
                width: max(0, node.frame.width - 16),
                height: node.font.size * 1.3
            )
            host.drawText(
                display, in: inset,
                fontSize: node.font.size, weight: node.font.weight.value,
                color: color
            )
        }
        if let path = node.identityPath, let get = node.textGet, let set = node.textSet {
            pass.textFieldRegions.append(TextFieldRegion(
                rect: node.frame, path: path, get: get, set: set, fontSize: node.font.size
            ))
        }

    case .slider:
        let knobRadius: CGFloat = 10
        let trackRect = CGRect(
            x: node.frame.minX,
            y: node.frame.midY - 2,
            width: node.frame.width,
            height: 4
        )
        host.fillRect(
            trackRect, cornerRadius: 2,
            color: Color(white: 0, opacity: 0.15 * node.opacity)
        )
        let knobX = node.frame.minX + node.sliderFraction * node.frame.width
        let active = CGRect(
            x: trackRect.minX,
            y: trackRect.minY,
            width: max(0, knobX - trackRect.minX),
            height: trackRect.height
        )
        host.fillRect(active, cornerRadius: 2, color: Color.accentColor.opacity(node.opacity))
        let knobRect = CGRect(
            x: min(max(knobX - knobRadius, node.frame.minX), node.frame.maxX - 2 * knobRadius),
            y: node.frame.midY - knobRadius,
            width: 2 * knobRadius,
            height: 2 * knobRadius
        )
        host.fillRect(knobRect, cornerRadius: knobRadius, color: Color.white.opacity(node.opacity))
        host.strokeRect(
            knobRect, cornerRadius: knobRadius, lineWidth: 1,
            color: Color(white: 0, opacity: 0.25 * node.opacity)
        )
        if let path = node.identityPath, let set = node.sliderSet {
            pass.sliderRegions.append(SliderRegion(rect: node.frame, path: path, set: set))
        }

    case .spacer:
        break

    case .scroll(let axis):
        host.pushClip(node.frame, cornerRadius: node.cornerRadius)
        pass.pushClipRect(node.frame)
        for child in node.children {
            draw(child, pass: pass)
        }
        pass.popClipRect()
        host.popClip()

        let path = node.identityPath ?? ""
        let contentLength = axis == .vertical
            ? node.scrollContentSize.height
            : node.scrollContentSize.width
        let viewportLength = axis == .vertical ? node.frame.height : node.frame.width
        // `.scrollDisabled(true)`: no region, so a drag over it scrolls the
        // scroll around it, if any.
        if !node.scrollDisabled { pass.scrollRegions.append(ScrollRegion(
            rect: node.frame,
            path: path,
            axis: axis,
            contentLength: contentLength,
            viewportLength: viewportLength,
            phaseHandlers: node.scrollPhaseHandlers
        )) }

        if node.showsIndicators, !node.scrollDisabled, contentLength > viewportLength {
            let offset = Runtime.shared.scrollOffsets[path] ?? 0
            let fraction = viewportLength / contentLength
            if axis == .vertical {
                let barHeight = max(24, node.frame.height * fraction)
                let track = node.frame.height - barHeight
                let barY = node.frame.minY + track * (offset / max(1, contentLength - viewportLength))
                host.fillRect(
                    CGRect(x: node.frame.maxX - 5, y: barY, width: 3, height: barHeight),
                    cornerRadius: 1.5,
                    color: Color(white: 0, opacity: 0.25)
                )
            } else {
                let barWidth = max(24, node.frame.width * fraction)
                let track = node.frame.width - barWidth
                let barX = node.frame.minX + track * (offset / max(1, contentLength - viewportLength))
                host.fillRect(
                    CGRect(x: barX, y: node.frame.maxY - 5, width: barWidth, height: 3),
                    cornerRadius: 1.5,
                    color: Color(white: 0, opacity: 0.25)
                )
            }
        }

    case .stack:
        for child in _drawOrder(node.children) {
            draw(child, pass: pass)
        }

    case .geometryReader:
        for child in node.children {
            draw(child, pass: pass)
        }

    case .progress(let value):
        let track = Color(white: 0, opacity: 0.15 * node.opacity)
        if let value {
            // Determinate: a horizontal bar filled to `value`.
            let h: CGFloat = 4
            let barRect = CGRect(
                x: node.frame.minX, y: node.frame.midY - h / 2,
                width: node.frame.width, height: h
            )
            host.fillRect(barRect, cornerRadius: h / 2, color: track)
            let clamped = max(0, min(1, value))
            host.fillRect(
                CGRect(x: barRect.minX, y: barRect.minY, width: barRect.width * clamped, height: h),
                cornerRadius: h / 2,
                color: Color.accentColor.opacity(node.opacity)
            )
        } else {
            // Indeterminate: 8 dots on a ring with a brightness trail that
            // rotates over time (precomputed unit circle, no trig needed).
            pass.wantsContinuousRender = true
            let unit: [(CGFloat, CGFloat)] = [
                (1, 0), (0.7071, 0.7071), (0, 1), (-0.7071, 0.7071),
                (-1, 0), (-0.7071, -0.7071), (0, -1), (0.7071, -0.7071),
            ]
            let cx = node.frame.midX
            let cy = node.frame.midY
            let r = min(node.frame.width, node.frame.height) / 2 - 2
            let lead = Int(Runtime.shared.animationTime * 8) % 8
            for i in 0 ..< 8 {
                let dist = ((i - lead) % 8 + 8) % 8
                let fade = 0.2 + 0.8 * (Double(dist) / 7)
                let dot = CGRect(
                    x: cx + unit[i].0 * r - 1.6,
                    y: cy + unit[i].1 * r - 1.6,
                    width: 3.2, height: 3.2
                )
                host.fillRect(
                    dot, cornerRadius: 1.6,
                    color: Color(white: 0.4, opacity: fade * node.opacity)
                )
            }
        }
    }
}

/// Draw a background/overlay node, letting an enclosing `.cornerRadius`
/// round plain rectangle fills (approximation of clipping).
private func drawDecoration(_ node: RenderNode, radius: CGFloat, pass: RenderPass) {
    if radius > 0, case .shape(.rectangle, let fill, let stroke) = node.kind {
        if let fill {
            pass.host.fillRect(node.frame, cornerRadius: radius, color: fill)
        }
        if let (color, lineWidth) = stroke {
            pass.host.strokeRect(
                node.frame, cornerRadius: radius, lineWidth: lineWidth, color: color
            )
        }
        return
    }
    // A gradient background inherits the enclosing `.cornerRadius`.
    if radius > 0, case .gradient(.rectangle, let paint) = node.kind {
        pass.host.fillGradient(node.frame, cornerRadius: radius, gradientJSON: paint.json())
        return
    }
    draw(node, pass: pass)
}

private func shapeRadius(_ kind: ShapeKind, frame: CGRect) -> CGFloat {
    switch kind {
    case .rectangle:
        return 0
    case .roundedRectangle(let radius):
        return radius
    case .circle, .capsule:
        return min(frame.width, frame.height) / 2
    case .path:
        return 0
    }
}

func aspectFitRect(_ intrinsic: CGSize, in frame: CGRect) -> CGRect {
    guard intrinsic.width > 0, intrinsic.height > 0, frame.width > 0, frame.height > 0 else {
        return frame
    }
    let scale = min(frame.width / intrinsic.width, frame.height / intrinsic.height)
    let size = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
    return alignedRect(size: size, container: frame, alignment: .center)
}

/// The smallest rect covering `frame` at the image's aspect ratio (it may
/// overflow `frame`; the host clips it). Mirrors `.scaledToFill()`.
func aspectFillRect(_ intrinsic: CGSize, in frame: CGRect) -> CGRect {
    guard intrinsic.width > 0, intrinsic.height > 0, frame.width > 0, frame.height > 0 else {
        return frame
    }
    let scale = max(frame.width / intrinsic.width, frame.height / intrinsic.height)
    let size = CGSize(width: intrinsic.width * scale, height: intrinsic.height * scale)
    return alignedRect(size: size, container: frame, alignment: .center)
}



