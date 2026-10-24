// The render tree. Views resolve into a small tree of `RenderNode`s each
// pass; layout assigns frames and the draw walk emits host commands.

enum ShapeKind: Sendable {
    case rectangle
    case roundedRectangle(CGFloat)
    case circle
    case capsule
    /// An app's own `Shape`: its `path(in:)`, asked for the unit square
    /// and scaled to the view's frame by the host (Shapes.swift).
    case path(Path)
}

struct ShadowSpec {
    var color: Color
    var radius: CGFloat
    var x: CGFloat
    var y: CGFloat
}

/// A `.searchable` field bridged into a native list's header (below the large
/// title): the prompt plus get/set for the bound query string.
struct SearchSpec {
    let prompt: String
    let get: () -> String
    let set: (String) -> Void
}

/// How touch feedback is rendered for a tappable region, following each
/// platform's idiom. Self-drawing renderers draw it into the display list;
/// component-system renderers map it to their component library's
/// own feedback (CSS :active, a Compose ripple). Apple uses real SwiftUI, so
/// its feedback is native and this is unused there.
package enum PressFeedback: Int {
    /// No host feedback (plain `onTapGesture`).
    case none = 0
    /// A flat translucent overlay while held (list rows, selectable cells).
    case highlight = 1
    /// A press-point ripple that radiates outward (buttons, navigation links).
    case ripple = 2
}

/// A platform-native widget the host materializes over the canvas, keyed by
/// structural identity and reconciled each frame. `kind` tells the host what
/// to create (e.g. "picker", "datepicker", "html:color"); `params` carry its
/// configuration as JSON-safe strings; `value` is the current value. The host
/// reports changes through `Runtime.hostViewEvent(id:value:)`.
struct HostViewSpec {
    var id: String
    var kind: String
    var params: [String: String]
    var value: String
    /// Option labels for list-style widgets (Picker).
    var options: [String]
    var onChange: ((String) -> Void)?
}

package final class RenderNode {
    enum Kind {
        /// Generic decorated container with 0 or 1 child.
        case box
        case text(String)
        case shape(ShapeKind, fill: Color?, stroke: (Color, CGFloat)?)
        case stack(StackAxis)
        case spacer(CGFloat?)
        case divider
        /// Clipping scroll container (single child = content).
        case scroll(StackAxis)
        case image(source: String, isRemote: Bool, resizable: Bool, fit: Bool)
        case textField(placeholder: String)
        case slider
        case gradient(ShapeKind, GradientPaint)
        /// A platform-native widget overlaid on the canvas (Picker, etc.).
        case hostView(HostViewSpec)
        /// Progress indicator; nil value = indeterminate spinner.
        case progress(Double?)
        /// GeometryReader: builds its content once its frame is known.
        case geometryReader

        /// The case alone (a text's string, a shape's colours left out).
        var caseIndex: Int {
            switch self {
            case .box: return 0
            case .text: return 1
            case .shape: return 2
            case .stack: return 3
            case .spacer: return 4
            case .divider: return 5
            case .scroll: return 6
            case .image: return 7
            case .textField: return 8
            case .slider: return 9
            case .gradient: return 10
            case .hostView: return 11
            case .progress: return 12
            case .geometryReader: return 13
            }
        }
    }

    var kind: Kind
    var children: [RenderNode] = []

    // Stack attributes.
    var stackAlignment: Alignment = .center
    var stackSpacing: CGFloat?

    /// `ViewThatFits(in:)` (a box whose children are its candidates): the
    /// axes they must fit along, and the one the core's layout chose (the
    /// component renderers choose for themselves, by the "fits" param).
    var fitsAxes: Axis.Set?
    var fitsChosen = 0

    // Box decorations.
    var padding = EdgeInsets()
    var fixedWidth: CGFloat?
    var fixedHeight: CGFloat?
    var minWidth: CGFloat?
    var minHeight: CGFloat?
    var maxWidth: CGFloat?
    var maxHeight: CGFloat?
    var expandsWidth = false
    var expandsHeight = false
    var alignment = Alignment.center
    var background: [RenderNode] = []
    var overlay: [RenderNode] = []
    var cornerRadius: CGFloat = 0
    /// Corner radius applied directly to an image's drawn bounds (set when a
    /// `.cornerRadius` wraps an `Image`/`AsyncImage`), so the host rounds and
    /// clips the image itself rather than relying on rounded scissor clipping.
    var imageCornerRadius: CGFloat = 0
    var opacity: Double = 1
    /// Visual translation (`.offset`); shifts this node's subtree at layout
    /// time without affecting siblings.
    var offsetX: CGFloat = 0
    var offsetY: CGFloat = 0
    /// `.position(x:y:)`: this (greedy) box centers its child at the point,
    /// in the box's own coordinates.
    var positionX: CGFloat?
    var positionY: CGFloat?
    /// `.clipped()`: hosts clip this box's content to its bounds.
    var clipsContent = false
    /// `.textSelection`: true when the text inside can be selected, false
    /// when it can't (nil: as the container around it says).
    var textSelection: Bool?
    /// `.fixedSize(horizontal:vertical:)`: "h", "v" or "hv", the axes on which
    /// this box takes its content's ideal size whatever it is offered.
    var fixedSize: String?
    /// `.aspectRatio(_:contentMode:)`: this box keeps width/height = ratio
    /// (fit: inside the proposal; fill: covering it).
    var aspectRatio: CGFloat?
    var aspectFill = false
    /// `Image.interpolation(.none)`: hosts draw the image without smoothing.
    var imageInterpolation: String?
    /// `.tint`: the accent color for controls in this subtree (a param for
    /// component hosts; core controls read it from the environment).
    var tint: Color?
    /// `.overlay(alignment:)` / `.background(alignment:)`: where the
    /// decoration layers sit over this box (default center).
    var overlayAlignment: Alignment = .center
    var backgroundAlignment: Alignment = .center
    /// `Image(systemName:)`: the SF Symbol name the glyph stands in for —
    /// the Apple host draws the real symbol.
    var symbolName: String?
    /// A symbol's secondary layer color (`.foregroundStyle(_:_:)`).
    var symbolSecondary: Color?
    /// The symbol is an `Image`, not a `Text` of one (`Text(Image(…))`):
    /// hosts that draw the real symbol draw an image (in a list row the
    /// separator then starts at the row's text, not at the symbol).
    var symbolIsImage = false
    /// A shape's `.trim(from:to:)` range.
    var trim: (CGFloat, CGFloat)?
    /// Text under `.multilineTextAlignment`: its alignment goes on the wire
    /// even when centred (hosts start text at the leading edge otherwise).
    var textAlignmentExplicit = false
    /// Visual rotation (radians) and uniform scale (`.rotationEffect` /
    /// `.scaleEffect`), applied about the node's center at draw time via a host
    /// transform. Don't affect layout.
    var rotation: Double = 0
    var scaleEffect: CGFloat = 1
    var tapAction: (() -> Void)?
    /// Taps `tapAction` waits for (`onTapGesture(count: 2)` is a double tap).
    var tapCount = 1
    /// `.dropDestination(for:)`: the dropped files' paths, and whether a
    /// drag is over the view.
    var dropAction: (([String]) -> Void)?
    var dropTargeted: ((Bool) -> Void)?
    /// Press feedback for this tappable region (drawn ripple/highlight under
    /// self-drawing renderers; serialized for component systems). `.none` for plain
    /// `onTapGesture`; Buttons/links ripple, list rows highlight.
    var pressFeedback: PressFeedback = .none
    /// The originating Button's role (toolbar extraction reads `.confirm`).
    var buttonRole: ButtonRole?
    var dragGesture: DragGesture?
    /// A pinch (`MagnifyGesture` / `MagnificationGesture`): the running and
    /// final magnification since it began.
    var magnifyChanged: ((CGFloat) -> Void)?
    var magnifyEnded: ((CGFloat) -> Void)?
    /// Presentation modifiers on a sheet's content: `.presentationDetents`
    /// ("medium,large"), `.presentationDragIndicator` ("visible"/"hidden"),
    /// `.interactiveDismissDisabled`.
    var presentationDetents: String?
    var presentationDragIndicator: String?
    var presentationDismissDisabled = false
    /// `.presentationCompactAdaptation` on a popover's content: the
    /// horizontal and vertical adaptations ("popover,popover").
    var presentationCompactAdaptation: String?
    /// The view a `.popover` hangs from: its presentation's id, so a host
    /// that presents popovers natively anchors it here (param "popover").
    var popoverAnchor: String?
    /// A concatenated Text's styled spans (empty: one plain run).
    var textRuns: [TextRun] = []
    /// The list row is the list's current selection (semantic hosts draw it).
    var listSelected = false
    /// `.controlSize` on a progress view ("small"/"large"/"mini"), regular when nil.
    var controlSize: String?
    /// `.contextMenu`: the items a long press (or secondary click) offers.
    var contextMenuItems: [RowActionItem] = []
    /// `.swipeActions`: the buttons a horizontal swipe reveals on this row.
    var swipeItems: [(edge: HorizontalEdge, fullSwipe: Bool, item: RowActionItem)] = []
    /// `.ignoresSafeArea()`: under component-system renderers the host owns
    /// the safe area, so the flag crosses the wire (param "safeArea") for the
    /// host to extend this node; the self-drawing path already fills the
    /// canvas edge to edge.
    var ignoresSafeArea = false
    var shadow: ShadowSpec?
    /// `.accessibilityLabel/Hint/Value/Identifier/Hidden`: cross the wire as
    /// params ("a11yLabel", "a11yHint", "a11yValue", "a11yId", "a11yHidden")
    /// for component-system hosts to apply to the native element.
    var accessibilityLabel: String?
    var accessibilityHint: String?
    var accessibilityValue: String?
    var accessibilityIdentifier: String?
    var accessibilityHidden = false
    /// `.accessibilityElement(children:)`: "combine", "ignore" or "contain".
    var accessibilityChildren: String?

    // Resolved text attributes.
    var font: Font = .body
    var color: Color = .primary
    /// Max lines for a text run (`.lineLimit`); nil = unlimited.
    var lineLimit: Int?

    /// TextField layout axis (`TextField(_:text:axis:)`): `.vertical` grows
    /// with its content (a multi-line input), bounded by `lineRange`.
    var textAxis: Axis?
    /// `TextEditor`: a container-filling multi-line editor (no line cap).
    var textEditor = false
    /// Line bounds for a growing text field (`.lineLimit(1...6)`).
    var lineRange: ClosedRange<Int>?

    /// Scroll content anchor (`.defaultScrollAnchor`): where the scroll
    /// starts and stays pinned while at that edge (e.g. `.bottom` chat logs).
    var scrollAnchor: UnitPoint?
    /// The role `scrollAnchor` was given (`.defaultScrollAnchor(_:for:)`:
    /// "initialOffset" / "sizeChanges"); nil for every role.
    var scrollAnchorRole: String?
    /// `.defaultScrollAnchor`'s alignment role: where content shorter than
    /// the scroll sits (nil: the top).
    var scrollAlignment: UnitPoint?
    /// `.scrollEdgeEffectStyle` at the top and bottom edges.
    var scrollEdgeTop: ScrollEdgeEffectStyle?
    /// `onScrollGeometryChange` handlers on this scroll (MainActor: builds).
    /// One per `.onScrollGeometryChange` over it, by that modifier's path
    /// (a modifier built again over a reused scroll replaces its own).
    var scrollGeometryHandlers: [(key: String, handler: @MainActor (ScrollGeometry) -> Void)] = []
    /// `onScrollPhaseChange` handlers on this scroll, by modifier path as
    /// above: the phase the host reports, with its geometry and velocity
    /// when it sends them.
    var scrollPhaseHandlers: [(key: String, handler: @MainActor (ScrollPhase, ScrollGeometry?, CGVector?) -> Void)] = []
    var scrollEdgeBottom: ScrollEdgeEffectStyle?

    /// Axis of the stack that owns this spacer (spacers only stretch along
    /// their stack's axis).
    var spacerAxis: StackAxis?

    /// Structural identity (set for nodes with persistent state of their
    /// own, e.g. scroll offsets, text-field focus).
    var identityPath: String?
    /// The build path of the view this node came from (structural identity
    /// with `ForEach` ids in it — SwiftUI's view identity). Set by
    /// `buildNode` on the node a view returns, innermost first; nodes the
    /// runtime synthesizes (list cells) take their content's with a suffix.
    /// Component renderers key children on it, so a row keeps its identity
    /// when rows are inserted, removed or moved around it.
    var buildPath: String?
    /// Set on the node a reusable composite view built (Reuse.swift): the
    /// same object comes back while the view's inputs are unchanged, so
    /// renderers can keep what they derived from it.
    package internal(set) var isReusedSubtreeRoot = false
    /// The composite view whose build ended with this node, kept to build it
    /// again alone (InPlace.swift); nil for nodes no composite returned.
    var rebuildSite: _RebuildSite?
    /// Bumped when a node below this one is replaced in place (InPlace.swift):
    /// what an encoder kept of this node's subtree is stale then.
    var contentEpoch = 0
    /// A List row not built this frame (off screen): an empty cell with the
    /// row's identity (param "placeholder").
    var isRowPlaceholder = false
    /// On a List's scroll node: its rows build lazily around the window the
    /// host reports (param "window" names where the host reports it).
    var lazyRows = false
    var showsIndicators = true
    /// `.scrollContentBackground(.hidden)` on a List: its ground is not drawn
    /// (param "contentBg").
    var contentBackgroundHidden = false
    /// Set on the scroll node a `List` builds: hosts with a native list
    /// component render it as one (real `List` on Apple) instead of a plain
    /// scroll column.
    var isList = false
    /// The `.listStyle` a List was built under (nil: the host's default).
    var listStyle: String?
    /// Whether the host draws lines between this list's rows.
    var listRowSeparators = true
    /// On a list row: `.listRowSeparator(.hidden)` was in scope for it (set
    /// on the row, not the list), so no line goes under it.
    var hidesRowSeparator = false
    /// On a list row: `.listRowInsets` and `.listRowBackground` in scope for
    /// it (params "rowInsets", "rowBg" on its cell).
    var listRowInsets: EdgeInsets?
    var listRowBackground: Color?
    /// On a list row: `.listRowBackground` with a view (a ZStack of the
    /// cell's fill and a highlight), built: drawn behind the cell's content
    /// in place of the host's own fill and selection (param "rowOwnBg").
    var listRowBackgroundNode: RenderNode?
    /// On a text field: a `SecureField`'s, its text masked (param "secure").
    var secureEntry = false
    /// On a button: disabled (param "disabled").
    var buttonDisabled = false
    /// `.zIndex`: drawn above its siblings with lower ones (param "z").
    var zIndex: Double = 0
    /// `.allowsHitTesting(false)`: drawn, but nothing in it takes a touch
    /// (param "nohit").
    var hitTestingDisabled = false
    /// Drawn above the screen's chrome (its bars), as a context menu is: a
    /// view an alignment guide moved out of the overlay it is in (a menu
    /// floated above a composer). Hosts lift it into a layer of its own at
    /// the overlay's place.
    var floatsAboveChrome = false
    /// `.onHover`: told when a pointer comes over it and leaves (param
    /// "hover", the handler's id; "1" in, "0" out).
    var hoverAction: ((Bool) -> Void)?
    /// What the hosts that can use them read and the others leave (params
    /// as they are: "blur", "help", "shortcut").
    var hostHints: [(String, String)] = []
    /// Set by `.listRowInsets` / `.listRowBackground` on the node they
    /// built: the row's traits as they stood there, which the row they are
    /// in takes however deep in its content they were applied (SwiftUI's
    /// row traits rise to the row).
    var rowTraitInsets: EdgeInsets??
    var rowTraitBackground: (color: Color?, node: RenderNode?)?
    /// `.listRowSeparator` likewise: whether the row's separator shows.
    var rowTraitSeparator: Bool?
    /// On a List's scroll: `\.defaultMinListRowHeight` when it is not the
    /// platform's 44 (param "minRowHeight").
    var minListRowHeight: CGFloat?
    /// `.scrollDismissesKeyboard` ("immediately" / "interactively" / "never").
    var dismissesKeyboard: String?
    /// `.scrollBounceBehavior` ("always" / "basedOnSize"), on the axes it
    /// was given ("v", "h" or "vh").
    var scrollBounce: String?
    /// `.scrollDisabled(true)` in scope: the scroll does not scroll (its
    /// content lies as laid out; it still lays out and draws).
    var scrollDisabled = false
    /// Set on the column `.safeAreaInset(edge:)` builds ("top" / "bottom"):
    /// hosts that own a safe area pin the inset as bar chrome at that edge
    /// and let the content scroll beneath it (param "inset").
    /// Built by a NavigationStack or a TabView: it brings its own
    /// navigation (a split view's column that leads to one takes no bar of
    /// its own).
    var ownsNavigation = false
    /// On a NavigationStack's node: the content it was built around (the
    /// stack the split view puts round a column hands it back when the
    /// column brings its own).
    var navigationContent: RenderNode?
    var safeAreaEdge: String?
    /// The inset is a `safeAreaBar` (iOS 26: the bar's scroll edge effect
    /// over the content beneath), not a `safeAreaInset` (param "insetBar").
    var safeAreaBar = false
    /// The spacing the app gave the inset (`spacing:`); nil, the system's
    /// (param "insetSpacing"; the column's own spacing is 0 for hosts that
    /// stack the two).
    var safeAreaSpacing: CGFloat?
    /// On the column a screen's `.bottomBar` toolbar builds (with
    /// `safeAreaEdge` "bottom"): what each item in its row is (see
    /// `_withBottomBar`), for hosts that have a bottom toolbar of their own
    /// (param "bottomBar").
    var bottomBarItems: String?
    /// `Grid`: the column count, on the column of lines it builds (param
    /// "grid"). Its `GridRow`s are row stacks (`isGridRow`, param
    /// "gridRow"); every line carries its index (param "gridLine") so hosts
    /// can place cells in shared columns, and lines that are not rows (a
    /// divider) span them all.
    var gridColumns: Int?
    var isGridRow = false
    var gridRowAligned = false
    var gridLine: Int?
    /// The column widths the last grid measure settled on (self-drawn layout).
    var gridColumnWidths: [CGFloat] = []
    /// List-cell role ("row" / "header") on the cell boxes a `List` builds
    /// in semantic mode — hosts apply their platform's row metrics and
    /// separators keyed on it.
    var listCell: String?

    // Control bindings (nil when disabled).
    var textGet: (() -> String)?
    var textSet: ((String) -> Void)?
    /// `.onSubmit`: Return in the field (hosts: Enter without Shift/Option
    /// in a multi-line field submits; Shift+Enter inserts a newline).
    var textSubmit: (() -> Void)?
    /// `.onKeyPress` handlers for a text field, innermost first.
    var keyPress: [KeyPressHandler] = []
    /// `.textFieldStyle` for this field (nil = the host's default).
    var textFieldStyle: String?
    /// `.keyboardType` / `.textInputAutocapitalization` / `.autocorrectionDisabled`.
    var keyboardType: String?
    var autocapitalization: String?
    var autocorrectionDisabled = false
    /// `.focused($state)`: whether the guest wants this field focused, and
    /// where the host reports focus changes (the keyboard coming and going).
    var focusGet: (() -> Bool)?
    var focusSet: ((Bool) -> Void)?
    /// `TextField(_:text:selection:)`: a selection the app set for the host
    /// to show (UTF-16 offsets and the request's number, nil while the app
    /// has set none), and where the host reports the field's own selection
    /// (TextSelection.swift).
    var selectionGet: (() -> (start: Int, end: Int, request: Int)?)?
    var selectionSet: ((Int, Int) -> Void)?
    /// `.truncationMode` for text ("head" / "middle" / "tail").
    var truncation: String?
    /// Text or a symbol whose colour nobody set: the host's container
    /// colours it (param "autoColor").
    var colorAuto = false
    /// Text whose font nobody set: the host's container chooses it (param
    /// "autoFont").
    var fontAuto = false
    /// `.navigationSplitViewColumnWidth` where the app put it: ideal, min,
    /// max (params colWidth, colWidthMin, colWidthMax).
    var columnWidth: (ideal: Double, min: Double?, max: Double?)?
    /// A part of a Form, for hosts that make the system's Form from the
    /// drawn one (param "form": "form", "section", "header", "card", "row",
    /// "footer").
    var formRole: String?
    /// A `Button` (param "button": its style), with its control size and
    /// border shape, for hosts that make the system's button.
    var buttonStyleName: String?
    var buttonControlSize: String?
    var buttonBorderShape: String?
    /// A `ShareLink`: what it shares (param "share", with "shareSubject" /
    /// "shareMessage"), and the button style it was given ("shareStyle").
    var shareItem: String?
    var shareSubject: String?
    var shareMessage: String?
    var shareStyle: String?
    var sharePreview: String?
    /// A `Label`'s icon-and-title stack (param "label"), for hosts that make
    /// the system's Label.
    var isLabel = false
    /// `.textCase` in scope for text ("upper" / "lower" / "none"): hosts
    /// whose containers case text themselves (a native list's section
    /// header) follow it.
    var textCase: String?
    /// `.lineSpacing` for text (points between lines).
    var lineSpacing: Double?
    /// `.id(_:)`: the scroll target name a `ScrollViewProxy.scrollTo` uses.
    var scrollTarget: String?
    var sliderFraction: Double = 0
    var sliderSet: ((Double) -> Void)?

    // Lifecycle handlers (set by onAppear/onDisappear modifiers).
    var onAppear: (() -> Void)?
    var onDisappear: (() -> Void)?
    /// The `.onChange` values kept for views whose node this is (their keys
    /// in `Runtime.onChangeStore`): let go of when the node leaves the tree.
    var onChangeKeys: [String] = []

    /// Whether the node takes part in the lifecycle (appear, disappear).
    var hasLifecycle: Bool { onAppear != nil || onDisappear != nil || !onChangeKeys.isEmpty }

    /// What runs when the node leaves the tree: its onDisappear, and the
    /// `.onChange` values it keeps let go of.
    var disappearHandler: (() -> Void)? {
        guard !onChangeKeys.isEmpty else { return onDisappear }
        let keys = onChangeKeys
        let disappear = onDisappear
        return {
            disappear?()
            for key in keys { Runtime.shared.onChangeStore[key] = nil }
        }
    }

    /// GeometryReader: builds its content once the frame is known (in `place`).
    /// The reader's content for its size and its place in the window (nil
    /// before its host has measured it: the size is then the canvas's).
    var geometryBuild: ((CGSize, CGPoint?) -> RenderNode)?

    // Layout results.
    var frame = CGRect.zero
    var measuredChildSizes: [CGSize] = []
    var scrollContentSize = CGSize.zero

    init(kind: Kind) {
        self.kind = kind
    }

    static func box(child: RenderNode?) -> RenderNode {
        let node = RenderNode(kind: .box)
        if let child {
            node.children = [child]
        }
        return node
    }
}

/// Apple's size-class enum, for `@Environment(\.horizontalSizeClass)`.
public enum UserInterfaceSizeClass: Sendable, Equatable {
    case compact
    case regular
}

/// `EnvironmentValues`' fields, shared by the copies of an environment
/// until one of them is changed (copy on write): a build copies its
/// environment at every level of the tree, and copying forty fields
/// (closures, arrays, dictionaries) retained and released each of them.
final class _EnvironmentStorage {
    var font: Font = .body
    var foregroundColor: Color = .primary
    var foregroundColorSet: Bool = false
    var fontSet: Bool = false
    var foregroundSecondary: Color?
    var inSheet: Bool = false
    var formRow: Bool = false
    var containerAlignment = ContainerAlignment()
    var tint: Color?
    var onSubmit: (() -> Void)?
    var keyPressHandlers: [KeyPressHandler] = []
    var textFieldStyle: String?
    var listStyle: String?
    var listRowSeparators: Bool = true
    var labelsHidden: Bool = false
    var listRowInsets: EdgeInsets?
    var listRowBackground: Color?
    var listRowBackgroundView: AnyView?
    var scrollIndicatorsHidden = false
    var scrollContentBackgroundHidden = false
    var defaultMinListRowHeight: CGFloat = 44
    var scrollDismissesKeyboard: String?
    var scrollBounceBehavior: String?
    var _isScrollEnabled: Bool = true
    var scrollEdgeTop: ScrollEdgeEffectStyle?
    var scrollEdgeBottom: ScrollEdgeEffectStyle?
    var keyboardType: String?
    var autocapitalization: String?
    var autocorrectionDisabled: Bool = false
    var truncationMode: String?
    var textCase: String?
    var lineSpacing: Double?
    var opacity: Double = 1
    var _isEnabled: Bool = true
    var lineLimit: Int?
    var lineRange: ClosedRange<Int>?
    var animation: Animation?
    var animationChosen = false
    var colorScheme: ColorScheme = .light
    var displayScaleOverride: CGFloat?
    var horizontalSizeClassOverride: UserInterfaceSizeClass?
    var dismiss: DismissAction = DismissAction(action: {})
    var refresh: RefreshAction?
    var custom: [ObjectIdentifier: Any] = [:]
    var objects: [ObjectIdentifier: AnyObject] = [:]
    var tabIconSize: CGFloat?

    init() {}

    init(copying other: _EnvironmentStorage) {
        font = other.font
        foregroundColor = other.foregroundColor
        foregroundColorSet = other.foregroundColorSet
        fontSet = other.fontSet
        foregroundSecondary = other.foregroundSecondary
        inSheet = other.inSheet
        formRow = other.formRow
        containerAlignment = other.containerAlignment
        tint = other.tint
        onSubmit = other.onSubmit
        keyPressHandlers = other.keyPressHandlers
        textFieldStyle = other.textFieldStyle
        listStyle = other.listStyle
        listRowSeparators = other.listRowSeparators
        labelsHidden = other.labelsHidden
        listRowInsets = other.listRowInsets
        listRowBackground = other.listRowBackground
        listRowBackgroundView = other.listRowBackgroundView
        scrollIndicatorsHidden = other.scrollIndicatorsHidden
        scrollContentBackgroundHidden = other.scrollContentBackgroundHidden
        defaultMinListRowHeight = other.defaultMinListRowHeight
        scrollDismissesKeyboard = other.scrollDismissesKeyboard
        scrollBounceBehavior = other.scrollBounceBehavior
        _isScrollEnabled = other._isScrollEnabled
        scrollEdgeTop = other.scrollEdgeTop
        scrollEdgeBottom = other.scrollEdgeBottom
        keyboardType = other.keyboardType
        autocapitalization = other.autocapitalization
        autocorrectionDisabled = other.autocorrectionDisabled
        truncationMode = other.truncationMode
        textCase = other.textCase
        lineSpacing = other.lineSpacing
        opacity = other.opacity
        _isEnabled = other._isEnabled
        lineLimit = other.lineLimit
        lineRange = other.lineRange
        animation = other.animation
        animationChosen = other.animationChosen
        colorScheme = other.colorScheme
        displayScaleOverride = other.displayScaleOverride
        horizontalSizeClassOverride = other.horizontalSizeClassOverride
        dismiss = other.dismiss
        refresh = other.refresh
        custom = other.custom
        objects = other.objects
        tabIconSize = other.tabIconSize
    }
}

/// Inherited attributes resolved while building the node tree. Public so apps
/// can extend it (via `EnvironmentKey`) and read values with `@Environment`.
public struct EnvironmentValues {
    var _storage = _EnvironmentStorage()

    /// Before a change: this copy's own storage.
    private mutating func _makeUnique() {
        if !isKnownUniquelyReferenced(&_storage) {
            _storage = _EnvironmentStorage(copying: _storage)
        }
    }

    var font: Font {
        get { _storage.font }
        set { _makeUnique(); _storage.font = newValue }
    }
    var foregroundColor: Color {
        get { _storage.foregroundColor }
        set { _makeUnique(); _storage.foregroundColor = newValue }
    }
    /// Whether the app set the foreground (`.foregroundColor` /
    /// `.foregroundStyle`, or a guest-drawn component did): otherwise text
    /// takes the container's own colour on hosts with native containers (a
    /// list's section header, a button's style) — param "autoColor".
    var foregroundColorSet: Bool {
        get { _storage.foregroundColorSet }
        set { _makeUnique(); _storage.foregroundColorSet = newValue }
    }
    /// Whether the app set the font (`.font`, `.bold`): otherwise text takes
    /// its container's on hosts with native containers (param "autoFont").
    var fontSet: Bool {
        get { _storage.fontSet }
        set { _makeUnique(); _storage.fontSet = newValue }
    }
    /// `.foregroundStyle(_:_:)`'s second style: a symbol's secondary layer
    /// (the badge of `xmark.circle.fill`).
    var foregroundSecondary: Color? {
        get { _storage.foregroundSecondary }
        set { _makeUnique(); _storage.foregroundSecondary = newValue }
    }
    /// Inside a sheet: grouped content takes the raised palette.
    var inSheet: Bool {
        get { _storage.inSheet }
        set { _makeUnique(); _storage.inSheet = newValue }
    }
    /// Inside a Form's or a List's row: a picker there shows its title
    /// beside its value, and a segmented one takes the row's width.
    var formRow: Bool {
        get { _storage.formRow }
        set { _makeUnique(); _storage.formRow = newValue }
    }
    /// How the container a view is built in aligns it (an overlay's, a
    /// ZStack's, a stack's across its axis): where its `.alignmentGuide`s
    /// for those guides count.
    var containerAlignment: ContainerAlignment {
        get { _storage.containerAlignment }
        set { _makeUnique(); _storage.containerAlignment = newValue }
    }
    /// `.tint`: the accent color controls use (nil = the system accent).
    var tint: Color? {
        get { _storage.tint }
        set { _makeUnique(); _storage.tint = newValue }
    }
    /// `.onSubmit` in scope for text fields.
    var onSubmit: (() -> Void)? {
        get { _storage.onSubmit }
        set { _makeUnique(); _storage.onSubmit = newValue }
    }
    /// `.onKeyPress` handlers in scope for text fields, outermost first.
    var keyPressHandlers: [KeyPressHandler] {
        get { _storage.keyPressHandlers }
        set { _makeUnique(); _storage.keyPressHandlers = newValue }
    }
    /// `.textFieldStyle` in scope ("plain" / "roundedBorder" / "automatic").
    var textFieldStyle: String? {
        get { _storage.textFieldStyle }
        set { _makeUnique(); _storage.textFieldStyle = newValue }
    }
    /// `.listStyle` in scope ("plain" / "insetGrouped" / "sidebar" / …).
    var listStyle: String? {
        get { _storage.listStyle }
        set { _makeUnique(); _storage.listStyle = newValue }
    }
    /// `.listRowSeparator`: false hides the lines between a list's rows.
    var listRowSeparators: Bool {
        get { _storage.listRowSeparators }
        set { _makeUnique(); _storage.listRowSeparators = newValue }
    }
    /// `.labelsHidden()` in scope: controls leave out their own label.
    var labelsHidden: Bool {
        get { _storage.labelsHidden }
        set { _makeUnique(); _storage.labelsHidden = newValue }
    }
    /// `.listRowInsets` in scope for a list's rows (nil: the list's own).
    var listRowInsets: EdgeInsets? {
        get { _storage.listRowInsets }
        set { _makeUnique(); _storage.listRowInsets = newValue }
    }
    /// `.listRowBackground` in scope for a list's rows: a colour (nil: the
    /// list's own).
    var listRowBackground: Color? {
        get { _storage.listRowBackground }
        set { _makeUnique(); _storage.listRowBackground = newValue }
    }
    /// `.listRowBackground` with a view other than a colour.
    var listRowBackgroundView: AnyView? {
        get { _storage.listRowBackgroundView }
        set { _makeUnique(); _storage.listRowBackgroundView = newValue }
    }
    /// `.scrollIndicators(.hidden)` in scope.
    var scrollIndicatorsHidden: Bool {
        get { _storage.scrollIndicatorsHidden }
        set { _makeUnique(); _storage.scrollIndicatorsHidden = newValue }
    }
    /// `.scrollContentBackground(.hidden)` in scope.
    var scrollContentBackgroundHidden: Bool {
        get { _storage.scrollContentBackgroundHidden }
        set { _makeUnique(); _storage.scrollContentBackgroundHidden = newValue }
    }
    /// `\.defaultMinListRowHeight`: the least a list's row is tall.
    public var defaultMinListRowHeight: CGFloat {
        get { _storage.defaultMinListRowHeight }
        set { _makeUnique(); _storage.defaultMinListRowHeight = newValue }
    }
    /// `.scrollDismissesKeyboard` in scope.
    var scrollDismissesKeyboard: String? {
        get { _storage.scrollDismissesKeyboard }
        set { _makeUnique(); _storage.scrollDismissesKeyboard = newValue }
    }
    /// `.scrollBounceBehavior` in scope ("always" / "basedOnSize" and the
    /// axes, "basedOnSize:v").
    var scrollBounceBehavior: String? {
        get { _storage.scrollBounceBehavior }
        set { _makeUnique(); _storage.scrollBounceBehavior = newValue }
    }
    /// Whether scroll views in this subtree scroll (`.scrollDisabled`).
    var _isScrollEnabled: Bool {
        get { _storage._isScrollEnabled }
        set { _makeUnique(); _storage._isScrollEnabled = newValue }
    }
    /// `.scrollEdgeEffectStyle` in scope at the top and bottom edges (nil:
    /// automatic, the host's soft edge).
    var scrollEdgeTop: ScrollEdgeEffectStyle? {
        get { _storage.scrollEdgeTop }
        set { _makeUnique(); _storage.scrollEdgeTop = newValue }
    }
    var scrollEdgeBottom: ScrollEdgeEffectStyle? {
        get { _storage.scrollEdgeBottom }
        set { _makeUnique(); _storage.scrollEdgeBottom = newValue }
    }
    var keyboardType: String? {
        get { _storage.keyboardType }
        set { _makeUnique(); _storage.keyboardType = newValue }
    }
    var autocapitalization: String? {
        get { _storage.autocapitalization }
        set { _makeUnique(); _storage.autocapitalization = newValue }
    }
    var autocorrectionDisabled: Bool {
        get { _storage.autocorrectionDisabled }
        set { _makeUnique(); _storage.autocorrectionDisabled = newValue }
    }
    var truncationMode: String? {
        get { _storage.truncationMode }
        set { _makeUnique(); _storage.truncationMode = newValue }
    }
    /// `.textCase`: "upper", "lower", or "none" (`.textCase(nil)`); nil
    /// when no `.textCase` is in scope (the container's own default).
    var textCase: String? {
        get { _storage.textCase }
        set { _makeUnique(); _storage.textCase = newValue }
    }
    var lineSpacing: Double? {
        get { _storage.lineSpacing }
        set { _makeUnique(); _storage.lineSpacing = newValue }
    }
    var opacity: Double {
        get { _storage.opacity }
        set { _makeUnique(); _storage.opacity = newValue }
    }
    var _isEnabled: Bool {
        get { _storage._isEnabled }
        set { _makeUnique(); _storage._isEnabled = newValue }
    }
    /// The most lines text here takes (`.lineLimit`), nil for no limit.
    public var lineLimit: Int? {
        get { _storage.lineLimit }
        set { _makeUnique(); _storage.lineLimit = newValue }
    }
    /// Line-count bounds (`.lineLimit(1...6)`): caps descendant text at the
    /// upper bound and sizes growing text fields between the bounds.
    var lineRange: ClosedRange<Int>? {
        get { _storage.lineRange }
        set { _makeUnique(); _storage.lineRange = newValue }
    }
    /// Animation in scope (`withAnimation` transaction or `.animation`), used by
    /// animatable modifiers to interpolate value changes.
    var animation: Animation? {
        get { _storage.animation }
        set { _makeUnique(); _storage.animation = newValue }
    }
    /// Whether a modifier chose the animation in scope (`.animation`,
    /// `.transaction`) rather than its being the transaction's: a view
    /// built again alone takes the frame's transaction only when not
    /// (InPlace.swift).
    var animationChosen: Bool {
        get { _storage.animationChosen }
        set { _makeUnique(); _storage.animationChosen = newValue }
    }
    /// Effective color scheme, readable as `@Environment(\.colorScheme)`.
    public var colorScheme: ColorScheme {
        get { _storage.colorScheme }
        set { _makeUnique(); _storage.colorScheme = newValue }
    }
    /// `@Environment(\.displayScale)`: device pixels per point.
    public var displayScale: CGFloat {
        get { displayScaleOverride ?? Runtime.shared.displayScale }
        set { displayScaleOverride = newValue }
    }
    var displayScaleOverride: CGFloat? {
        get { _storage.displayScaleOverride }
        set { _makeUnique(); _storage.displayScaleOverride = newValue }
    }
    /// `@Environment(\.horizontalSizeClass)`: the host's system's (an
    /// iPhone's stays compact in landscape), else `.compact` below the 700pt
    /// canvas width where split views collapse, `.regular` otherwise —
    /// re-resolved every build, so it tracks resizes live. Settable
    /// (`.environment(\.horizontalSizeClass, …)`) for overrides.
    public var horizontalSizeClass: UserInterfaceSizeClass? {
        get { horizontalSizeClassOverride ?? (Runtime.shared.compactWidth ? .compact : .regular) }
        set { horizontalSizeClassOverride = newValue }
    }
    var horizontalSizeClassOverride: UserInterfaceSizeClass? {
        get { _storage.horizontalSizeClassOverride }
        set { _makeUnique(); _storage.horizontalSizeClassOverride = newValue }
    }
    /// `@Environment(\.verticalSizeClass)`: the host's system's, else
    /// `.regular` unless the canvas is shorter than it is wide on a
    /// compact-width host (landscape phone).
    public var verticalSizeClass: UserInterfaceSizeClass? {
        Runtime.shared.hostVerticalSizeClass
            ?? (Runtime.shared.compactWidth && Runtime.shared.height < Runtime.shared.width ? .compact : .regular)
    }
    /// Dismiss action for the enclosing presentation (`@Environment(\.dismiss)`).
    /// Injected when a sheet/popover/alert builds its content; a no-op outside one.
    public var dismiss: DismissAction {
        get { _storage.dismiss }
        set { _makeUnique(); _storage.dismiss = newValue }
    }

    /// `.refreshable`'s action (`@Environment(\.refresh)`); nil outside one.
    public var refresh: RefreshAction? {
        get { _storage.refresh }
        set { _makeUnique(); _storage.refresh = newValue }
    }

    /// Custom values keyed by `EnvironmentKey` type.
    var custom: [ObjectIdentifier: Any] {
        get { _storage.custom }
        set { _makeUnique(); _storage.custom = newValue }
    }
    /// Objects put in the environment (`.environment(_:)` of an
    /// `@Observable`), keyed by their type.
    var objects: [ObjectIdentifier: AnyObject] {
        get { _storage.objects }
        set { _makeUnique(); _storage.objects = newValue }
    }
    /// Set while building a `TabView`'s tab-bar labels so bare `Image`s render
    /// at an icon size (the app uses unsized `Image` in `.tabItem`, the native
    /// idiom). Reimplementation-only; Apple's native tab bar sizes its own.
    var tabIconSize: CGFloat? {
        get { _storage.tabIconSize }
        set { _makeUnique(); _storage.tabIconSize = newValue }
    }

    public init() {}

    public subscript<K: EnvironmentKey>(key: K.Type) -> K.Value {
        get { custom[ObjectIdentifier(key)] as? K.Value ?? K.defaultValue }
        set { custom[ObjectIdentifier(key)] = newValue }
    }

    /// Whether controls in this subtree are enabled (`.disabled` modifier).
    public var isEnabled: Bool {
        get { _isEnabled }
        set { _isEnabled = newValue }
    }

    /// Whether scroll views in this subtree scroll (`.scrollDisabled`), as
    /// SwiftUI's `\.isScrollEnabled`.
    public var isScrollEnabled: Bool {
        get { _isScrollEnabled }
        set { _isScrollEnabled = newValue }
    }
}

/// Dismisses the enclosing presentation, mirroring SwiftUI's `DismissAction`.
/// Read it with `@Environment(\.dismiss)` and call it like a function.
public struct DismissAction {
    let action: () -> Void
    public func callAsFunction() { action() }
}

/// `.refreshable`'s action, as the views inside it see it: `await refresh()`.
public struct RefreshAction: Sendable {
    let action: @Sendable () async -> Void
    public func callAsFunction() async { await action() }
}

/// A key into `EnvironmentValues`, with a default for when nothing set it.
public protocol EnvironmentKey {
    associatedtype Value
    static var defaultValue: Value { get }
}

package struct BuildContext {
    var path: String
    var env: EnvironmentValues
    let storage: StateStorage

    /// Nearest enclosing navigation stack (for NavigationLink / titles).
    var navigation: NavigationState?
    var navigationLevel = 0

    func descend(_ component: String) -> BuildContext {
        var copy = self
        copy.path = path + "/" + component
        return copy
    }
}

/// A composite view's component in its descendants' paths: its type's name
/// without generic arguments, and a number of its own when generic (each
/// instantiation another type, as a different view at a place is). Made
/// once per type: the whole name (`ModifiedContent<…>` of everything below)
/// ran to hundreds of characters, built every frame and carried in every
/// path, key and lookup beneath it.
func typeName(_ value: Any) -> String {
    let type = type(of: value)
    let id = ObjectIdentifier(type)
    if let known = _typeComponents[id] { return known }
    let component: String
    // A struct's or enum's name is in its descriptor; `String(describing:)`
    // demangles the whole generic name to keep the part before "<" (a
    // millisecond a type interpreted, for each one built the first time).
    if let nominal = _nominalName(type) {
        if nominal.generic {
            _genericTypeCount += 1
            component = nominal.name + "<\(_genericTypeCount)>"
        } else {
            component = nominal.name
        }
        _typeComponents[id] = component
        return component
    }
    let full = String(describing: type)
    if let generic = full.firstIndex(of: "<") {
        _genericTypeCount += 1
        // ASCII: a path with any other character is compared and hashed
        // through Unicode normalization, many times slower.
        component = full[..<generic] + "<\(_genericTypeCount)>"
    } else {
        component = full
    }
    _typeComponents[id] = component
    return component
}

nonisolated(unsafe) private var _typeComponents: [ObjectIdentifier: String] = [:]
nonisolated(unsafe) private var _genericTypeCount = 0

/// Resolves an arbitrary view into a render node.
@MainActor
func buildNode(view: any View, ctx: inout BuildContext) -> RenderNode {
    let node = buildUnidentifiedNode(view: view, ctx: &ctx)
    if node.buildPath == nil { node.buildPath = ctx.path }
    return node
}

/// What a view type is to the builder, found once per type: each `as?` is a
/// protocol conformance lookup, and a view went through up to six that
/// failed, every frame, before being built as what it is.
struct _ViewKind: OptionSet {
    let rawValue: UInt8
    static let primitive = _ViewKind(rawValue: 1)
    static let reusable = _ViewKind(rawValue: 2)
    static let shape = _ViewKind(rawValue: 4)
    static let multi = _ViewKind(rawValue: 16)
    static let environment = _ViewKind(rawValue: 32)
    static let modified = _ViewKind(rawValue: 64)

    /// Neither a primitive nor a shape: an app's own view (or one of ours)
    /// with a body.
    var isComposite: Bool { isDisjoint(with: [.primitive, .shape]) }
}

func _viewKind(_ view: any View) -> _ViewKind {
    let id = ObjectIdentifier(type(of: view))
    if let known = _viewKinds[id] { return known }
    // A view with a body of its own is built through it: none of the kinds
    // below has one (each a built-in primitive, a shape or a representable,
    // whose `Body` is `Never`). Read from the view's `View` conformance, it
    // costs no lookup: asked as casts, each question a type does not answer
    // yes to scanned every conformance in the program the first time, two
    // to five of them for every type of view, most of a chat's first build.
    if !_bodyIsNever(view) && !_verifyViewKinds {
        _viewKinds[id] = []
        return []
    }
    // One answer for every instantiation of a generic view (a VStack of
    // any content): what it conforms to does not depend on what it holds,
    // and the runtime's own cache is per instantiation, so each new one
    // scanned the conformances again for every question it said no to.
    // (Structs only: a cast looks through an Optional to what it holds, so
    // an Optional's answers are its value's.)
    let descriptor = _isStruct(type(of: view)) ? _typeDescriptor(type(of: view)) : nil
    let kind: _ViewKind
    if let descriptor, let known = _viewKindsByDescriptor[descriptor], !_verifyViewKinds {
        kind = known
    } else {
        kind = _viewKindByCasts(view)
        if _verifyViewKinds, let descriptor, let known = _viewKindsByDescriptor[descriptor], known != kind {
            _viewKindMismatches.append("instantiation \(type(of: view))")
        }
        if let descriptor { _viewKindsByDescriptor[descriptor] = kind }
    }
    if _verifyViewKinds, !_bodyIsNever(view), !kind.isEmpty { _viewKindMismatches.append("\(type(of: view))") }
    _viewKinds[id] = _bodyIsNever(view) ? kind : []
    return _viewKinds[id]!
}

nonisolated(unsafe) private var _viewKindsByDescriptor: [UnsafeRawPointer: _ViewKind] = [:]

/// Whether a view's `Body` is `Never` (it has no body of its own).
private func _bodyIsNever<V: View>(_ view: V) -> Bool { V.Body.self == Never.self }

/// Checks `_viewKind`'s reading of `Body` against the casts (tests).
nonisolated(unsafe) package var _verifyViewKinds = false
nonisolated(unsafe) package var _viewKindMismatches: [String] = []

private func _viewKindByCasts(_ view: any View) -> _ViewKind {
    var kind: _ViewKind = []
    let type = type(of: view)
    // An app's own view cannot be one of ours (FieldRecords.swift), and a
    // type with no conformance record for a protocol cannot conform to it
    // (ConformanceIndex.swift): asked, the runtime scans every conformance.
    if _mayConformInternally(type) {
        if _mayConform(type, .primitiveView), let primitive = view as? _PrimitiveView {
            kind.insert(.primitive)
            if Swift.type(of: primitive)._isReusableBuild { kind.insert(.reusable) }
            if _verifyViewKinds, (view is _ReusableBuild) != kind.contains(.reusable) {
                _viewKindMismatches.append("reusable \(type)")
            }
        }
        // (Both, for an Optional: a cast looks through it to what it holds.)
        if _mayConform(type, .multiView), view is _MultiView { kind.insert(.multi) }
    }
    // A primitive is built as one whatever else it is (buildUnidentifiedNode
    // asks first), so whether it is also a shape is never read: a lookup
    // fewer for each of our types.
    if !kind.contains(.primitive), _mayConform(type, .shape), view is any Shape { kind.insert(.shape) }
    if view is _EnvironmentModifier { kind.insert(.environment) }
    if view is _ModifiedView { kind.insert(.modified) }
    return kind
}

nonisolated(unsafe) private var _viewKinds: [ObjectIdentifier: _ViewKind] = [:]

@MainActor
private func buildUnidentifiedNode(view: any View, ctx: inout BuildContext) -> RenderNode {
    let kind = _viewKind(view)
    if kind.contains(.primitive), let primitive = view as? _PrimitiveView {
        // Built-in views that don't say they build purely read or register
        // runtime state: nothing around them is reused (Reuse.swift).
        if !(kind.contains(.reusable) && primitive._buildIsPure(ctx)) {
            Runtime.shared.markBuildVolatile()
            _frameLogVolatile(view)
        }
        return primitive.makeNode(&ctx)
    }
    // An app's own `Shape` (a `path(in:)` of its own): filled with the
    // foreground colour, as a bare `Circle()` is.
    if kind.contains(.shape), let shape = view as? any Shape {
        return shape.makeNode(&ctx)
    }
    if kind.contains(.multi), let multi = view as? _MultiView {
        // A multi-view outside a stack container (e.g. an `if` at the top of
        // a body). Zero children render as nothing; one renders direct;
        // several overlap like an implicit ZStack.
        let children = multi.childViews()
        if children.count == 1 {
            var sub = ctx.descend(children[0].suffix)
            return buildNode(view: children[0].view, ctx: &sub)
        }
        let node = RenderNode(kind: .stack(.depth))
        node.children = children.map { entry in
            var sub = ctx.descend(entry.suffix)
            return buildNode(view: entry.view, ctx: &sub)
        }
        return node
    }

    // Composite view: reuse last frame's subtree when nothing it depends on
    // changed; otherwise connect state and recurse into its body.
    return buildCompositeReusing(view, ctx: &ctx)
}

/// Collects the flattened children of a container's content view.
@MainActor
func buildChildren(of view: any View, ctx: inout BuildContext) -> [RenderNode] {
    var result: [RenderNode] = []
    appendChildren(of: view, ctx: &ctx, into: &result)
    return result
}

@MainActor
func appendChildren(
    of view: any View,
    ctx: inout BuildContext,
    into result: inout [RenderNode]
) {
    let kind = _viewKind(view)
    if kind.contains(.multi), let multi = view as? _MultiView {
        for entry in multi.childViews() {
            var sub = ctx.descend(entry.suffix)
            appendChildren(of: entry.view, ctx: &sub, into: &result)
        }
        return
    }
    // An environment modifier draws nothing of its own: over a Group it
    // applies to each child, as SwiftUI's does, rather than making the
    // group one node (which stacked its children on top of each other).
    if kind.contains(.environment), let environment = view as? _EnvironmentModifier {
        var sub = ctx.descend(environment.descend)
        environment.transform(&sub.env)
        appendChildren(of: environment.child, ctx: &sub, into: &result)
        return
    }
    // Any other modifier over several views (`controls.padding(…)` where the
    // controls are a ViewBuilder's several views) applies to each of them,
    // which stay the container's children, as in SwiftUI.
    if kind.contains(.modified), let modified = view as? _ModifiedView, let parts = _modifiedParts(modified.child), parts.count != 1 {
        for (suffix, part) in parts {
            var sub = ctx.descend(suffix)
            let each = _ModifiedView(child: part, descend: modified.descend, pure: modified.pure, configure: modified.configure)
            appendChildren(of: each, ctx: &sub, into: &result)
        }
        return
    }
    // An app's own view whose body is several views (two Sections, an `if`
    // beside another) is those views in the container, as SwiftUI's is:
    // built as one node they overlapped like a ZStack (a Form's sections
    // drawn over each other), and an `if` that is false took a place of
    // its own. A body that comes to one view is kept and reused as that
    // view.
    if kind.isComposite {
        if let node = reusedSubtree(for: view, ctx: ctx) {
            result.append(node)
            return
        }
        _frameLogBuilt(view, ctx: ctx)
        var build = beginCompositeBuild(view, ctx: ctx)
        build.asPart = true
        var sub = ctx.descend(typeName(view))
        var parts: [RenderNode] = []
        _trackingObservation(at: ctx.path) {
            appendChildren(of: view.body, ctx: &sub, into: &parts)
        }
        if parts.count == 1 {
            if parts[0].buildPath == nil { parts[0].buildPath = sub.path }
            finishCompositeBuild(build, view: view, ctx: ctx, node: parts[0])
        } else {
            abandonCompositeBuild(build)
        }
        result += parts
        return
    }
    result.append(buildNode(view: view, ctx: &ctx))
}

/// The views a modifier's content stands for when it is several (a
/// TupleView, a Group, nested modifiers over one), each to take the
/// modifier itself; nil for a single view.
private func _modifiedParts(_ view: any View) -> [(String, any View)]? {
    // What the view is, known once per type: a cast the type answers no to
    // is a scan of every conformance the first time (a modifier's content
    // is most often an app's own view).
    let kind = _viewKind(view)
    if kind.contains(.multi), let multi = view as? _MultiView {
        var parts: [(String, any View)] = []
        for entry in multi.childViews() {
            if let nested = _modifiedParts(entry.view) {
                parts += nested.map { (entry.suffix + "/" + $0.0, $0.1) }
            } else {
                parts.append((entry.suffix, entry.view))
            }
        }
        return parts
    }
    if kind.contains(.modified), let modified = view as? _ModifiedView, let parts = _modifiedParts(modified.child) {
        return parts.map { ($0.0, _ModifiedView(child: $0.1, descend: modified.descend, pure: modified.pure, configure: modified.configure)) }
    }
    if kind.contains(.environment), let environment = view as? _EnvironmentModifier, let parts = _modifiedParts(environment.child) {
        return parts.map { ($0.0, _EnvironmentModifier(child: $0.1, descend: environment.descend, transform: environment.transform)) }
    }
    return nil
}
