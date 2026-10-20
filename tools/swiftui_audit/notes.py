"""Curated text for the audit report (report.py fills the numbers)."""

HEADLINE = """\
Isomer covers the everyday core of SwiftUI well: stacks and lazy stacks/grids, `Text`/`Image`/`Label`,
`Button`/`Toggle`/`TextField`/`TextEditor`/`Picker`/`Slider`/`Stepper`, `List`/`ForEach`/`Section`/`Form`,
`NavigationStack`/`NavigationSplitView`/`NavigationLink`, `TabView`/`Tab`, toolbars, sheets, alerts,
confirmation dialogs, popovers and inspectors, `@State`/`@Binding`/`@Observable`/`@Bindable`/`@Environment`/
`@FocusState`/`@AppStorage`, `.task`/`.onChange`/`.refreshable`/`.searchable`, `ScrollViewReader`, and Liquid
Glass. Measured against the whole public surface it implements a fifth to a quarter: {tl_have} of {tl_total} top-level
types (only {tl_present} with every member), {vm_have} of {vm_total} View-modifier base names, {env_present} of
{env_total} environment values, and none of the {scene_total} Scene modifiers.

The gaps cluster rather than scatter:

1. **Value-based navigation** (`NavigationPath`, `navigationDestination`, `NavigationLink(value:)`) is absent;
   Isomer only has destination-view links.
2. **Protocol-based customization**: no `ButtonStyle`/`LabelStyle`/`ToggleStyle`/`ProgressViewStyle`/`TextFieldStyle`
   protocols (styles are fixed option structs), no `Layout`, `PreferenceKey`, `Animatable`/`GeometryEffect`,
   `Transition`, the `@Entry` macro for environment keys, or custom `Scene` bodies.
3. **Gestures** beyond tap/drag/magnify: no `TapGesture`/`LongPressGesture` values, `onLongPressGesture`,
   `@GestureState`, `simultaneousGesture`/`highPriorityGesture`, or composition (`sequenced`, `exclusively`).
4. **Text and fonts**: no formatted text (`Text(_:format:)`, `Text(date, style:)`, `"\\(x, specifier:)"`),
   no `Text(AttributedString)`, no `Font.custom`; `.fontWeight`/`.italic`/`.monospaced`/`.underline` exist only on
   `Text`, and `.kerning`/`.tracking`/`.minimumScaleFactor` not at all.
5. **Environment**: only {env_present} values are public (`colorScheme`, `dismiss`, `displayScale`,
   `horizontalSizeClass`, `verticalSizeClass`, `isEnabled`, `isScrollEnabled`, `refresh`, `scenePhase`,
   `defaultMinListRowHeight`); `locale`, `openURL`, `isPresented`, `isSearching`, `editMode`, `layoutDirection`,
   `dynamicTypeSize` are missing.
6. **Shapes and drawing**: no `Ellipse`, `StrokeStyle`, `strokeBorder`, arcs/curves in `Path`, shape transforms,
   `Canvas`; `stroke`/`border`/`tint` take only `Color`; `clipShape` takes only three concrete shapes.
7. **Animation semantics**: `.transition` is a no-op, springs are ease-outs, no `matchedGeometryEffect`,
   phase/keyframe animators, or completion callbacks.
8. **Scenes**: `WindowGroup` only; no `Settings`/`Window`/`DocumentGroup`/`MenuBarExtra`, no `.commands`,
   `.defaultSize` or other scene modifiers.

Some API that exists is accepted but does nothing, or does less than its signature says (section 5): `.onDelete`,
`.transition`, `.allowsHitTesting`, `.contentShape` (non-rectangular), `.toolbarBackground`, `.submitLabel`,
`.formStyle`, `.accessibilityAddTraits`, `.ignoresSafeArea`'s regions/edges, the `searchable` placement, gesture
masks, `GeometryProxy.frame(in:)` (always at the origin), springs."""

TOP_P1_INTRO = """\
Ranked by how often typical apps hit them. "Tutorials" means Apple's SwiftUI tutorials (Landmarks,
Scrumdinger); "Skip" means SkipUI (a SwiftUI-on-Compose reimplementation) lists it as supported, i.e. its users
asked for it; "a/o" are call counts in apps written on Isomer / older native SwiftUI code (section 7). The apps
were written against Isomer, so their counts understate missing API; where they work around a gap it is noted."""

TOP_P1 = [
    ("Value-based navigation.",
     "`NavigationStack(path:root:)`, `NavigationPath`, `NavigationLink(value:label:)` / `NavigationLink(_:value:)`, "
     "`.navigationDestination(for:destination:)`, `.navigationDestination(isPresented:destination:)`, "
     "`.navigationDestination(item:destination:)`. Apple's navigation model since iOS 16 (programmatic push/pop, "
     "deep links, state restoration); agent_ui uses `navigationDestination` on its native path; Skip: full."),
    ("Item-driven and dismiss-aware presentations.",
     "`.sheet(item:onDismiss:content:)`, the `onDismiss:` argument of `.sheet(isPresented:)` and "
     "`.fullScreenCover`, `.fullScreenCover(item:)`, `.alert(_:isPresented:presenting:actions:message:)`, "
     "`.confirmationDialog(_:isPresented:titleVisibility:presenting:actions:)`. `sheet` is used 32/4 times; "
     "the item form is the standard \"edit this row\" pattern."),
    ("`SecureField`.",
     "Password entry. Visor's `PasswordField` falls back to a plain `TextField` where it is missing "
     "(visor_ui/Sources/PasswordField.swift); Skip: full."),
    ("Bindings to collections.",
     "`ForEach($items) { $item in ... }`, `List($items)`, `ForEach(_:editActions:content:)`, "
     "`List(_:editActions:rowContent:)`: `Binding` is not a `RandomAccessCollection` in Isomer and `ForEach`/`List` "
     "take no `Binding<C>`. Scrumdinger is built on this pattern."),
    ("List editing.",
     "`.onDelete(perform:)` exists but is never called (shared/swift_ui_core/ForEach.swift:68); `.onMove(perform:)`, "
     "`EditButton`, `EditMode` / `\\.editMode`, `.deleteDisabled`, `.moveDisabled`, and the collection helpers the "
     "handlers call (`remove(atOffsets:)`, `move(fromOffsets:toOffset:)`) are missing. Landmarks and "
     "Scrumdinger both edit lists; Skip: full for onDelete/onMove."),
    ("Style protocols.",
     "`ButtonStyle` (+ `ButtonStyleConfiguration`), `PrimitiveButtonStyle`, `LabelStyle`, `ToggleStyle` and "
     "`.toggleStyle(_:)`, `ProgressViewStyle` and `.progressViewStyle(_:)`, `TextFieldStyle`, and the instance "
     "spellings `PlainButtonStyle()` (a/o 0/6), `PlainListStyle()` (0/4). Isomer's `buttonStyle`/`listStyle`/"
     "`labelStyle`/`textFieldStyle` take fixed option structs, so `.buttonStyle(.bordered)` compiles but any custom "
     "style does not. Scrumdinger defines a custom `LabelStyle` and `ProgressViewStyle`."),
    ("Gestures beyond tap and drag.",
     "`TapGesture`, `LongPressGesture`, `.onLongPressGesture(minimumDuration:maximumDistance:perform:onPressingChanged:)`, "
     "`@GestureState` with `Gesture.updating(_:body:)`, `.simultaneousGesture(_:including:)`, "
     "`.highPriorityGesture(_:including:)`, `Gesture.onChanged/onEnded/sequenced/exclusively/map` for any gesture. "
     "Skip: high for `TapGesture`, `LongPressGesture`, `onLongPressGesture`, `simultaneousGesture`."),
    ("Formatted text.",
     "`Text(_:format:)`, `Text(_:style:)` with `Text.DateStyle`, interpolation `\"\\(value, format: ...)\"` and "
     "`\"\\(value, specifier: \"%.1f\")\"`, `TextField(_:value:format:prompt:)`, `LabeledContent(_:value:format:)`. "
     "Numbers, dates and currency appear in nearly every app; Scrumdinger uses `Text(date, style: .date)`."),
    ("`Text(AttributedString)`.",
     "Attributed/markdown text built at run time (`AttributedString(markdown:)`). Isomer renders inline markdown of "
     "literal keys only; agent_ui's portable path shows such text unstyled (agent_ui/Sources/AgentUI/MarkdownText.swift)."),
    ("Text and font modifiers on any view; custom fonts.",
     "`.fontWeight`, `.italic`, `.monospaced`, `.underline`, `.strikethrough` exist only on `Text` (so not on a "
     "`Label`, `Button` or container); `.fontDesign`, `.kerning`, `.tracking`, `.monospacedDigit`, "
     "`.minimumScaleFactor`, `.allowsTightening`, `.baselineOffset` are missing; `Font.custom(_:size:)`, "
     "`Font.custom(_:size:relativeTo:)`, `Font.system(_:design:weight:)`, `Font.italic()`, `Font.monospacedDigit()` and "
     "`Font.TextStyle` are missing. Skip: full for italic, monospaced, tracking, minimumScaleFactor."),
    ("Environment values.",
     "Missing: `locale`, `timeZone`, `calendar`, `openURL` (+ `OpenURLAction`), `isPresented`, `isSearching`, "
     "`dismissSearch`, `editMode`, `layoutDirection`, `dynamicTypeSize`, `accessibilityReduceMotion`, and the `@Entry` "
     "macro for custom keys. Several (font, lineLimit, tint) are stored internally but not public."),
    ("`matchedGeometryEffect` and `@Namespace`; real transitions.",
     "Hero animations need both; `.transition(_:)` is accepted and ignored (Modifiers.swift:868), "
     "`withAnimation(_:completionCriteria:_:completion:)` (completion callbacks) is missing."),
    ("Shape strokes and basic shapes.",
     "`Ellipse`, `StrokeStyle`, `Shape.stroke(_:style:)` / `stroke(style:)` / `stroke(lineWidth:)`, "
     "`InsettableShape.strokeBorder(...)`, `Shape.rotation(_:anchor:)`; `stroke` takes only a `Color`; `clipShape` "
     "accepts only `RoundedRectangle`, `Circle`, `Capsule`. Scrumdinger uses `strokeBorder` and `rotation`."),
    ("Path construction.",
     "`Path.addArc(center:radius:startAngle:endAngle:clockwise:)`, `addQuadCurve(to:control:)`, "
     "`addCurve(to:control1:control2:)`. Landmarks draws its badge with these; Scrumdinger its speaker arcs."),
    ("Gradients and styles as `ShapeStyle` values.",
     "`.linearGradient(colors:startPoint:endPoint:)`, `.radialGradient(...)` statics, `Color.gradient`, `.tint` as "
     "a style; `.foregroundStyle`/`.tint`/`.border` with gradients or hierarchical styles beyond Color."),
    ("Layout essentials.",
     "`.zIndex(_:)`, `.layoutPriority(_:)`, `.offset(_ offset: CGSize)`, `.scaledToFit()`/`.scaledToFill()` on any "
     "view (Isomer: `Image` only), `ViewThatFits`, `.coordinateSpace(_:)`; `GeometryProxy.frame(in:)` returns a frame "
     "at the origin whatever the space (Components.swift:86)."),
    ("Preferences.",
     "`PreferenceKey`, `.preference(key:value:)`, `.onPreferenceChange(_:perform:)`: the standard child-to-parent "
     "channel (and how views report measured sizes). Skip: full."),
    ("Visual effects and hit testing.",
     "`.blur(radius:)`, `.mask(alignment:_:)` (and the older `.mask(_:)`), anchors on `.scaleEffect(_:anchor:)` / `.rotationEffect(_:anchor:)`, "
     "`.scaleEffect(x:y:)`; `.allowsHitTesting(false)` is a no-op (Modifiers.swift:861), so an overlay marked "
     "with it is not made transparent to taps."),
    ("`.onReceive(_:perform:)`.",
     "Combine publishers (`Timer.publish`, NotificationCenter). Visor guards its use; a/o 2/4; Skip: full."),
    ("Toolbar composition and bar visibility.",
     "`ToolbarContent` / `@ToolbarContentBuilder` (toolbar items factored into properties), "
     "`.toolbarVisibility(_:for:)` (hide a tab or navigation bar), `.navigationBarBackButtonHidden(_:)`, "
     "`.badge(_:)` (tab and row badges); `.toolbarBackground(_:for:)` is a no-op and has no `ShapeStyle` form."),
    ("Control initializers.",
     "`DatePicker` takes only `(_:selection:)`: no `displayedComponents:`, `in:` range, or label closure "
     "(Landmarks' profile editor uses all three); `Picker(selection:content:label:)`, "
     "`Slider(value:in:step:label:onEditingChanged:)`, `Stepper(value:in:step:label:)`, `Toggle(_:systemImage:isOn:)`, "
     "`Menu(_:systemImage:content:)`, `ProgressView(value:total:label:)`; `Slider` is `Double`-only."),
    ("`AsyncImage` phases.",
     "`AsyncImage(url:scale:transaction:content:)` with `AsyncImagePhase` (`.empty`/`.success`/`.failure`) for "
     "loading and error states; Isomer has only the content/placeholder form."),
    ("Image rendering options.",
     "`Image.renderingMode(_:)` (`.template`/`.original`), `.imageScale(_:)` and `Image.Scale`, "
     "`.symbolRenderingMode(_:)`, the `bundle:` argument of `Image(_:bundle:)`."),
    ("Property-wrapper forms.",
     "`@State var x: T?` with no initial value (`State.init()` for optionals), `@ScaledMetric`, `@SceneStorage`, "
     "`Binding.animation(_:)`."),
    ("Search plumbing.",
     "`.onSubmit(of: .search)`, `\\.isSearching`, `\\.dismissSearch`; `.searchable`'s `placement` is ignored "
     "(Components.swift:624)."),
    ("Desktop and web input.",
     "`.keyboardShortcut(_:modifiers:)` (a/o 4/0), `.onHover(perform:)`, `.help(_:)`, `.focusable(_:)`: Isomer ships "
     "on web, Electron and desktop hosts, where these are expected."),
    ("Scroll and list chrome.",
     "`.scrollIndicators(_:axes:)`, `.scrollContentBackground(_:)` (the usual way to restyle a `List`/`Form` "
     "background). Skip: full for `scrollContentBackground`."),
    ("`.textContentType(_:)`.",
     "Autofill for usernames, passwords and one-time codes on sign-in forms (Visor's password field). Skip: high."),
    ("Sheet sizes.",
     "`PresentationDetent.fraction(_:)`, `.height(_:)`, `.custom(_:)`, and `presentationDetents(_:selection:)`; "
     "only `.medium`/`.large` reach the host (Presentations.swift:146)."),
    ("Scenes beyond one `WindowGroup` (desktop).",
     "Isomer's `Scene` has no `body`, so no `SceneBuilder` composition, `Settings`, `Window`, `DocumentGroup`, "
     "`MenuBarExtra`, and none of the 33 scene modifiers (`.commands`, `.defaultSize`, `.onChange`, `.environment`, "
     "`.windowStyle`). Landmarks' macOS chapter uses `Settings` and `.commands` with `CommandMenu`. "
     "(Section 3 files most of these as P2/P3 by its platform rule; they are P1 for Isomer's desktop hosts.)"),
]

AREA_NOTES = {
    "Lists, tables & collections":
        "Present: `List` (content, data, id, single selection), `ForEach` (data, id, `Range<Int>`), `Section` (header/footer "
        "forms), `OutlineGroup`, `DisclosureGroup`, `.listStyle` (option values), `.listRowInsets`/`.listRowBackground`/"
        "`.listRowSeparator`, `.swipeActions`, `.refreshable`. SwiftUI declares `.onDelete`, `.onMove`, `.onInsert` and "
        "`.dropDestination` for rows on `DynamicViewContent` (the protocol `ForEach` conforms to), so they appear here under "
        "that type; Isomer declares an inert `onDelete` directly on `ForEach`.",
    "Controls, input & styles":
        "Isomer spells styles as option structs (`ButtonStyleOption`, `ListStyleOption`, `LabelStyleOption`, "
        "`TextFieldStyleOption`, `PickerStyle`, `TabViewStyle`, `FormStyle`) with SwiftUI's static names, so "
        "`.buttonStyle(.borderedProminent)` compiles; the style protocols and concrete style types do not exist. "
        "Control titles are `String` (Apple: `LocalizedStringKey`/`StringProtocol`/`Text`).",
    "Navigation, toolbars & tabs":
        "Present: `NavigationStack(root:)`, `NavigationSplitView` (all eight initializers), `NavigationLink(destination:label:)` "
        "and `(_:destination:)`, `TabView(selection:)`, `Tab`/`TabSection`, `ToolbarItem`/`ToolbarItemGroup`/`ToolbarSpacer`/"
        "`DefaultToolbarItem`, most `ToolbarItemPlacement`s (incl. `.principal`, `.bottomBar`, `.keyboard`).",
    "Presentation & dialogs":
        "Present: `sheet(isPresented:content:)`, `fullScreenCover(isPresented:content:)`, `popover(isPresented:content:)`, "
        "`alert(_:isPresented:actions:message:)`, `confirmationDialog(_:isPresented:titleVisibility:actions:message:)`, "
        "`inspector`, `presentationDetents` (medium/large), `presentationDragIndicator`, `interactiveDismissDisabled`.",
    "Animation & transitions":
        "Present: `withAnimation(_:_:)`, `withTransaction(_:_:)`, `.animation(_:)`, `.animation(_:value:)` (value must be "
        "`Hashable`, Apple: `Equatable`), `Animation` curves with `delay`/`speed`/`repeatCount`/`repeatForever`, the "
        "named springs (approximated), `AnyTransition` values (inert).",
    "Gestures & pointer":
        "Present: `.onTapGesture(count:perform:)`, `.gesture(_:including:)` (mask ignored), `DragGesture`, `MagnifyGesture`, "
        "`MagnificationGesture`, `Gesture.simultaneously(with:)`, plus Isomer's own `.swipeGesture(onChanged:onEnded:)`.",
    "State, data flow & lifecycle":
        "Present: `@State`, `@Binding` (with `Binding(get:set:)`, `.constant`, dynamic-member projection), `@StateObject`, "
        "`@ObservedObject`, `@EnvironmentObject` (their `$model.property` bindings go through Isomer's `_ObservedBindings`, "
        "so only the `Wrapper` type names are missing), `@Environment` (key path and `@Observable` type forms), "
        "`@Bindable`, `@AppStorage`, `@FocusState`, `ViewModifier`/`.modifier`, `.environment`, `.environmentObject`, "
        "`.onAppear`/`.onDisappear`, `.onChange(of:initial:_:)`, `.task(id:priority:_:)`, `.id`, `.tag`.",
    "Environment values":
        "Readable today: `colorScheme`, `dismiss`, `displayScale`, `horizontalSizeClass`, `verticalSizeClass`, `isEnabled`, "
        "`isScrollEnabled`, `refresh`, `scenePhase`, `defaultMinListRowHeight`, and custom keys through "
        "`EnvironmentValues[_:]`/`EnvironmentKey`. `@Environment(Model.self)` works for `@Observable` models.",
    "Scenes, windows & app":
        "Isomer's `Scene` protocol has only `_makeRootView()`; `App.body` is a single `WindowGroup` (with an optional title).",
    "Shapes, colors & graphics":
        "Present: `Rectangle`, `RoundedRectangle`, `Circle`, `Capsule`, custom `Shape` "
        "via `path(in:)`, `Path` with move/line/rect/rounded-rect/ellipse/closeSubpath and an SVG-ish string form, "
        "the `.rect`/`.rect(cornerRadius:)`/`.capsule`/`.circle` shorthands, `fill` (Color or ShapeStyle), `stroke(Color, lineWidth:)`, `trim`, `Color` (named colors, `opacity`, RGB/white "
        "initializers), `LinearGradient`/`RadialGradient`/`AngularGradient`, `Material`, `Glass`.",
    "Text & fonts":
        "Present: `Text(_:)` (StringProtocol, LocalizedStringKey with inline markdown, `Image`), `Text(verbatim:)`, `+` "
        "concatenation, `Text.bold/italic/underline/strikethrough/monospaced/fontWeight/font/foregroundStyle`, "
        "`Font.system(size:weight:design:)`, the text styles, `Font.weight`, `Font.bold`, `Font.monospaced`, "
        "`.lineLimit` (Int and closed range), `.lineSpacing`, `.multilineTextAlignment`, `.truncationMode`, `.textCase`, "
        "`.textSelection`.",
}

TYPE_GAPS_INTRO = """\
The label comparison counts these as present, but the argument types Isomer accepts are narrower than
SwiftUI's, so ordinary call sites still fail to compile (found by normalizing parameter types and checked by hand)."""

TYPE_GAPS = [
    ("`ForEach(_:content:)`, `ForEach(_:id:content:)`, `List(_:rowContent:)`:",
     "no `Binding<C>` data (`ForEach($items) { $item in }`); `Binding` has no collection conformance "
     "(shared/swift_ui_core/ForEach.swift:27-44)."),
    ("`Text(_:)`:", "no `AttributedString`, `Date` range (`ClosedRange<Date>`) or `DateInterval` overloads."),
    ("`stroke(_:lineWidth:)`, `border(_:width:)`, `tint(_:)`:",
     "take `Color` only (Shapes.swift:40, Modifiers.swift:490, Modifiers.swift:345); SwiftUI takes any `ShapeStyle` "
     "(gradients, `.tint`, `.secondary`)."),
    ("`buttonStyle(_:)`, `listStyle(_:)`, `textFieldStyle(_:)`, `labelStyle(_:)`:",
     "take Isomer option structs; `PlainButtonStyle()`, `.buttonStyle(MyStyle())` and every custom style fail."),
    ("`clipShape(_:)`:", "three overloads (`RoundedRectangle`, `Circle`, `Capsule`), Modifiers.swift:461-473; no "
     "generic `Shape` (`Rectangle`/`.rect`, `Ellipse`, `UnevenRoundedRectangle`, custom paths); `.rect(cornerRadius:)` works."),
    ("`animation(_:value:)`:", "requires `Hashable` values (Animation.swift:224); SwiftUI requires `Equatable`."),
    ("`safeAreaInset(edge:alignment:spacing:content:)` / `safeAreaBar`:",
     "`VerticalEdge` only; the `HorizontalEdge` overload (leading/trailing insets) is missing, and `alignment` is ignored."),
    ("`lineLimit(_:)`:", "no `PartialRangeFrom`/`PartialRangeThrough` forms (`.lineLimit(3...)`)."),
    ("`Slider(value:in:)`, `Stepper`:", "`Binding<Double>`/`Binding<Int>` only (SwiftUI: any `BinaryFloatingPoint`/"
     "`Strideable`), so `Float`/`CGFloat` bindings fail."),
    ("`List(selection:content:)`:", "single selection only; no `Binding<Set<ID>>` multi-selection."),
    ("`navigationTitle(_:)`:", "`String`/`Text`; no `Binding<String>` (editable, renamable titles)."),
    ("`toolbarBackground(_:for:)`:", "`Visibility` only, and a no-op; no `ShapeStyle` overload "
     "(`.toolbarBackground(.blue, for: .navigationBar)`)."),
    ("`transition(_:)`:", "`AnyTransition` only (no `some Transition`), and a no-op."),
    ("`searchable(text:placement:prompt:)`:", "`prompt` is a `String` (SwiftUI: `Text?`/`LocalizedStringKey`)."),
    ("`dropDestination(for:action:isTargeted:)`, `PhotosPickerItem.loadTransferable(type:)`:",
     "deliver only `URL` or `Data` (files), whatever `Transferable` type is asked for (Pickers.swift:86, :209)."),
    ("Controls' titles (`Button`, `Toggle`, `TextField`, `Picker`, `Menu`, ...):",
     "`String` only; a `Text` title or a `Substring` does not compile (SwiftUI: `LocalizedStringKey`, "
     "`some StringProtocol`, `Text`)."),
]

NOOPS_INTRO = """\
Read from the code (comments such as "accepted for source compatibility", "no-op") and from a scan for public
functions that ignore arguments. Line numbers are as of the audit (working tree of cffc3ef; another session had
uncommitted edits in Navigation.swift that add no public API)."""

NOOPS = [
    ("`.onDelete(perform:)`", "shared/swift_ui_core/ForEach.swift:68: returns `self`; the handler is never called "
     "(no swipe-to-delete in the component renderers)."),
    ("`.transition(_:)`", "Modifiers.swift:868: returns `self`; views appear and disappear at once. All "
     "`AnyTransition` builders (Modifiers.swift:872-889) only record a name; `AnyTransition.animation(_:)` returns `self`."),
    ("`.allowsHitTesting(_:)`", "Modifiers.swift:861: returns `self` (\"`.disabled` is the functional stand-in\"), so `.allowsHitTesting(false)` does "
     "not make a view transparent to taps."),
    ("`.contentShape(_:)`", "Modifiers.swift:677: returns `self`; every view's bounds are hit-testable, so "
     "non-rectangular shapes are approximated by their bounds."),
    ("`.toolbarBackground(_:for:)`, `.toolbarBackgroundVisibility(_:for:)`", "TabContent.swift:456-457: return `self`."),
    ("`.submitLabel(_:)`", "Modifiers.swift:341: returns `self` (return-key label not passed to hosts)."),
    ("`.formStyle(_:)`", "Form.swift:205: returns `self`."),
    ("`.accessibilityAddTraits(_:)`, `.accessibilityRemoveTraits(_:)`", "Modifiers.swift:407-408: return `self`."),
    ("`.ignoresSafeArea(_:edges:)`", "Modifiers.swift:413: regions and edges ignored; every edge is extended."),
    ("`.gesture(_:including:)`", "Gesture.swift:155: the `GestureMask` is ignored."),
    ("`.searchable(text:placement:prompt:)`", "Components.swift:624: `placement` ignored."),
    ("`.confirmationDialog(..., titleVisibility:)`", "Presentations.swift:108, :122: `titleVisibility` ignored; drawn as an alert-shaped panel."),
    ("`.presentationDetents(_:)`", "Presentations.swift:144-149: only `.medium` and `.large` are passed to the host."),
    ("`.frame(minWidth:idealWidth:...)`", "Modifiers.swift:183: `idealWidth`/`idealHeight` ignored."),
    ("`.safeAreaInset(edge:alignment:...)`, `.safeAreaBar`", "Navigation.swift:1405, :1414: `alignment` ignored."),
    ("`.inspectorColumnWidth(min:ideal:max:)`, `.navigationSplitViewColumnWidth(min:ideal:max:)`",
     "Modifiers.swift:301, Navigation.swift:524: `min`/`max` accepted for source compatibility only."),
    ("`GeometryProxy.frame(in:)`", "Components.swift:86: always `CGRect(origin: .zero, size: size)`; no global or "
     "named coordinate spaces."),
    ("`Animation.spring(...)`, `.smooth`, `.snappy`, `.bouncy`", "Animation.swift:84-104: ease-out curves; "
     "`dampingFraction`, `bounce`, `blendDuration`, `extraBounce` ignored."),
    ("`DragGesture(minimumDistance:coordinateSpace:)`", "Gesture.swift:61: `coordinateSpace` ignored."),
    ("`MagnifyGesture(minimumScaleDelta:)`, `MagnificationGesture(minimumScaleDelta:)`", "Gesture.swift:91, :121: ignored."),
    ("`LazyVGrid`/`LazyHGrid(pinnedViews:)`", "Grid.swift:32, :52: pinned section headers/footers ignored "
     "(and `LazyVStack`/`LazyHStack` take no `pinnedViews:`)."),
    ("`RoundedRectangle(cornerRadius:style:)`, `Path.addRoundedRect(...style:)`", "Shapes.swift:90, :177: "
     "`style` (continuous vs circular) ignored."),
    ("`Text.underline(_:color:)`, `Text.strikethrough(_:color:)`", "Text.swift:87, :93: `color` ignored."),
    ("`GlassEffectContainer(spacing:)`", "Material.swift:117: `spacing` ignored (no glass merging)."),
    ("`Image(_:scale:orientation:label:)` (CGImage)", "Image+CGImage.swift:13-19: `scale` and `orientation` ignored."),
]
NOOPS_COVERED = {
    # benign: type-only generic parameters, shape-specific overloads whose shape carries no data, internal hooks
    "shared/swift_ui_core/LocalizedStringKey.swift:45", "shared/swift_ui_core/Modifiers.swift:467",
    "shared/swift_ui_core/Modifiers.swift:471", "shared/swift_ui_core/ObservationSupport.swift:85",
    "shared/swift_ui_core/ObservationSupport.swift:99", "shared/swift_ui_core/ScrollGeometry.swift:41",
    "shared/swift_ui_core/VideoPlayer.swift:17",
    "shared/swift_ui_core/ForEach.swift:68", "shared/swift_ui_core/Modifiers.swift:868", "shared/swift_ui_core/Modifiers.swift:861",
    "shared/swift_ui_core/Modifiers.swift:677", "shared/swift_ui_core/TabContent.swift:456", "shared/swift_ui_core/TabContent.swift:457",
    "shared/swift_ui_core/Modifiers.swift:341", "shared/swift_ui_core/Form.swift:205", "shared/swift_ui_core/Modifiers.swift:407",
    "shared/swift_ui_core/Modifiers.swift:408", "shared/swift_ui_core/Modifiers.swift:413", "shared/swift_ui_core/Gesture.swift:155",
    "shared/swift_ui_core/Components.swift:624", "shared/swift_ui_core/Modifiers.swift:183", "shared/swift_ui_core/Modifiers.swift:301",
    "shared/swift_ui_core/Components.swift:86", "shared/swift_ui_core/Animation.swift:84", "shared/swift_ui_core/Animation.swift:89",
    "shared/swift_ui_core/Animation.swift:95", "shared/swift_ui_core/Animation.swift:99", "shared/swift_ui_core/Animation.swift:103",
    "shared/swift_ui_core/Gesture.swift:61", "shared/swift_ui_core/Gesture.swift:91", "shared/swift_ui_core/Gesture.swift:121",
    "shared/swift_ui_core/Grid.swift:32", "shared/swift_ui_core/Grid.swift:52", "shared/swift_ui_core/Shapes.swift:90",
    "shared/swift_ui_core/Shapes.swift:177", "shared/swift_ui_core/Text.swift:87", "shared/swift_ui_core/Text.swift:93",
    "shared/swift_ui_core/Material.swift:117", "shared/swift_ui_core/Image+CGImage.swift:13", "shared/swift_ui_core/Image+CGImage.swift:19",
    "shared/swift_ui_core/Modifiers.swift:879", "shared/swift_ui_core/Modifiers.swift:880", "shared/swift_ui_core/Modifiers.swift:881",
    "shared/swift_ui_core/Modifiers.swift:882", "shared/swift_ui_core/Modifiers.swift:883", "shared/swift_ui_core/Modifiers.swift:888", "shared/swift_ui_core/Navigation.swift:1405", "shared/swift_ui_core/Navigation.swift:1414", "shared/swift_ui_core/Navigation.swift:1399", "shared/swift_ui_core/Navigation.swift:1408",
    "shared/swift_ui_core/Pickers.swift:86", "shared/swift_ui_core/Pickers.swift:209",
}

SOFT_DEP = """\
Apple marks these `deprecated: 100000` (to be deprecated, no version yet). They still compile without warnings in
most projects and older code is full of them, so a reimplementation that wants to run existing code needs the
common ones. Isomer has `foregroundColor`, `cornerRadius`, `edgesIgnoringSafeArea`, `overlay(_:alignment:)`,
`background(_:alignment:)`, `onChange(of:perform:)` (hard-deprecated, also present); it lacks
`navigationBarTitle` (0/29 in the older code), `navigationBarItems` (0/13), `navigationViewStyle` (0/6),
`navigationBarHidden`, `statusBar(hidden:)`, `accentColor`, `autocapitalization`, `disableAutocorrection` and the
old `alert(isPresented:content:)`/`Alert` and `actionSheet` forms."""

METHOD = """\
1. **Apple's interface.** `/tmp/swiftui_audit/swiftdecl.py` reads `.swiftinterface` text: it strips comments and
   string contents, keeps every `#if` branch, tracks braces to find type/extension bodies (skipping function and
   accessor bodies), splits declaration headers, and records kind, name, argument labels (from the parameter
   clause; defaulted and closure parameters noted), generic constraints, the enclosing type/extension, and
   `@available` attributes inherited from the enclosing declarations. Module selectors (`SwiftUICore::View`,
   `SwiftUI.View`, `Swift.Bool`) are stripped. Inputs: SwiftUI and SwiftUICore, `arm64e-apple-ios` from the
   iPhoneOS SDK and `arm64e-apple-macos` from the MacOSX SDK (Xcode 27.0). A record counts for a platform unless
   that platform (or `*`) says `unavailable`/`obsoleted`; records are then merged across platform and module by
   (kind, qualified name, labels). Overloads that differ only in argument types merge into one signature.
2. **Isomer.** The same parser over the `SwiftUI` module's sources: `shared/swift_ui_core/*.swift`,
   `shared/renderers/*.swift`, `wasm/libraries/swift_ui/{WasmHost,WebBridge}.swift`,
   `android/libraries/swift_ui/{AndroidBridge,AndroidHost}.swift` (public/open declarations, members of
   `public extension`s, protocol requirements, enum cases; members of non-public types excluded). `shared/swift_ui_extensions`,
   `shared/platform_services` and the two `IsomerBridge.swift` files are separate modules and are not counted.
   Declarations marked `@available(*, unavailable)` count as absent.
3. **Matching** (`compare.py`). Types by qualified name. Members by container and base name; a SwiftUI signature is
   *present* if some Isomer overload can be called with SwiftUI's full label list (Isomer may have extra defaulted
   parameters; the first of a trailing run of closures may be unlabeled), *partial* if only a shorter call form
   works (a defaulted SwiftUI argument Isomer lacks), else *missing*. View modifiers SwiftUI declares on `View` that
   Isomer declares only on `Text`/`Image`/`Shape` count as partial. Static members of
   `extension ShapeStyle where Self == X` also match members of `X`; SwiftUI style protocols also match Isomer's
   `*StyleOption` structs. Enum cases and static properties match each other by name.
4. **Priorities** (`classify.py`). P1 from a curated list grounded in Apple's tutorials, SkipUI's support table
   (`~/Developer/skiptools/skip-ui/README.md`, 220 entries) and usage; any whole-missing API used 3+ times in either
   corpus is P1. Secondary overloads of P1 modifiers (`isEnabled:`, `name:`, `fillStyle:`, token search, ...) are P2.
   P3: macOS- or iOS-only API, API introduced in the 26/27 SDKs, accessibility rotors, window/document/Touch Bar
   API, GraphicsContext, Table, keyframes, shaders and similar. Everything else P2.
5. **Usage** (`usage.py`). Regex counts (`.name(` for modifiers, the type name, `\\.key` for environment values) over
   .swift files that `import SwiftUI`, comments and strings stripped, vendored/build directories excluded:
   "apps" = apps written on Isomer (visor, agent_ui, visor_isomer, isomer's examples and others, about 250 files);
   "old" = older native SwiftUI apps, examples and forks (179 files). Counts are approximate (name collisions).
6. **OpenSwiftUI** (`~/Developer/OpenSwiftUI/Sources/{OpenSwiftUI,OpenSwiftUICore}`) parsed the same way for the
   `OSUI` column (public declarations only; its availability macros are ignored).
7. **No-ops** (`noops.py`): public functions whose body is empty, returns `self`, or never reads a parameter,
   plus a read of comments like "accepted for source compatibility"; each listed item was checked by hand."""

LIMITS = """\
Limitations:

- Names and labels, not types: an overload Isomer has with narrower argument types counts as present (section 4
  lists the ones found). Conversely a SwiftUI overload set that differs only by type collapses into one signature.
- Presence is not behaviour: section 5 lists what was seen to be inert, but no renderer was run.
- Priorities are judgement. The app corpora are small and the Isomer-era apps avoid what Isomer lacks; the older
  corpus predates most iOS 16+ API.
- Not covered: the cross-import overlays (`_MapKit_SwiftUI`, `_AVKit_SwiftUI`, `_PhotosUI_SwiftUI`,
  `_StoreKit_SwiftUI`, `_WebKit_SwiftUI`, `_SwiftData_SwiftUI`, ...), which Isomer partly reimplements (`Map`,
  `VideoPlayer`, `photosPicker`, `WebView` in SwiftUIExtensions); Charts; Observation, Combine
  (`ObservableObject`/`Published` are in Isomer's module), Foundation and CoreTransferable types.
- Raw data: `/tmp/swiftui_audit/results.json` (every SwiftUI item with its Isomer/OpenSwiftUI status),
  `/tmp/swiftui_audit/gaps_full.tsv` (every gap, including members of missing types, with signatures, priority,
  area, platforms, availability and usage). Rerun with `python3 extract_all.py && python3 compare.py &&
  python3 usage.py && python3 noops.py && python3 report.py` in that directory."""

ISO_ONLY_INTRO = """\
Public, non-underscored names in Isomer's `SwiftUI` module that SwiftUI/SwiftUICore do not declare. Most are
framework plumbing (renderers, host bridges), stand-ins for other Apple frameworks Isomer folds into its module
(Foundation/CoreGraphics skims, Dispatch, Combine's `ObservableObject`/`Published`, `UTType`, `Transferable`,
`UIPasteboard`, MapKit's `Map`, AVKit's `VideoPlayer`, PhotosUI's picker types), or Isomer-specific API
(`PlatformViewRepresentable` and its per-platform refinements, `IsomerHostingController`, `swipeGesture`,
`cameraCapture`, the `*StyleOption` structs)."""
