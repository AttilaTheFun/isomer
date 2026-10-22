// The Gallery: Isomer's apps and components, a page each, on every
// platform. The Isomer app lists it as a section of its sidebar (an entry's
// page is GalleryPage); GalleryView is the same pages as an app of their own
// (the examples' apps, the wasm reactor the Isomer app runs). Compiled unchanged against Apple's SwiftUI
// (iOS, macOS) and Isomer's (web, Android, Linux, Windows), natively and as
// wasm.

import SwiftUI
import Isomer
import Observation
// The C library for getenv: the launch hooks below must not pull in
// Foundation (this file is host-compiled by the swift_ffi analyzer aspect,
// where Apple's Foundation would meet the reimplementation's types).
#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#elseif canImport(ucrt)
import ucrt
#endif

/// Reads a launch-environment variable: the process environment natively,
/// the WASI environment in a reactor (the host forwards its
/// ISO_-prefixed variables).
func launchEnvironment(_ name: String) -> String? {
    guard let value = getenv(name) else { return nil }
    return String(cString: value)
}

/// Shared theme, an `@Observable` put in the environment with
/// `.environment(_:)` and read back in the gallery with `@Environment(Theme.self)`.
@Observable final class Theme {
    var name = "Aurora"
    /// Nil = follow the system appearance (the default); the Settings toggle
    /// pins an explicit override.
    var darkOverride: Bool? = nil
    var dark: Bool {
        get { darkOverride ?? false }
        set { darkOverride = newValue }
    }
}

/// The Gallery as an app of its own: its sidebar, and each entry's page
/// (the shape the Isomer app shows it in, so the two look alike).
public struct GalleryView: View {
    @State private var model = GalleryModel()
    @State private var entry: GalleryEntry? = GalleryEntry.launchEntry
    /// A phone's one column: the entry a launch opened (ISO_OPEN_APP), else
    /// the sidebar.
    @State private var compactColumn: NavigationSplitViewColumn = GalleryEntry.launchEntry == nil ? .sidebar : .detail
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    /// A deep link delivered while running (`iso://…` on Android, the launch
    /// URL / a `iso:openurl` event on web); surfaced as an alert.
    @State private var openedURL: String?

    public init() {}

    // ONE shell on every platform and size. NavigationSplitView owns
    // responsive behavior — real SwiftUI collapses to a drill-in stack on
    // compact widths natively, and the reimplementation hosts do the same
    // (single pane, taps advance, back retreats) — so the app never swaps
    // layouts itself.
    public var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            List(selection: $entry) {
                Section("Apps") {
                    ForEach(GalleryEntry.apps) { GalleryEntryRow($0).tag($0) }
                }
                Section("Gallery") {
                    ForEach(GalleryEntry.componentGroups) { GalleryEntryRow($0).tag($0) }
                }
            }
            .navigationTitle("Isomer")
        } detail: {
            GalleryPage(entry ?? .first, model: model)
                .id(entry ?? .first)
        }
        .galleryEnvironment(model)
        .onAppear {
            // Wide, the first entry is open beside the sidebar.
            if entry == nil, sizeClass != .compact { entry = .first }
        }
        .onChange(of: entry) { value in
            if sizeClass == .compact, value != nil { compactColumn = .detail }
        }
        .onOpenURL { url in
            // Ignore the page's own address on web; deep links only.
            if !url.absoluteString.hasPrefix("http") {
                openedURL = url.absoluteString
            }
        }
        .onChange(of: scenePhase) { phase in
            Bridge.log("scenePhase -> \(phase)")
        }
        .alert(
            "Opened URL",
            isPresented: Binding(
                get: { openedURL != nil },
                set: { if !$0 { openedURL = nil } }
            )
        ) {
            Button("OK") { openedURL = nil }
        } message: {
            Text(openedURL ?? "")
        }
    }
}

/// The bundled example apps, presented as a navigable list. Selecting one
/// pushes its screen onto this tab's shared NavigationStack.
struct AppCatalogEntry: Identifiable {
    let id: Int
    let title: String
    let subtitle: String
    let color: Color
}

let appCatalog: [AppCatalogEntry] = [
    AppCatalogEntry(id: 1, title: "Pokédex", subtitle: "Catalog every Pokémon", color: .red),
    AppCatalogEntry(id: 0, title: "Wikipedia", subtitle: "Browse & search articles", color: .blue),
    AppCatalogEntry(id: 2, title: "Hacker News", subtitle: "Top stories & comments", color: .orange),
    AppCatalogEntry(id: 3, title: "To-Do", subtitle: "Tasks by day", color: .teal),
    AppCatalogEntry(id: 4, title: "Meme Creator", subtitle: "Caption a photo", color: .green),
    AppCatalogEntry(id: 5, title: "Date Planner", subtitle: "Plan events by day", color: .purple),
    AppCatalogEntry(id: 6, title: "Map Explorer", subtitle: "Pan, zoom, rotate & tilt", color: .indigo),
    AppCatalogEntry(id: 7, title: "2048", subtitle: "Swipe to merge tiles", color: .brown),
    AppCatalogEntry(id: 8, title: "Counter", subtitle: "The smallest example", color: .gray),
    AppCatalogEntry(id: 9, title: "Floating Menu", subtitle: "A menu over the navigation bar", color: .yellow),
]

let galleryGroups = ["Controls", "Layout & Motion", "Media", "System"]

/// What the Gallery's sidebar lists: one of its apps, or a group of
/// components.
public enum GalleryEntry: Hashable, Identifiable, Sendable {
    case app(Int)
    case componentGroup(Int)

    public var id: Self { self }

    /// The apps, in the sidebar's order.
    public static var apps: [GalleryEntry] { appCatalog.map { .app($0.id) } }
    /// The groups of components.
    public static var componentGroups: [GalleryEntry] { galleryGroups.indices.map { .componentGroup($0) } }
    /// The apps, then the groups.
    public static var all: [GalleryEntry] { apps + componentGroups }
    /// What the Gallery opens on.
    public static let first = GalleryEntry.app(1)

    public var title: String {
        switch self {
        case .app(let id): return appCatalog.first { $0.id == id }?.title ?? ""
        case .componentGroup(let group): return galleryGroups.indices.contains(group) ? galleryGroups[group] : ""
        }
    }

    /// A short name for the entry, as the ISO_OPEN_APP launch hook takes it
    /// ("pokedex", "map", "controls", "layout"...).
    public var slug: String {
        switch self {
        case .app(0): return "wikipedia"
        case .app(1): return "pokedex"
        case .app(2): return "hackernews"
        case .app(3): return "todo"
        case .app(4): return "meme"
        case .app(5): return "dateplanner"
        case .app(6): return "map"
        case .app(7): return "game2048"
        case .app(8): return "counter"
        case .app(9): return "floatingmenu"
        case .componentGroup(0): return "controls"
        case .componentGroup(1): return "layout"
        case .componentGroup(2): return "media"
        case .componentGroup(3): return "system"
        default: return ""
        }
    }

    public init?(slug: String) {
        guard let entry = Self.all.first(where: { $0.slug == slug }) else { return nil }
        self = entry
    }

    /// Headless-verification hook: launching with ISO_OPEN_APP=<slug> (e.g.
    /// `SIMCTL_CHILD_ISO_OPEN_APP=map xcrun simctl launch …`) opens that entry
    /// directly — simctl can inject environment but not taps.
    public static var launchEntry: GalleryEntry? {
        launchEnvironment("ISO_OPEN_APP").flatMap(GalleryEntry.init(slug:))
    }
}

struct GalleryComponent: Identifiable, Hashable {
    let id: Int
    let title: String
    let group: Int
}

let galleryComponents: [GalleryComponent] = [
    GalleryComponent(id: 0, title: "Controls", group: 0),
    GalleryComponent(id: 1, title: "Progress", group: 0),
    GalleryComponent(id: 2, title: "Menu", group: 0),
    GalleryComponent(id: 3, title: "GeometryReader", group: 1),
    GalleryComponent(id: 4, title: "Gradient & shadow", group: 1),
    GalleryComponent(id: 5, title: "Animation", group: 1),
    GalleryComponent(id: 6, title: "Form & Outline", group: 1),
    GalleryComponent(id: 7, title: "List selection", group: 1),
    GalleryComponent(id: 8, title: "Media", group: 2),
    GalleryComponent(id: 9, title: "WebView", group: 2),
    GalleryComponent(id: 10, title: "Presentations", group: 3),
    GalleryComponent(id: 11, title: "Environment", group: 3),
    GalleryComponent(id: 12, title: "Logging", group: 3),
    GalleryComponent(id: 13, title: "Platform", group: 3),
    GalleryComponent(id: 14, title: "Chat & Toolbar", group: 0),
]

/// The Gallery's state across its screens: the apps' models, one per
/// window, kept while the sidebar's selection changes.
@MainActor @Observable public final class GalleryModel {
    let theme = Theme()
    let pokedex = PokedexStore()
    let wiki = FeedModel()
    let pokeList = PokemonListModel()
    let hn = HNFeedModel()
    let planner = PlannerStore()
    let todos = TodoStore()

    /// Headless hook: ISO_OPEN_POKEMON=<id> opens that Pokémon's detail at
    /// launch (pairs with ISO_OPEN_APP=pokedex; simctl can inject env, not taps).
    var pokemon: PokemonRef? = launchEnvironment("ISO_OPEN_POKEMON")
        .flatMap { Int($0) }.map { PokemonRef(id: $0, name: "pokemon-\($0)") }

    public init() {}
}

extension View {
    /// What the Gallery's screens read from the environment (its theme, the
    /// Pokédex's store), and its appearance: the system's until its
    /// Settings pin one.
    public func galleryEnvironment(_ model: GalleryModel) -> some View {
        environment(model.theme)
            .environment(model.pokedex)
            // `.preferredColorScheme(nil)` = no override.
            .preferredColorScheme(model.theme.darkOverride.map { $0 ? .dark : .light })
    }
}

/// An entry as one page, for an app whose sidebar opens a page per entry
/// (the Isomer app; a phone's one column): its list, whose rows push their
/// screens, or the app's one screen.
public struct GalleryPage<Actions: View>: View {
    let entry: GalleryEntry
    var model: GalleryModel
    let actions: Actions
    @State private var path: [GalleryPush] = []

    /// `actions`: the app's own bar items on the entry's first screen.
    public init(_ entry: GalleryEntry, model: GalleryModel, @ViewBuilder actions: () -> Actions) {
        self.entry = entry
        self.model = model
        self.actions = actions()
    }

    // The stack is the page's root, its modifiers inside it: a compact split
    // knows a pane by its root (Android's draws a back row over one that
    // is not a stack).
    public var body: some View {
        NavigationStack(path: $path) {
            root
                .toolbar { ToolbarItem(placement: .primaryAction) { actions } }
                .navigationDestination(for: GalleryPush.self) { push in destination(push) }
                .onAppear {
                    // ISO_OPEN_POKEMON: the Pokédex opens on that Pokémon.
                    if entry == .app(1), path.isEmpty, let pokemon = model.pokemon { path = [.pokemon(pokemon)] }
                }
        }
    }

    @ViewBuilder
    private var root: some View {
        switch entry {
        case .app(0): WikipediaMaster(model: model.wiki, selection: pushing(GalleryPush.article))
        case .app(1): PokedexMaster(model: model.pokeList, selection: pushing(GalleryPush.pokemon))
        case .app(2): HackerNewsMaster(model: model.hn, selection: pushing(GalleryPush.story))
        case .app(3): TodoMasterColumn(store: model.todos, selection: pushing(GalleryPush.todo))
        case .app(4): MemeCreatorScreen()
        case .app(5): DatePlannerMaster(store: model.planner, selection: pushing(GalleryPush.event))
        case .app(6): MapExplorerScreen()
        case .app(7): Game2048Screen()
        case .app(8): CounterScreen()
        case .app(9): FloatingMenuScreen()
        case .componentGroup(let group): GalleryGroupColumn(group: group, selection: pushing(GalleryPush.component))
        default: PlaceholderDetail("")
        }
    }

    @ViewBuilder
    private func destination(_ push: GalleryPush) -> some View {
        switch push {
        case .article(let article): ArticleView(article: article)
        case .pokemon(let pokemon): PokemonDetailView(pokemon: pokemon)
        case .story(let story): HNStoryDetailView(story: story)
        case .todo(let filter): TodoListView(store: model.todos, filter: filter)
        case .event(let id): EventDetailView(store: model.planner, eventID: id)
        case .component(let component): galleryDetail(component)
        }
    }

    /// A list's selection that pushes the row it is set to (and shows none
    /// selected: the row's screen is on top of it).
    private func pushing<Value>(_ make: @escaping (Value) -> GalleryPush) -> Binding<Value?> {
        Binding(get: { nil }, set: { value in
            if let value { path.append(make(value)) }
        })
    }
}

extension GalleryPage where Actions == EmptyView {
    public init(_ entry: GalleryEntry, model: GalleryModel) {
        self.init(entry, model: model) { EmptyView() }
    }
}

/// What a Gallery page pushes: a row's screen.
enum GalleryPush: Hashable {
    case article(Article)
    case pokemon(PokemonRef)
    case story(HNStory)
    case todo(TodoFilter)
    case event(Int)
    case component(GalleryComponent)
}

/// An entry's row in a sidebar: its glyph on its colour, and its title.
public struct GalleryEntryRow: View {
    let entry: GalleryEntry

    public init(_ entry: GalleryEntry) { self.entry = entry }

    public var body: some View {
        switch entry {
        case .app(let id):
            let app = appCatalog.first { $0.id == id }
            SidebarRow(title: entry.title, color: app?.color ?? .gray, glyph: String(entry.title.prefix(1)))
        case .componentGroup:
            SidebarRow(title: entry.title, color: .gray, glyph: "▦")
        }
    }
}

struct SidebarRow: View {
    let title: String
    let color: Color
    let glyph: String

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color)
                Text(glyph).font(.subheadline).bold().foregroundColor(.white)
            }
            .frame(width: 26, height: 26)
            Text(title).font(.body).foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

// MARK: Per-app master columns (reuse the apps' models, rows, and detail views)

struct WikipediaMaster: View {
    var model: FeedModel
    @Binding var selection: Article?
    @State private var query = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(model.articles) { article in
                ArticleRow(article: article).tag(article)
            }
        }
        .searchable(text: $query, prompt: "Search Wikipedia")
        .onChange(of: query) { newValue in model.load(query: newValue) }
        .navigationTitle("Wikipedia")
        .onAppear { if model.articles.isEmpty { model.load(query: "") } }
    }
}

struct PokedexMaster: View {
    var model: PokemonListModel
    @Binding var selection: PokemonRef?
    @State private var query = ""

    var body: some View {
        List(selection: $selection) {
            ForEach(model.filter(query)) { pokemon in
                PokemonRow(pokemon: pokemon).tag(pokemon)
            }
        }
        .searchable(text: $query, prompt: "Search Pokémon")
        .navigationTitle("Pokédex")
        .onAppear { model.loadIfNeeded() }
    }
}

struct HackerNewsMaster: View {
    var model: HNFeedModel
    @Binding var selection: HNStory?

    var body: some View {
        List(selection: $selection) {
            ForEach(model.stories.indices, id: \.self) { index in
                HNStoryRow(rank: index + 1, story: model.stories[index])
                    .tag(model.stories[index])
            }
        }
        .navigationTitle("Hacker News")
        .onAppear { model.loadIfNeeded() }
    }
}

struct DatePlannerMaster: View {
    var store: PlannerStore
    @Binding var selection: Int?

    var body: some View {
        List(selection: $selection) {
            ForEach(store.days.indices, id: \.self) { index in
                let group = store.days[index]
                Section(dayHeadline(group.day)) {
                    ForEach(group.events) { event in
                        EventRow(event: event).tag(event.id)
                    }
                }
            }
        }
        .navigationTitle("Date Planner")
    }
}

struct GalleryGroupColumn: View {
    let group: Int
    @Binding var selection: GalleryComponent?

    var body: some View {
        List(selection: $selection) {
            ForEach(galleryComponents.filter { $0.group == group }) { component in
                Text(component.title).tag(component)
            }
        }
        .navigationTitle(galleryGroups[group])
    }
}

struct PlaceholderDetail: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        VStack {
            Spacer()
            Text(text).font(.headline).foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The detail pane for a gallery component: full-screen demos for the rich ones,
/// otherwise the component's card on a plain background (no nested card chrome).
@ViewBuilder
func galleryDetail(_ component: GalleryComponent) -> some View {
    switch component.id {
    case 0: GalleryDemo { ControlsCard() }
    case 1: GalleryDemo { ProgressCard() }
    case 2: GalleryDemo { MenuCard() }
    case 3: GalleryDemo { GeometryCard() }
    case 4: GalleryDemo { GradientCard() }
    case 5: GalleryDemo { AnimationCard() }
    case 6: FormDemoScreen()
    case 7: SelectionDemoScreen()
    case 8: MediaScreen()
    case 9: GalleryWebDemo()
    case 10: GalleryDemo { PresentationCard() }
    case 11: GalleryDemo { EnvironmentCard() }
    case 12: GalleryDemo { LoggingCard() }
    case 13: GalleryDemo { PlatformCard() }
    default: ChatDemoScreen()
    }
}

/// Exercises the inbox/chat API batch end-to-end: multi-item toolbar
/// (`ToolbarItem` + `Image(systemName:)`), an inline title, a
/// bottom-anchored transcript (`.defaultScrollAnchor(.bottom)`), and a
/// growing multi-line composer (`TextField(axis: .vertical)` +
/// `.lineLimit(1...6)`), with whole-row tap targets via `.contentShape`.
struct ChatDemoScreen: View {
    @State private var draft = ""
    @State private var messages: [String] = (1 ... 24).map { "Message #\($0)" }
    @State private var lastAction = "none"

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(messages.indices, id: \.self) { index in
                        HStack {
                            Text(messages[index])
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(Color.blue.opacity(0.15))
                                .cornerRadius(12)
                            Spacer(minLength: 40)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { lastAction = "row \(index)" }
                    }
                }
                .padding(12)
            }
            .restingAtBottom()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 6)
                Button {
                    if !draft.isEmpty {
                        messages.append(draft)
                        draft = ""
                    }
                } label: {
                    Image(systemName: "paperplane")
                }
            }
            .padding(10)
            Text("Last action: \(lastAction)")
                .font(.caption).foregroundColor(.secondary)
                .padding(.bottom, 6)
        }
        .navigationTitle("Chat")
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { lastAction = "settings" } label: {
                    Image(systemName: "gearshape")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { messages.append("Added #\(messages.count + 1)") } label: {
                    Image(systemName: "plus")
                }
            }
        }
    }
}

struct GalleryDemo<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            content
                .padding(20)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }
}

struct GalleryWebDemo: View {
    var body: some View {
        WebView(url: URL(string: "https://en.wikipedia.org/wiki/SwiftUI"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("WebView")
    }
}

// MARK: - Gallery tab (component showcase)

/// The gallery's scroll of component cards, without its own NavigationStack so
/// it can drop into either a tab (wrapped above) or a split column.
struct GalleryContent: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ControlsCard()
                ProgressCard()
                MenuCard()
                GeometryCard()
                GradientCard()
                AnimationCard()
                MediaCard()
                WebViewCard()
                ContainersCard()
                PresentationCard()
                EnvironmentCard()
                LoggingCard()
                PlatformCard()
            }
            .padding(20)
            .frame(maxWidth: 560)
        }
        .navigationTitle("Gallery")
    }
}

/// A titled container used by every gallery section.
struct Card<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colorScheme == .dark ? Color(white: 1, opacity: 0.08) : Color(white: 0, opacity: 0.04))
        .cornerRadius(14)
    }
}

struct ControlsCard: View {
    @State private var count = 0
    @State private var on = true
    @State private var brightness = 0.6
    @State private var quantity = 1
    @State private var role = "Navigator"

    private let roles = ["Navigator", "Engineer", "Pilot", "Medic"]

    var body: some View {
        Card("Controls") {
            HStack(spacing: 14) {
                Button("−") { count -= 1 }
                Text("\(count)").font(.title2).frame(width: 56)
                Button("+") { count += 1 }
            }
            Toggle("Enabled", isOn: $on)
            Text("Brightness: \(Int(brightness * 100))%")
                .font(.subheadline).foregroundColor(.secondary)
            Slider(value: $brightness)
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1 ... 10)
            Picker("Role", selection: $role) {
                ForEach(roles, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

struct ProgressCard: View {
    @State private var progress = 0.35

    var body: some View {
        Card("ProgressView") {
            Text("Indeterminate")
                .font(.subheadline).foregroundColor(.secondary)
            ProgressView()
            Text("Determinate: \(Int(progress * 100))%")
                .font(.subheadline).foregroundColor(.secondary)
            ProgressView(value: progress)
            Slider(value: $progress)
        }
    }
}

struct MenuCard: View {
    @State private var choice = "—"

    var body: some View {
        Card("Menu") {
            Text("Native pop-up menu (an HTML <select> on web, a pop-up on Android).")
                .font(.subheadline).foregroundColor(.secondary)
            Menu("Actions") {
                Button("Duplicate") { choice = "Duplicate" }
                Button("Archive") { choice = "Archive" }
                Button("Delete") { choice = "Delete" }
            }
            Text("Last action: \(choice)")
                .font(.footnote).foregroundColor(.secondary)
        }
    }
}

struct GeometryCard: View {
    var body: some View {
        Card("GeometryReader") {
            Text("Reads its proposed size and splits it proportionally.")
                .font(.subheadline).foregroundColor(.secondary)
            GeometryReader { geo in
                HStack(spacing: 6) {
                    Color.accentColor
                        .frame(width: geo.size.width * 0.6)
                        .cornerRadius(6)
                    Color.accentColor.opacity(0.4)
                        .cornerRadius(6)
                }
            }
            .frame(height: 44)
        }
    }
}

struct WebViewCard: View {
    var body: some View {
        Card("WebView") {
            Text("An <iframe> on the web, a native WebView on Android, a WKWebView on Apple.")
                .font(.subheadline).foregroundColor(.secondary)
            // Opened on demand: a live web view embedded in a scrolling list is
            // expensive (notably WKWebView on iOS), so push it instead.
            NavigationLink {
                WebView(url: URL(string: "https://en.wikipedia.org/wiki/SwiftUI"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle("WebView")
            } label: {
                Text("Open a web page")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .cornerRadius(10)
            }
        }
    }
}

struct AnimationCard: View {
    @State private var revealed = false

    var body: some View {
        Card("Animation") {
            Text("withAnimation interpolates opacity and offset over time.")
                .font(.subheadline).foregroundColor(.secondary)
            Button(revealed ? "Hide" : "Reveal") {
                withAnimation(.easeInOut(duration: 0.45)) {
                    revealed.toggle()
                }
            }
            Text("Hello, animation!")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity)
                .background(Color.accentColor)
                .cornerRadius(10)
                .opacity(revealed ? 1 : 0)
                .offset(y: revealed ? 0 : -16)
        }
    }
}

struct MediaCard: View {
    var body: some View {
        Card("Media") {
            Text("Native VideoPlayer (<video> / VideoView / AVPlayer) and bridged SVG & GIF images.")
                .font(.subheadline).foregroundColor(.secondary)
            NavigationLink {
                MediaScreen()
            } label: {
                Text("Open media demo").foregroundColor(.accentColor)
            }
        }
    }
}

struct MediaScreen: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("VideoPlayer").font(.headline)
                VideoPlayer(url: URL(string:
                    "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 200)
                    .cornerRadius(12)

                Text("SVG (vector)").font(.headline).padding(.top, 8)
                AsyncImage(url: URL(string:
                    "https://upload.wikimedia.org/wikipedia/commons/f/fd/Ghostscript_Tiger.svg"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)

                Text("Animated GIF").font(.headline).padding(.top, 8)
                AsyncImage(url: URL(string:
                    "https://upload.wikimedia.org/wikipedia/commons/2/2c/Rotating_earth_%28large%29.gif"))
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Media")
    }
}

struct ContainersCard: View {
    var body: some View {
        Card("Form · Outline · selection") {
            Text("Grouped forms, an expandable outline, and a selectable list.")
                .font(.subheadline).foregroundColor(.secondary)
            NavigationLink {
                FormDemoScreen()
            } label: {
                Text("Form & OutlineGroup").foregroundColor(.accentColor)
            }
            NavigationLink {
                SelectionDemoScreen()
            } label: {
                Text("List selection").foregroundColor(.accentColor)
            }
        }
    }
}

struct OutlineItem: Identifiable {
    let id: String
    let name: String
    var children: [OutlineItem]?

    init(_ name: String, children: [OutlineItem]? = nil) {
        self.id = name
        self.name = name
        self.children = children
    }
}

let sampleTree: [OutlineItem] = [
    OutlineItem("shared", children: [
        OutlineItem("swift_ui_core", children: [
            OutlineItem("Form.swift"),
            OutlineItem("Outline.swift"),
            OutlineItem("Scroll.swift"),
        ]),
        OutlineItem("example_application", children: [
            OutlineItem("ExampleApp.swift"),
            OutlineItem("Pokedex.swift"),
        ]),
    ]),
]

struct FormDemoScreen: View {
    @State private var name = ""
    @State private var notify = true
    @State private var role = "Navigator"
    private let roles = ["Navigator", "Engineer", "Pilot"]

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
                Toggle("Notifications", isOn: $notify)
                Picker("Role", selection: $role) {
                    ForEach(roles, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("Project files") {
                OutlineGroup(sampleTree, children: \.children) { item in
                    Text(item.name)
                        .foregroundColor(item.children == nil ? .secondary : .primary)
                }
            }
            Section {
                Text("`Form`, `Section`, and `OutlineGroup` are reimplemented for wasm/Android and use real SwiftUI on Apple.")
                    .font(.footnote).foregroundColor(.secondary)
            }
        }
        .navigationTitle("Form")
    }
}

struct SelectionDemoScreen: View {
    @State private var selected: String?
    private let flavors = ["Vanilla", "Chocolate", "Strawberry", "Matcha", "Mango"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selected.map { "Selected: \($0)" } ?? "Tap a row to select")
                .font(.headline)
                .padding(16)
            List(selection: $selected) {
                ForEach(flavors, id: \.self) { flavor in
                    Text(flavor).tag(flavor)
                }
            }
        }
        .navigationTitle("List selection")
    }
}

struct GradientCard: View {
    var body: some View {
        Card("Gradient + shadow") {
            Text("Aurora")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 90)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .cornerRadius(16)
                .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        }
    }
}

struct PresentationCard: View {
    @State private var showSheet = false
    @State private var showAlert = false

    var body: some View {
        Card("Presentations (animated)") {
            HStack(spacing: 12) {
                Button("Show sheet") { showSheet = true }
                Button("Show alert") { showAlert = true }
            }
        }
        .sheet(isPresented: $showSheet) {
            VStack(spacing: 16) {
                Text("A sheet").font(.title2).bold()
                Text("Slides up over a dimming scrim. Tap below to dismiss.")
                    .font(.subheadline).foregroundColor(.secondary)
                Button("Done") { showSheet = false }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.15)).cornerRadius(10)
            }
        }
        .alert("Heads up", isPresented: $showAlert) {
            Button("OK") { showAlert = false }
        } message: {
            Text("Alerts fade in over the content.")
        }
    }
}

struct EnvironmentCard: View {
    @Environment(Theme.self) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var theme = theme
        Card("@Environment / @Environment(Theme.self)") {
            Toggle("Dark mode", isOn: $theme.dark)
            Text("Environment colorScheme: \(colorScheme == .dark ? "dark" : "light")")
                .font(.subheadline).foregroundColor(.secondary)
            TextField("Rename theme", text: $theme.name)
        }
    }
}

struct LoggingCard: View {
    @State private var logged = 0

    var body: some View {
        Card("Native bridge logging") {
            Text("Tap to write to the host log via the native bridge.")
                .font(.subheadline).foregroundColor(.secondary)
            HStack(spacing: 10) {
                ForEach(0 ..< 3) { index in
                    Circle()
                        .fill(index < logged % 4 ? Color.green : Color.gray.opacity(0.3))
                        .frame(width: 10, height: 10)
                }
                Spacer(minLength: 0)
                Text("\(logged) logged").font(.footnote).foregroundColor(.secondary)
            }
            .onTapGesture {
                logged += 1
                Bridge.log("Hello from shared SwiftUI code! count=\(logged)")
            }
        }
    }
}

struct PlatformCard: View {
    #if os(Windows) || os(Linux)
    @State private var sliderValue = 40
    #endif

    var body: some View {
        Card("Platform") {
            #if canImport(Darwin)
            Badge("Compiled for Apple", color: .blue)
            #elseif os(Android)
            Badge("Compiled for Android", color: .green)
            #elseif os(WASI)
            Badge("Compiled for WebAssembly", color: .purple)
            #elseif os(Windows)
            Badge("Compiled for Windows", color: .blue)
            #elseif os(Linux)
            Badge("Compiled for Linux", color: .orange)
            #else
            Badge("Unknown platform", color: .gray)
            #endif
            DetailRow(label: "Platform", value: Bridge.platformName)
            DetailRow(label: "Renderer", value: Bridge.rendererName)
            DetailRow(label: "Epoch ms", value: "\(Bridge.epochMilliseconds())")
            #if os(Windows)
            // A `WindowsViewRepresentable` demo: a real native Win32 trackbar
            // (`msctls_trackbar32`) bridged into the shared SwiftUI tree.
            DetailRow(label: "Native trackbar", value: "\(sliderValue)")
            NativeSlider(value: $sliderValue)
                .frame(height: 34)
            #elseif os(Linux)
            // A `LinuxViewRepresentable` demo: a host-drawn trackbar
            // (`linux:trackbar`) bridged into the shared SwiftUI tree.
            DetailRow(label: "Native trackbar", value: "\(sliderValue)")
            NativeSlider(value: $sliderValue)
                .frame(height: 34)
            #endif
        }
    }
}

// MARK: - Small reusable views

struct Badge: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(color)
            .cornerRadius(8)
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).bold()
            Spacer(minLength: 24)
            Text(value).foregroundColor(.secondary)
        }
        .font(.subheadline)
    }
}
