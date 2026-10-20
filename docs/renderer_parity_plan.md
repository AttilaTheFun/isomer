# Renderer parity plan (in progress)

Goal (2026-07-04): two convergence targets —

1. **High-level renderers (React, Jetpack Compose)**: feature/quality parity
   with the GPU paths, *feeling native to their platform* (Material on
   Android, web-idiomatic on the web) even where that differs from iOS.
2. **Low-level renderers (WebGPU, OpenGL, Direct2D, GL/Linux)**: a single
   consistent look and feel, **no bridged native components at all** — all
   chrome drawn at the GPU layer by the shared adapter (the runtime's
   layout+draw walk). Remove the native bridges from the low-level hosts and
   their applications.

## Key facts (recon)

- Drawn chrome ALREADY exists for Windows/Linux behind `#if os(...)`:
  `WindowsNavBar` (Navigation.swift ~209/286) and `WindowsTabBar`
  (Components.swift ~202/264), and a drawn menu path (~424). The refactor is
  to key these on the **renderer binding** (`Renderer.usesDrawnChrome`,
  true for `.lowLevel`) instead of the OS, rename them (DrawnNavBar/
  DrawnTabBar), and make web+Android use them too.
- Host-view kinds emitted by the core: navbar (Navigation ~191), search
  (Navigation ~154), tabbar (Components ~211), menu (Components ~335),
  picker (PlatformViews ~263), datepicker (PlatformViews ~382?), image
  (Image.swift ~109, SVG/GIF fallback), webview/video (PlatformViews ~80),
  representables (`html:`/`android:`/`win:`/`linux:` — the
  UIViewRepresentable analogue; documented exception, stays native).
- Android-only native paths to remove for low level: recycler lists
  (usesRecyclerLists), native scroll (usesNativeScroll), native press
  feedback (pressFeedback host call), EditText overlay (keep an *invisible*
  IME capture channel; draw the field + caret in GPU).
- Web-only native paths to remove: DOM text overlay (same treatment), DOM
  press ripple layer, DOM host views for picker/menu/date/search.
- High-level tree gaps (why React/Compose feel broken): no navbar/back, no
  search, no presentations (sheets/alerts), stack alignment not serialized,
  box alignment/overlay/background nodes dropped, shadows dropped, hostView
  semantic controls crude, no press feedback, controlled TextField caret
  reset, no system-back wiring in Compose mode, images unsized.

## Work breakdown

### A. Binding-driven drawn chrome (core; helps every low-level platform)
- [x] `Renderer.usesDrawnChrome` (true for .lowLevel bindings; also true on
  Windows/Linux regardless, preserving today's behavior there).
- [x] Rename WindowsNavBar/WindowsTabBar → DrawnNavBar/DrawnTabBar; switch
  the `#if os` sites to `if Renderer.usesDrawnChrome`. Note: `#if os(WASI)`
  menu path (Components ~424) similarly.
- [x] Drawn search field (Navigation search host view → drawn field using
  the text-input channel).
- [x] Drawn picker/menu (DrawnPopUpList via popover) + DrawnDatePicker steppers: tap → drawn popup list presentation (reuse the
  presentation mechanism); selected row check-marked. Drawn datepicker: 3
  drawn wheels or +/- steppers (keep simple, consistent).
- [x] Drawn press feedback (Runtime.drawPressFeedback): runtime-drawn highlight/ripple (animated circle,
  wantsContinuousRender during animation) replacing host pressFeedback.
- [x] Image host-view fallback (SVG/GIF): keep bitmap path only for low
  level (imageInfo/drawImage), drop the DOM <img> host view.
- [x] WebView/video under low level (DrawnMediaPlaceholder + host openURL): drawn poster/placeholder + openURL
  (embedded surfaces can't be GPU-drawn); example app pages adjust.

### B. Strip native machinery from low-level hosts + apps
- [x] Android: usesRecyclerLists/usesNativeScroll → false; delete
  NativeListManager/NativeScrollManager/HostViewManager/PressFeedbackView
  usage + AndroidHost methods syncLists/syncNativeScroll/pressFeedback/
  syncHostViews (keep beginTextInput as invisible IME capture); runtime's
  own inertial scrolling takes over.
- [x] Web boot.js: host-view DOM layer reduced to `html:` representables;
  press layer deleted (drawn feedback); hidden IME input kept; scroll stays
  runtime-driven (already).
- [x] HostBridge protocol: syncLists/syncNativeScroll/setPressFeedback/
  beginListCell/endListCell/usesNativeScroll/usesRecyclerLists deleted along
  with the runtime's recycler/native-scroll machinery (ListBlob, RecyclerCellSpec,
  listTap/searchChanged/nativeScrollOffset entry points and their bridge
  exports). syncHostViews + syncWebView/syncNativeControl stay for
  representables (html:/win:/linux:).

### C. High-level tree enrichment (serializer + Runtime)
- [x] Serialize: stackAlignment + box alignment ("align": "leading" etc.),
  shadow, overlay/background as node arrays, offset/rotation/scale/opacity,
  showsIndicators.
- [x] Semantic control nodes (hostView params serialized; toggle semantic; navbar/tabbar/search host views reach the tree) instead of hostView JSON: "picker" (options,
  selected, edit id), "menu", "toggle"?, "datepicker" (ISO value), "search"
  (prompt, value, edit id), "navbar" {title, back:Bool, backID, trailing},
  "tabbar" {icons, labels, selected, edit id}. Navigation/Components emit
  these when `Renderer.isHighLevel` (third mode alongside drawn/hostView).
- [x] Presentations: serialize pendingPresentations as trailing z-stack
  overlay children with a scrim + dismiss id.
- [x] System back: Compose BackHandler → nativeBack() + nativeRender()
  (falls back to finish()); React keeps the navbar back button.
- [x] TextField: include a stable "id"; consumers keep local state while
  focused (uncontrolled with value sync) to avoid caret jumps.

### D. React renderer polish (web-native feel)
- [x] navbar/tabbar/search/picker/menu/datepicker/toggle components (real
  <select>, <input type=search|date|checkbox|range>), sheet/alert modals,
  CSS ripple on tap targets, alignment/shadow/overlay support, image sizing
  from frame, dark scheme via serialized colors (already resolved), fonts.

### E. Compose renderer polish (Material feel)
- [x] androidx.compose.material3:1.3.2 in rules_android_maven (repinned;
  material-icons-core arrives transitively); IsoTree wrapped in
  MaterialTheme(lightColorScheme()).
- [x] Mapped: navbar → CenterAlignedTopAppBar (back arrow, inlineAlpha
  crossfade), tabbar → NavigationBar + NavigationBarItem (asset icons),
  search → OutlinedTextField w/ Search icon (focus-local state), picker/menu
  → DropdownMenu (check-marked selection), datepicker → DatePickerDialog,
  toggle → Switch, slider → Slider, progress → Circular/LinearProgress-
  Indicator, presentations → ModalBottomSheet/AlertDialog, gradients →
  Brush, alignment (Row/Column/Box) + shadow + opacity, ripple via
  MaterialTheme clickable, weight guarded under unbounded constraints
  (scrollables), webview → AndroidView(WebView), Bridge.rendererName
  reflects the binding.

### Bugs found by the matrix (fixed in core)
- [x] Nav push transition (`transT`) froze pushed screens at opacity 0 under
  high-level bindings (no frame loop) — skipped when `Renderer.isHighLevel`.
- [x] onAppear keyed by serialize path was swallowed across nav pushes
  (same structural slot); keyed by identityPath|path instead.
- [x] Shapes/gradients weren't marked greedy, collapsing to zero size in
  component layouts (app icons); circle/capsule backgrounds lost their
  radius; gradient *backgrounds* (`.background(LinearGradient…)`) weren't
  serialized at all.
- [x] Android Compose mode: imageInfo now reports ready (Kotlin owns image
  loading like the web host), so AsyncImage always emits its image node.

### F. Verification matrix (each slice)
- web: `bazel run //examples/wasm/example_web_application` (React) and
  `:example_web_gpu_application`; Electron variants for screenshots.
- android: `bazel run //examples/android/example_application` (Compose)
  and `:example_opengl_application` on the hermetic emulator.
- Screenshot side-by-sides per app page (Apps root, Pokédex, Controls
  gallery, To-Do w/ text input, presentation sheet).

## Status
- [x] Plan written. Working order: A → B → C → D → E, committing per slice.
