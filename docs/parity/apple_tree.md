# The iPhone Storybook on Isomer against Apple's SwiftUI

The proof's `tests/parity-ios` item builds the iPhone Storybook twice: against
Apple's SwiftUI, and against Isomer's (`examples/apple/storybook_isomer_ios_application`,
the guest's tree drawn by apple/libraries/swift_ui_tree with Apple's views). Every story's
two pictures should be the same, pixel for pixel (the owner, 2026-11-13). A story that
differs is Isomer's: a param the encoder drops, or the tree renderer ignores, or a
composite the core builds where Apple has a control.

At 0.51.1, 40 of 98 stories differed. Their causes, and where each stands:

| Cause | Stories | State |
| --- | --- | --- |
| Gradient stops in Isomer's RGBA table, not the system's colours | scrolling.horizontal, shapes.gradients, shapes.gradientstyles, shapes.elliptical, shapes.effects | stops carry the colour's name (`n`) |
| An app's shape drawn as a rectangle; curves as lines | shapes.basic, shapes.path, shapes.arcs, shapes.rotation | `pathExact`: the parts as added, replayed with the system's path calls |
| Font weights folded (light, heavy, black), designs and tracking ignored | text.weights, text.tracking | all nine weights, `design`, `tracking` |
| `.multilineTextAlignment` not applied to the lines | text.lines, lists.empty | `textAlign` |
| `.rotationEffect` never on the wire | animation.transforms, shapes.stroke | `rotation` param |
| A stack with no spacing given 8 | text.tracking (and more) | nil: the system's |
| `.progressViewStyle`, `.layoutPriority`, `.blur` ignored | controls.progressstyle, layout.priority, shapes.effects | applied |
| NavigationLink's chevron outside a row | navigation.links | the chevron is a row's |
| A tab's content at its top-leading corner | navigation.tabs | centred |
| Live content and the platform's own name | isomer.map, isomer.video, controls.progressstyle, isomer.platform | masked alike in both pictures |
| `.bold()` sent as weight 700 (iOS draws `.fontWeight(.bold)` heavier) | text.weights, text.decoration, layout.grid, scrolling.horizontal | `.bold()` its own trait (`boldTrait`), drawn with `Text.bold()` |
| Content exactly 1 px off (identity opacity, scale and offset wrappers?) | images.symbols, controls.inline, layout.geometry, gestures.tap, state.appstorage | open |
| The core's own Stepper, labelled ProgressView, DisclosureGroup, ContentUnavailableView | controls.stepper, controls.progress, lists.outline, lists.empty | tagged with their roles (`native`, parts by `part`) and drawn as the system's: the Stepper, a labelled ProgressView, ContentUnavailableView; DisclosureGroup and OutlineGroup open (in a List they are rows of their own) |
| `underline(color:)`, `strikethrough(color:)` colours dropped | text.decoration | kept (`runLines`) |
| `Text(Image(systemName:))` inline as a Unicode glyph | text.format | the run names its symbol (`runSymbols`), drawn as the system's |
| `.disabled` as opacity, not the control's own look | controls.toggle | open: the core dims a disabled subtree's colours (`env.opacity *= 0.45`) where SwiftUI dims only its controls, on every platform |
| `LazyVGrid`'s adaptive columns against the window's width | layout.lazygrid | its columns sent (`native` lazyvgrid), the system's grid on Apple |
| `adoptFixedSize` through padding; an image's corners rounded too | images.assets | the clip adopts the frame and the padding; an image inside padding keeps its corners |
| `@State` inherited by another view type at the same place | input.focus | another type at a path starts its state afresh |
| `.environment(\.colorScheme, .dark)` not reaching named colours | state.environment | host hint `scheme`, applied |
| Web view, video player and map drawn as placeholders | isomer.webview, isomer.video, isomer.map | the web view a WKWebView, as Apple's; the video's and map's frames masked in both pictures |
| The toolbar's glass capsule about 1 pt wider | navigation.toolbar | open |
