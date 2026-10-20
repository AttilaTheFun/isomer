"""Area and priority classification for audit items (used by report.py)."""
import re

TYPE_KINDS = {"struct", "class", "enum", "protocol", "typealias", "actor"}

# ---------------------------------------------------------------- areas ----
MOD_AREAS = [
    ("Accessibility", r"^(accessibility|speech)"),
    ("Navigation, toolbars & tabs", r"^(navigation|toolbar|tabView|tabItem|tabBar|tabViewStyle|statusBar|persistentSystemOverlays|defaultTab)"),
    ("Presentation & dialogs", r"^(sheet|fullScreenCover|popover|alert|confirmationDialog|inspector|presentation|interactiveDismissDisabled|dialog|onDismiss)"),
    ("Files, drag & drop, transfer & sharing", r"^(fileImporter|fileExporter|fileMover|fileDialog|draggable|dropDestination|onDrag|onDrop|copyable|cuttable|pasteDestination|itemProvider|springLoading|exportable|importable|drag|onCopyCommand|onCutCommand|onPasteCommand|documentBrowser)"),
    ("Lists, tables & collections", r"^(list|onDelete|onMove|onInsert|deleteDisabled|moveDisabled|swipeActions|editActions|selectionDisabled|table|headerProminence|badge|sectionActions|disclosureGroupStyle|outline)"),
    ("Scrolling", r"^(scroll|contentMargins|defaultScrollAnchor|onScroll|refreshable)"),
    ("Search", r"^(search)"),
    ("Focus, keyboard & commands", r"^(focus|focused|defaultFocus|prefersDefaultFocus|onKeyPress|keyboardShortcut|onMoveCommand|onExitCommand|onCommand|onDeleteCommand|typeSelect|onModifierKeysChanged)"),
    ("Gestures & pointer", r"^(gesture|onTapGesture|onLongPressGesture|onLongTouchGesture|simultaneousGesture|highPriorityGesture|onHover|onContinuousHover|hoverEffect|defaultHoverEffect|pointer|contentShape|allowsHitTesting|defersSystemGestures|onPencil|handPointerBehavior|allowsWindowActivationEvents)"),
    ("Animation & transitions", r"^(animation|transition|matchedGeometryEffect|matchedTransitionSource|navigationTransition|contentTransition|phaseAnimator|keyframeAnimator|transaction|geometryGroup|glassEffectTransition|scrollTransition)"),
    ("Images & symbols", r"^(symbol|imageScale|allowedDynamicRange|resizable|renderingMode|interpolation|antialiased)"),
    ("Text & fonts", r"^(font|bold|italic|underline|strikethrough|kerning|tracking|baselineOffset|lineLimit|lineSpacing|lineHeight|multilineTextAlignment|truncationMode|minimumScaleFactor|allowsTightening|textCase|textSelection|monospaced|dynamicTypeSize|textScale|typesettingLanguage|writingDirection|textRenderer|flipsForRightToLeft|attributedTextFormatting|textVariant)"),
    ("Controls, input & styles", r"^(textContentType|keyboardType|textInput|autocorrection|disableAutocorrection|submitLabel|onSubmit|submitScope|textFieldStyle|textEditorStyle|writingTools|findNavigator|findDisabled|replaceDisabled|.*Style$|labelsHidden|labelsVisibility|controlSize|buttonBorderShape|buttonRepeatBehavior|buttonSizing|menuIndicator|menuOrder|menuActionDismissBehavior|help|datePicker|digitalCrown|horizontalRadioGroupLayout|labelIcon|labelReservedIconWidth|gaugeStyle|tint|accentColor|textEditor)"),
    ("Layout & geometry", r"^(frame|padding|offset|position|fixedSize|layoutPriority|alignmentGuide|aspectRatio|scaledToFit|scaledToFill|ignoresSafeArea|safeArea|containerRelativeFrame|layoutValue|zIndex|coordinateSpace|onGeometryChange|layoutDirectionBehavior|containerShape|grid|containerValue|edgesIgnoringSafeArea|containerCornerOffset)"),
    ("Appearance & visual effects", r"^(background|overlay|foreground|opacity|shadow|blur|border|cornerRadius|clipShape|clipped|mask|brightness|contrast|saturation|grayscale|hueRotation|colorInvert|colorMultiply|luminanceToAlpha|blendMode|compositingGroup|drawingGroup|visualEffect|colorEffect|distortionEffect|layerEffect|scaleEffect|rotationEffect|rotation3DEffect|transformEffect|projectionEffect|glassEffect|preferredColorScheme|colorScheme|materialActiveAppearance|redacted|unredacted|privacySensitive|hidden|containerBackground|backgroundStyle|backgroundExtensionEffect|tabViewBottomAccessory|imageScale)"),
    ("Menus & context menus", r"^(contextMenu|menu)"),
    ("Scenes, windows & app", r"^(window|scene|openWindow|onOpenURL|handlesExternalEvents|userActivity|onContinueUserActivity|defaultAppStorage|commands|touchBar|focusedSceneValue|focusedSceneObject|immersive|supportedVolume|defaultLaunchBehavior|restorationBehavior)"),
    ("State, data flow & lifecycle", r"^(environment|transformEnvironment|preference|onPreferenceChange|transformPreference|anchorPreference|transformAnchorPreference|overlayPreferenceValue|backgroundPreferenceValue|onChange|onReceive|task|onAppear|onDisappear|id$|tag$|equatable|modifier|sensoryFeedback|modelContainer|onSubmit|tag)"),
]
MOD_AREAS = [(a, re.compile(rx)) for a, rx in MOD_AREAS]

TYPE_AREAS = [
    ("Environment values", r"^EnvironmentValues$"),
    ("Accessibility", r"^(Accessibility|AXChart)"),
    ("Scenes, windows & app", r"^(NewDocumentButton|InterfaceOrientation|Scene|App$|WindowGroup|Window|Settings|SettingsLink|DocumentGroup|MenuBarExtra|UtilityWindow|AlertScene|Commands|CommandMenu|CommandGroup|EmptyCommands|SidebarCommands|ToolbarCommands|TextEditingCommands|TextFormattingCommands|ImportFromDevicesCommands|InspectorCommands|ScenePhase|OpenWindowAction|DismissWindowAction|PushWindowAction|OpenDocumentAction|NewDocumentAction|OpenSettingsAction|SceneStorage|DocumentConfiguration|FileDocument|ReferenceFileDocument|DocumentLaunch|SceneRestoration|SceneLaunch|WindowResizability|WindowStyle|WindowToolbarStyle|WindowLevel|WindowPlacement|WindowProxy|WindowLayoutRoot|DefaultWindow|HiddenTitleBar|TitleBarWindowStyle|TitleOnlyWindowToolbarStyle|UnifiedWindowToolbarStyle|ExpandedWindowToolbarStyle|UnifiedCompactWindowToolbarStyle|MenuBarExtraStyle|WindowMenuBarExtraStyle|PullDownMenuBarExtraStyle|AutomaticMenuBarExtraStyle|DismissBehavior|WindowVisibilityToggle|WindowInteractionBehavior|WindowManagerRole|BackgroundTask|SceneBuilder|DocumentBaseBox|ExternalEvents|OpenURLAction|DragDropPreviewsFormation|SceneLaunchBehavior|WindowLevel|WindowIdealSize)"),
    ("Presentation & dialogs", r"^(\w*PresentationSizing|CustomPresentationDetent|Presentation|DismissAction|Alert|ConfirmationDialog|Dialog|Popover|SheetPresentation|Inspector|PresentedWindowContent)"),
    ("Files, drag & drop, transfer & sharing", r"^(ShareLink|SharePreview|PasteButton|Transferable|Drag(?!Gesture)|Drop|EditableCollectionContent|FileDialog|FileExport|FileImport|ItemProvider|Copy|Cut|Paste|DocumentBrowser|ContentSharingPicker|SpringLoading)"),
    ("Search", r"^(Search|DismissSearchAction)"),
    ("Controls, input & styles", r"^(PaletteSelectionEffect|\w*FormStyle$|Button|PrimitiveButton|BorderedButton|BorderedProminentButton|BorderlessButton|PlainButton|DefaultButton|GlassButton|GlassProminentButton|CardButton|LinkButton|ButtonRole|ButtonRepeatBehavior|ButtonSizing|Toggle|SwitchToggle|ButtonToggle|CheckboxToggle|DefaultToggle|TextField|SecureField|TextFieldStyle|PlainTextField|RoundedBorderTextField|SquareBorderTextField|DefaultTextField|Picker|DatePicker|MultiDatePicker|ColorPicker|Slider|Stepper|ProgressView|Gauge|Menu|Link|Label|LabeledContent|GroupBox|ControlGroup|Form|FormStyle|ColumnsFormStyle|GroupedFormStyle|ControlSize|ControlActiveState|.*PickerStyle$|.*DatePickerStyle$|.*ProgressViewStyle$|.*GaugeStyle$|.*MenuStyle$|.*LabelStyle$|.*ControlGroupStyle$|.*GroupBoxStyle$|.*LabeledContentStyle$|.*DisclosureGroupStyle$|.*TextEditorStyle$|.*ButtonStyle$|.*ToggleStyle$|DatePickerComponents|Spacer|Divider|EmptyView|AnyView|TupleView|EquatableView|ViewThatFits|HelpLink|MenuOrder|MenuActionDismissBehavior|Prominence|SliderTick|TextEditingCommands|PickerOption|MenuButton|PullDownButton|TimelineView|TimelineSchedule|PeriodicTimelineSchedule|EveryMinuteTimelineSchedule|ExplicitTimelineSchedule|AnimationTimelineSchedule|ContentUnavailable|VideoPlayer|WebView|SignInWithAppleButton|TextEditor)"),
    ("Lists, tables & collections", r"^(MutableCollection|RangeReplaceableCollection|OutlineSubgroupChildren|\w*TableStyle$|List|ForEach|Section|Table|OutlineGroup|EditButton|EditMode|EditActions|DisclosureGroup|Disclosure|InsetListStyle|PlainListStyle|GroupedListStyle|InsetGroupedListStyle|SidebarListStyle|BorderedListStyle|DefaultListStyle|CarouselListStyle|EllipticalListStyle|SubviewsCollection|SectionCollection|SectionConfiguration|Subview|DynamicViewContent|DynamicTableRowContent|KeyPathComparator|SortComparator|RenameButton|RenameAction|HeaderProminence|BadgeProminence|Group$|ContentUnavailableView)"),
    ("Navigation, toolbars & tabs", r"^(CustomizableToolbarContent|ContentToolbarPlacement|SidebarRowSize|Navigation|Toolbar|DefaultToolbarItem|Tab|AdaptableTabBarPlacement|SidebarAdaptableTabViewStyle|PageTabViewStyle|DefaultTabViewStyle|TabBarOnlyTabViewStyle|GroupedTabViewStyle|VerticalPageTabViewStyle|BottomBarTabViewStyle|IndexViewStyle|PageIndexViewStyle|DefaultNavigation|ColumnNavigationViewStyle|StackNavigationViewStyle|DoubleColumnNavigationViewStyle|BalancedNavigationSplitViewStyle|ProminentDetailNavigationSplitViewStyle|AutomaticNavigationSplitViewStyle|TitleBar|ToolbarTitle)"),
    ("Scrolling", r"^(Scroll|PinnedScrollableViews|ContentMargin|ScrollTarget|PagingScrollTargetBehavior|ViewAlignedScrollTargetBehavior|RefreshAction)"),
    ("Focus, keyboard & commands", r"^(Focus|FocusedValue|FocusedBinding|FocusedObject|FocusInteractions|DefaultFocusEvaluationPriority|KeyPress|KeyEquivalent|KeyboardShortcut|EventModifiers|SubmitLabel|SubmitTriggers|MoveCommandDirection)"),
    ("Gestures & pointer", r"^(HandGestureShortcut|Gesture|AnyGesture|TapGesture|SpatialTapGesture|LongPressGesture|DragGesture|MagnifyGesture|MagnificationGesture|RotateGesture|RotationGesture|SimultaneousGesture|SequenceGesture|ExclusiveGesture|GestureState|GestureMask|HoverPhase|HoverEffect|PointerStyle|PointerVisibility|ContentShapeKinds|WindowDragGesture|SpatialEventGesture|GestureStateGesture|_EndedGesture|_ChangedGesture|_MapGesture|PencilDoubleTap|PencilSqueeze|PencilHoverPose|PencilPreferredAction|CustomHoverEffect|HoverEffectContent|HoverEffectPhase|HoverEffectGroup|EmptyHoverEffect|DefaultHoverEffect|AnyHoverEffect|HighlightHoverEffect|LiftHoverEffect|AutomaticHoverEffect|HoverEffectPhaseOverride)"),
    ("Animation & transitions", r"^(VectorArithmetic|Animation|Animatable|AnimatablePair|AnimationContext|AnimationState|AnimationStateKey|CustomAnimation|EmptyAnimatableData|Transition|AnyTransition|TransitionPhase|TransitionProperties|Spring|UnitCurve|Transaction|TransactionKey|PhaseAnimator|KeyframeAnimator|Keyframe|KeyframeTrack|KeyframeTimeline|Keyframes|LinearKeyframe|SpringKeyframe|CubicKeyframe|MoveKeyframe|ContentTransition|MatchedGeometryProperties|NavigationTransition|ZoomNavigationTransition|AutomaticNavigationTransition|MatchedTransitionSource|AnimationCompletionCriteria|TimingCurve|(Push|Move|Opacity|Identity|Slide|Scale|Offset|Asymmetric|Blur|BlurReplace)Transition$|AnyMatchedTransitionSource|ScrollTransition|GeometryEffect|ProjectionTransform)"),
    ("Images & symbols", r"^(\w+SymbolEffect$|Image|AsyncImage|AsyncImagePhase|SymbolRenderingMode|SymbolVariants|SymbolVariableValueMode|SymbolColorRenderingMode|SymbolEffect|ImageRenderer|ImageResource|DynamicRange)"),
    ("Text & fonts", r"^(AttributeDynamicLookup|SystemFormatStyle|TimeDataSource|\w*TextSelectability$|\w*TextVariant$|Text|Font|LocalizedStringKey|TextAlignment|TextSelectability|TextSelection|TextEditor|AttributedText|TextProxy|TextAttribute|TextRenderer|TextVariantPreference|DynamicTypeSize|ContentSizeCategory|LegibilityWeight|TypesettingLanguage|LineHeight|WritingDirection|AttributedString|Writing|TextContentType|TextInput|FontResolution|BaselineOffset|Kerning)"),
    ("Shapes, colors & graphics", r"^(ShadowStyle|ContainerBackgroundPlacement|Shape|AnyShape|InsettableShape|RoundedShape|ShapeView|FillShapeView|StrokeShapeView|StrokeBorderShapeView|Path|Rectangle|RoundedRectangle|UnevenRoundedRectangle|Circle|Ellipse|Capsule|ContainerRelativeShape|ConcentricRectangle|ButtonBorderShape|StrokeStyle|FillStyle|RoundedCornerStyle|RectangleCornerRadii|OffsetShape|RotatedShape|ScaledShape|TransformedShape|ShapeRole|ShapeStyle|AnyShapeStyle|HierarchicalShapeStyle|ForegroundStyle|BackgroundStyle|SeparatorShapeStyle|TintShapeStyle|SelectionShapeStyle|PlaceholderTextShapeStyle|LinkShapeStyle|FillShapeStyle|WindowBackgroundShapeStyle|Color|Gradient|AnyGradient|LinearGradient|RadialGradient|AngularGradient|EllipticalGradient|MeshGradient|Material|Glass|ImagePaint|Canvas|GraphicsContext|BlendMode|ColorRenderingMode|ColorScheme|ColorSchemeContrast|ColorMatrix|Shader|ShaderFunction|ShaderLibrary|VisualEffect|EmptyVisualEffect|ResolvedImage|ContainerCorner|ConcentricCorner|Edge.Corner|Corner|BackgroundProminence|RedactionReasons|GlassEffect|Redaction)"),
    ("Layout & geometry", r"^(Layout|AnyLayout|LayoutSubview|LayoutSubviews|LayoutProperties|LayoutValueKey|LayoutDirection|LayoutDirectionBehavior|ProposedViewSize|ViewDimensions|VStack|HStack|ZStack|LazyVStack|LazyHStack|LazyVGrid|LazyHGrid|Grid|GridRow|GridItem|VStackLayout|HStackLayout|ZStackLayout|GridLayout|Alignment|HorizontalAlignment|VerticalAlignment|AlignmentID|AlignmentKey|Edge|EdgeInsets|HorizontalEdge|VerticalEdge|Axis|UnitPoint|Angle|GeometryReader|GeometryProxy|CoordinateSpace|NamedCoordinateSpace|GlobalCoordinateSpace|LocalCoordinateSpace|CoordinateSpaceProtocol|Anchor|SafeAreaRegions|ContentMode|ViewSpacing|Spacing|ContainerValues|ContainerValueKey|SpacerSizing|UserInterfaceSizeClass|HorizontalDirection|VerticalDirection|ContainerRelativeFrame)"),
    ("State, data flow & lifecycle", r"^(AnyLocation|State|Binding|StateObject|ObservedObject|EnvironmentObject|Environment|EnvironmentKey|AppStorage|Bindable|Namespace|ScaledMetric|DynamicProperty|PreferenceKey|EmptyPreferenceKey|View$|ViewBuilder|ViewModifier|EmptyModifier|ModifiedContent|EnvironmentalModifier|Entry|SubscriptionView|UIApplicationDelegateAdaptor|AsyncPreview|Previewable|ContentBuilder)"),
    ("Feedback & haptics", r"^(SensoryFeedback)"),

]
TYPE_AREAS = [(a, re.compile(rx)) for a, rx in TYPE_AREAS]


def area_of(it):
    c, n = it["container"], it["name"]
    if c == "EnvironmentValues":
        return "Environment values"
    if c in ("View",) and it["kind"] not in TYPE_KINDS:
        for a, rx in MOD_AREAS:
            if rx.match(n):
                return a
        return "Other view modifiers"
    if c in ("Scene", "App", "Commands"):
        return "Scenes, windows & app"
    if c is None and it["kind"] in ("func", "macro", "var"):
        if n.startswith("with") or n.startswith("Animat"):
            return "Animation & transitions"
        return "State, data flow & lifecycle"
    head = (c or n).split(".")[0]
    for a, rx in TYPE_AREAS:
        if rx.match(head):
            return a
    return "Other types"


# ------------------------------------------------------------ priorities ---
# P1: commonly used in typical apps. Grounded in Apple's SwiftUI tutorials
# (Landmarks, Scrumdinger), SkipUI's curated support table, the app corpora,
# and Isomer's own reference apps. Keyed by name (base name for modifiers,
# type names, env keys, or "Container.member(labels)").
P1_MODIFIERS = {
    "navigationDestination", "sheet", "fullScreenCover", "alert", "confirmationDialog",
    "onLongPressGesture", "simultaneousGesture", "highPriorityGesture", "matchedGeometryEffect",
    "onReceive", "onMove", "zIndex", "scaledToFit", "scaledToFill", "blur", "mask",
    "italic", "fontWeight", "fontDesign", "monospaced", "monospacedDigit", "kerning", "tracking",
    "minimumScaleFactor", "underline", "strikethrough", "textContentType", "toggleStyle", "badge",
    "navigationBarBackButtonHidden", "toolbarVisibility", "toolbar", "scrollContentBackground",
    "scrollIndicators", "keyboardShortcut", "help", "onHover", "focusable", "imageScale", "preference",
    "onPreferenceChange", "coordinateSpace", "background", "overlay", "offset", "scaleEffect",
    "rotationEffect", "transition", "progressViewStyle", "labelStyle", "buttonStyle", "textFieldStyle",
    "listStyle", "onDelete", "clipShape", "foregroundStyle", "tint", "border", "contextMenu",
    "presentationDetents", "lineLimit", "task", "onTapGesture", "gesture", "onSubmit", "searchable",
    "layoutPriority", "ignoresSafeArea", "animation", "environment", "multilineTextAlignment",
}
P1_TYPES = {
    "SecureField", "NavigationPath", "Ellipse", "TapGesture", "LongPressGesture", "GestureState", "Namespace",
    "ViewThatFits", "ButtonStyle", "ButtonStyleConfiguration", "ToggleStyle", "ToggleStyleConfiguration",
    "LabelStyle", "LabelStyleConfiguration", "ProgressViewStyle", "ProgressViewStyleConfiguration",
    "PreferenceKey", "ScaledMetric", "EditButton", "EditMode", "StrokeStyle", "OpenURLAction",
    "Entry", "PlainButtonStyle", "PlainListStyle", "ToolbarContent", "ToolbarContentBuilder",
    "DatePicker.Components", "DatePickerComponents", "Text.DateStyle", "Image.Scale", "Image.TemplateRenderingMode",
    "AsyncImagePhase", "Font.TextStyle", "DynamicViewContent", "EditActions",
}
P1_ENV = {"locale", "openURL", "isPresented", "isSearching", "dismissSearch", "editMode", "layoutDirection",
          "dynamicTypeSize", "timeZone", "calendar", "accessibilityReduceMotion"}
# individual members/inits that are P1 (container.name(labels))
P1_MEMBERS = {
    "Text.init(_:format:)", "Text.init(_:style:)", "Text.init(_:formatter:)",
    "LocalizedStringKey.StringInterpolation.appendInterpolation(_:format:)",
    "LocalizedStringKey.StringInterpolation.appendInterpolation(_:specifier:)",
    "LocalizedStringKey.StringInterpolation.appendInterpolation(_:style:)",
    "TextField.init(_:value:format:prompt:)", "TextField.init(_:text:prompt:axis:)",
    "NavigationStack.init(path:root:)", "NavigationLink.init(value:label:)", "NavigationLink.init(_:value:)",
    "ForEach.init(_:editActions:content:)", "List.init(_:editActions:rowContent:)",
    "Path.addArc(center:radius:startAngle:endAngle:clockwise:transform:)", "Path.addQuadCurve(to:control:)",
    "Path.addCurve(to:control1:control2:)",
    "Path.trimmedPath(from:to:)",
        "Shape.rotation(_:anchor:)", "Shape.offset(_:)", "Shape.offset(x:y:)", "Shape.scale(_:anchor:)",
    "Shape.stroke(_:style:)", "Shape.stroke(lineWidth:)", "Shape.stroke(style:)", "Shape.fill(style:)",
    "Shape.stroke(_:style:antialiased:)", "Shape.fill(_:style:)", "Shape.stroke(_:lineWidth:antialiased:)",
            "InsettableShape.strokeBorder(_:lineWidth:antialiased:)", "InsettableShape.strokeBorder(lineWidth:antialiased:)",
    "InsettableShape.strokeBorder(_:style:antialiased:)", "InsettableShape.strokeBorder(style:antialiased:)",
    "InsettableShape.inset(by:)",
    "ShapeStyle.linearGradient(colors:startPoint:endPoint:)", "ShapeStyle.linearGradient(_:startPoint:endPoint:)",
    "ShapeStyle.radialGradient(colors:center:startRadius:endRadius:)",
    "ShapeStyle.tint()",
    "ShapeStyle.opacity(_:)",
        "Color.init(_:bundle:)", "Color.init(hue:saturation:brightness:opacity:)",
    "Color.init(_:)", "Color.gradient()",
    "Font.custom(_:size:)", "Font.custom(_:size:relativeTo:)",
    "Font.system(_:design:weight:)", "Font.weight(_:)", "Font.bold(_:)", "Font.italic()", "Font.monospacedDigit()",
        "Image.renderingMode(_:)", "Image.init(_:bundle:)",
                        "Binding.animation(_:)", "Binding.init(_:)", "State.init()",
    "Gesture.updating(_:body:)", "Gesture.onEnded(_:)", "Gesture.onChanged(_:)",
            "PresentationDetent.fraction(_:)", "PresentationDetent.height(_:)", "PresentationDetent.custom(_:)",
    "Picker.init(selection:content:label:)", "Picker.init(_:systemImage:selection:content:)",
    "Slider.init(value:in:step:label:onEditingChanged:)", "Slider.init(value:in:label:onEditingChanged:)",
    "Slider.init(value:in:onEditingChanged:)", "Slider.init(value:in:step:onEditingChanged:)",
        "Stepper.init(value:in:step:label:onEditingChanged:)", "Stepper.init(_:value:in:step:onEditingChanged:)",
            "Toggle.init(_:systemImage:isOn:)", "Menu.init(_:systemImage:content:)",
    "Label.init(_:image:)", "Button.init(_:image:action:)", "ProgressView.init(value:total:label:)",
        "DatePicker.init(selection:displayedComponents:label:)", "DatePicker.init(selection:in:displayedComponents:label:)",
    "DatePicker.init(_:selection:in:displayedComponents:)", "AsyncImage.init(url:scale:content:placeholder:)",
    "AsyncImage.init(url:scale:transaction:content:)",
    "LabeledContent.init(_:value:format:)",
    "TabView.init(selection:content:)", "Tab.init(_:systemImage:value:content:)",
        "ToolbarItemPlacement.navigationBarLeading()",
    "ToolbarItemPlacement.navigationBarTrailing()",
        "VerticalAlignment.firstTextBaseline()",
            "withAnimation(_:completionCriteria:_:completion:)",
    "RangeReplaceableCollection.remove(atOffsets:)", "MutableCollection.move(fromOffsets:toOffset:)",
}
NICHE = re.compile(
    r"^(touchBar|window|menuBarExtra|dialogSuppression|dialogIcon|dialogSeverity|documentBrowser|documentLaunch|"
    r"accessibilityRotor|accessibilityCustomContent|accessibilityChartDescriptor|accessibilityDirectTouch|"
    r"accessibilityZoomAction|accessibilityLinkedGroup|accessibilityTextContentType|accessibilityLabeledPair|"
    r"accessibilityIgnoresInvertColors|accessibilityShowsLargeContentViewer|accessibilityDragPoint|accessibilityDropPoint|"
    r"accessibilityActivationPoint|accessibilityScrollAction|accessibilityQuickAction|accessibilityElements|"
    r"speech|writingTools|pencil|onPencil|typeSelect|handlesExternalEvents|userActivity|onContinueUserActivity|"
    r"hoverEffect|defaultHoverEffect|pointerStyle|pointerVisibility|focusEffect|onModifierKeysChanged|"
    r"materialActiveAppearance|glassEffectTransition|glassEffectUnion|glassEffectID|backgroundExtensionEffect|"
    r"tabViewSidebar|tabViewBottomAccessory|tabBarMinimize|toolbarMinimization|tabViewSearchActivation|"
    r"symbolVariableValueMode|symbolColorRenderingMode|symbolEffectsRemoved|allowedDynamicRange|textRenderer|"
    r"textInputCompletion|textInputSuggestions|textInputFormattingControl|textSelectionAffinity|attributedTextFormatting|"
    r"findNavigator|findDisabled|replaceDisabled|springLoading|exportableToServices|importableFromServices|"
    r"onCopyCommand|onCutCommand|onPasteCommand|onDeleteCommand|onMoveCommand|onExitCommand|onCommand|"
    r"focusedSceneValue|focusedSceneObject|scenePadding|horizontalRadioGroupLayout|controlGroupStyle|"
    r"gaugeStyle|labeledContentStyle|groupBoxStyle|disclosureGroupStyle|menuIndicator|menuOrder|"
    r"tableStyle|tableColumnHeaders|alternatingRowBackgrounds|dropDestination|contentCaptureProtected|"
    r"layoutDirectionBehavior|typesettingLanguage|lineHeight|containerCornerOffset|containerShape|"
    r"textScale|textVariant|labelIcon|labelReservedIconWidth|buttonSizing|textInputBorderShape|"
    r"defaultLaunchBehavior|restorationBehavior|supportsRemoteScenes|isSceneCaptured|sidebarRowSize|"
    r"preferredPencil|navigationLinkIndicatorVisibility|badgeProminence|backgroundProminence|"
    r"isTabViewSidebarAvailable|isTabBarShowingSections|tabBarPlacement|remoteDevice|resetFocus|"
    r"systemPrefersReducedResourceUsage|worldTracking|fontResolutionContext|findContext|appearsActive|"
    r"isUserAuthenticationEnabled|searchSuggestionsPlacement|contentTransitionAddsDrawingGroup|"
    r"documentConfiguration|newDocument|openDocument|openSettings|rename|toolbarLabelStyle|"
    r"defaultMinListHeaderHeight|headerProminence|listItemTint|listSectionIndex|listRowPlatterColor|"
    r"geometryGroup|transformEffect|projectionEffect|colorEffect|distortionEffect|layerEffect|"
    r"luminanceToAlpha|hueRotation|colorInvert|colorMultiply|blendMode|privacySensitive|unredacted|"
    r"invalidatableContent|widget|activity|safeAreaBar|scrollEdgeEffect|scrollInputBehavior|"
    r"onScrollPhaseChange|onScrollTargetVisibilityChange|onScrollVisibilityChange|scrollClipDisabled|"
    r"defaultScrollAnchor|scrollBounceBehavior|scrollTransition|presentationSizing|presentationCompactAdaptation|"
    r"presentationContentInteraction|presentationBackgroundInteraction|inspectorColumnWidth|"
    r"navigationSplitViewColumnWidth|navigationSubtitle|navigationDocument|toolbarTitleMenu|toolbarRole|"
    r"toolbarItemHidden|toolbarOverflowMenu|toolbarBackgroundVisibility|toolbarForegroundStyle|"
    r"submitScope|selectionDisabled|searchScopes|searchDictationBehavior|searchPresentationToolbarBehavior|"
    r"searchToolbarBehavior|searchFocused|searchCompletion|fileDialog|fileMover|dragContainer|dragPreviewsFormation|"
    r"draggable|onDrag|onDrop|copyable|cuttable|pasteDestination|itemProvider|modelContainer|"
    r"buttonRepeatBehavior|keyboardShortcut\(|digitalCrown|defaultAppStorage|backgroundTask|"
    r"handGesture|onLongTouchGesture|defersSystemGestures|allowsWindowActivationEvents|"
    r"accessibilityRepresentation|accessibilityChildren|accessibilityInputLabels|accessibilityRespondsToUserInteraction|"
    r"accessibilityFocused|accessibilitySortPriority|accessibilityAdjustableAction|accessibilityActions|accessibilityHeading|"
    r"accessibilityLabel|accessibilityHint|accessibilityValue|accessibilityHidden|accessibilityIdentifier|accessibilityAddTraits|"
    r"accessibilityRemoveTraits|accessibilityElement|accessibilityAction)"
)
# NICHE also catches a few common accessibility names (listed after the niche
# ones) only to keep them out of P3 when they matter; P1 rules run first.


def intro_major(it):
    v = (it.get("introduced") or {}).get("iOS") or (it.get("introduced") or {}).get("macOS")
    if not v:
        return None
    try:
        return float(".".join(v.split(".")[:2]))
    except ValueError:
        return None


def member_key(it):
    c = it["container"] or ""
    return (c + "." if c else "") + f"{it['name']}({it['labels']})"


SECONDARY_LABELS = re.compile(r"(isEnabled:|\bname:|inputKinds:|localization:|interactions:|antialiased:|eoFill:|"
                              r"fillStyle:|ignoresSafeAreaEdges:|forSelectionType:|coordinateSpace:|reservesSpace:|"
                              r"strategy:|body:|includeOptional:|prefersInApp:|onPresentationChanged:|onCancellation:|"
                              r"\bid:content:|style:$|alignment:$|executorPreference:|_:_:_:|okens:|selection:$|preview:$|^isPresented:error:|^error:)")
DEMOTE = {"View.searchable(text:isPresented:placement:prompt:)", "Color.init(_:)", "Binding.init(_:)", "Font.bold(_:)",
          "Text.init(_:formatter:)", "InsettableShape.inset(by:)", "InsettableShape.strokeBorder(_:style:antialiased:)",
          "InsettableShape.strokeBorder(style:antialiased:)", "Shape.stroke(_:style:antialiased:)", "Shape.fill(style:)",
          "Shape.offset(_:)", "Shape.offset(x:y:)", "Shape.scale(_:anchor:)", "Path.trimmedPath(from:to:)",
          "ShapeStyle.opacity(_:)", "View.alert(_:item:actions:)", "View.alert(_:item:actions:message:)",
          "View.confirmationDialog(_:item:titleVisibility:actions:)", "View.confirmationDialog(_:item:titleVisibility:actions:message:)"}


P3_FORCE = {"ObservedObject.Wrapper()", "EnvironmentObject.Wrapper()", "ContentBuilder()", "SimultaneousGesture.Value()"}


def priority(it, usage_apps=0, usage_old=0, group_present=False, group_size=1):
    """P1 / P2 / P3 for a gap item."""
    c, n, k = it["container"], it["name"], it["kind"]
    plats = it.get("plats", [])
    intro = intro_major(it)
    one_plat = len(plats) == 1
    mk = member_key(it)
    is_type = k in TYPE_KINDS
    qual = it["key"][1] if is_type else None
    if mk in P3_FORCE:
        return "P3"
    if mk in DEMOTE:
        return "P2"
    # explicit P1s
    if is_type and qual in P1_TYPES:
        return "P1"
    if c == "EnvironmentValues" and n in P1_ENV:
        return "P1"
    if mk in P1_MEMBERS:
        return "P1"
    if c is None and k == "macro" and n == "Entry":
        return "P1"
    if c == "View" and n in P1_MODIFIERS and group_size > 1 and SECONDARY_LABELS.search(it["labels"]):
        return "P2"
    if c == "View" and n in P1_MODIFIERS:
        # the specific signature may still be niche (new in 26+, platform-only)
        if intro and intro >= 26 and not group_present:
            return "P2"
        if intro and intro >= 26:
            return "P3"
        if one_plat and plats == ["macOS"]:
            return "P2"
        return "P1"
    # usage evidence
    if (usage_old + usage_apps) >= 3 and it["status"] == "ok" and not (intro and intro >= 26) and not group_present:
        return "P1"
    # niche / platform-specific / brand new
    if NICHE.match(n) or (c and NICHE.match(c.split(".")[-1][:1].lower() + c.split(".")[-1][1:])):
        return "P3"
    if one_plat:
        return "P3"
    if intro and intro >= 26:
        return "P3"
    if c and re.match(r"^(GraphicsContext|Accessibility|AttributedTextFormatting|Keyframe|TableColumn|Table|Spring|"
                       r"Text\.Layout|TextProxy|TextRenderer|Shader|ColorMatrix|MeshGradient|Glass|HoverEffect|"
                       r"CustomHoverEffect|AnimationContext|Animation\.|TransitionProperties|SliderTick|"
                       r"ContainerValues|Subview|SectionConfiguration|DocumentConfiguration|FocusedValues|"
                       r"WindowProxy|ImageRenderer|SymbolEffect|_)", c):
        return "P3"
    if is_type and re.match(r"^(Accessibility|Keyframe|Hover|Pencil|Window|Document|Immersive|Spring|Shader|"
                            r"GraphicsContext|Text\.Layout|TextRenderer|Glass|Symbol|Table|MeshGradient|"
                            r"ContentSharing|Material\.|Font\.Context|Tab\w*Style|ColorMatrix)", qual):
        return "P3"
    return "P2"
