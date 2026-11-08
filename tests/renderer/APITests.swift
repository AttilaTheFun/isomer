// Checks for SwiftUI API Isomer gained from the API audit
// (docs/swiftui_api_audit.md): each builds a screen with the mock renderer
// and asserts on the tree, the serialized form, or what a host event does.

import FlatBuffers
import Foundation
import SwiftUI  // IsomerCore, aliased (BUILD.bazel)
import IsomerSwiftUI

/// The flat tree of the mock's last frame.
@MainActor
func lastFlatTree(_ mock: MockRenderer, _ encoder: FlatTreeEncoder = FlatTreeEncoder()) -> IsoFlat_Node {
    var buffer = ByteBuffer(bytes: encoder.encode(root: mock.lastTree!))
    return getRoot(byteBuffer: &buffer) as IsoFlat_Node
}

/// Every node of a flat tree that passes the test.
func flatNodes(_ node: IsoFlat_Node, where test: (IsoFlat_Node) -> Bool) -> [IsoFlat_Node] {
    var found: [IsoFlat_Node] = []
    func walk(_ n: IsoFlat_Node) {
        if test(n) { found.append(n) }
        for i in 0..<n.ch.count { walk(n.ch[i]) }
    }
    walk(node)
    return found
}

func param(_ node: IsoFlat_Node, _ key: String) -> String? {
    node.params.first { $0.key == key }?.value
}

// MARK: SecureField

nonisolated(unsafe) var password = ""

struct SecureScreen: View {
    var body: some View {
        Form {
            TextField("Name", text: .constant(""))
            SecureField("Password", text: Binding(get: { password }, set: { password = $0 }))
        }
    }
}

@MainActor
func checkSecureField(_ mock: MockRenderer) {
    Runtime.shared.installRootView { SecureScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    let fields = flatNodes(lastFlatTree(mock, encoder)) { $0.kind == .textfield }
    expect(fields.count == 2, "both fields are text fields (got \(fields.count))")
    expect(fields.map { param($0, "secure") } == [nil, "1"], "only the SecureField is secure")
    Runtime.shared.installTreeHandlers(encoder.handlers)
    if let edit = fields.last?.edit { Runtime.shared.hostViewEvent(id: edit, value: "hunter2") }
    expect(password == "hunter2", "typing into the SecureField sets its binding (got \(password))")
}

// MARK: TextField(_:text:selection:)

nonisolated(unsafe) var composerText = ""
nonisolated(unsafe) var composerSelection: Any?

@available(macOS 15.0, *)
struct SelectionScreen: View {
    var body: some View {
        TextField("Message", text: Binding(get: { composerText }, set: { composerText = $0 }),
                  selection: Binding(get: { composerSelection as? TextSelection }, set: { composerSelection = $0 }))
    }
}

/// The selection as UTF-16 offsets, for comparing.
@available(macOS 15.0, *)
func selectionOffsets() -> String {
    guard let selection = composerSelection as? TextSelection, case .selection(let range) = selection.indices else { return "none" }
    return "\(range.lowerBound.utf16Offset(in: composerText)),\(range.upperBound.utf16Offset(in: composerText))"
}

@MainActor
func checkTextFieldSelection(_ mock: MockRenderer) {
    guard #available(macOS 15.0, *) else { return }
    composerText = "/go"
    composerSelection = nil
    Runtime.shared.fieldSelections = [:]
    Runtime.shared.installRootView { SelectionScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    func field() -> IsoFlat_Node? {
        var buffer = ByteBuffer(bytes: encoder.encode(root: mock.lastTree!))
        Runtime.shared.installTreeHandlers(encoder.handlers)
        return flatNodes(getRoot(byteBuffer: &buffer) as IsoFlat_Node) { $0.kind == .textfield }.first
    }
    func frame() {
        Runtime.shared.setNeedsRender()
        Runtime.shared.renderFrame()
    }
    func report(_ value: String) {
        guard let id = field().flatMap({ param($0, "selId") }) else { return }
        Runtime.shared.hostViewEvent(id: id, value: value)
        frame()
    }
    expect(field().flatMap { param($0, "selId") } != nil, "a field with a selection binding says where to report it")
    expect(field().flatMap { param($0, "sel") } == nil, "and asks for none until the app sets one")

    report("1,3")
    expect(selectionOffsets() == "1,3", "a report sets the binding (\(selectionOffsets()))")
    expect(field().flatMap { param($0, "sel") } == nil, "and is not sent back as a request")

    // A completion: the command and a space, the insertion point after them.
    composerText = "/goal "
    composerSelection = TextSelection(insertionPoint: composerText.endIndex)
    frame()
    expect(field().flatMap { param($0, "sel") } == "6,6,1", "the app's selection is request 1 (\(field().flatMap { param($0, "sel") } ?? "none"))")

    report("6,6")
    expect(field().flatMap { param($0, "sel") } == "6,6,1", "the host showing it asks for nothing new")
    report("2,2")
    expect(selectionOffsets() == "2,2", "the person moving the caret sets the binding")
    expect(field().flatMap { param($0, "sel") } == "6,6,1", "and is no new request (an old one isn't shown again)")

    composerSelection = TextSelection(insertionPoint: composerText.endIndex)
    frame()
    expect(field().flatMap { param($0, "sel") } == "6,6,2", "the same selection asked for again is a new request")

    // A host that reports nothing: the binding follows the end as it types.
    Runtime.shared.fieldSelections = [:]
    composerSelection = nil
    Runtime.shared.installRootView { SelectionScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    if let edit = field()?.edit { Runtime.shared.hostViewEvent(id: edit, value: "/goal x") }
    frame()
    expect(selectionOffsets() == "7,7", "without reports the caret follows the text's end (\(selectionOffsets()))")
    expect(field().flatMap { param($0, "sel") } == nil, "which is not a request")
}

// MARK: sheet(item:onDismiss:)

struct SheetItem: Identifiable { let id: Int }
nonisolated(unsafe) var sheetItem: SheetItem? = nil
nonisolated(unsafe) var sheetDismissals = 0

struct ItemSheetScreen: View {
    var body: some View {
        Text("Home")
            .sheet(item: Binding(get: { sheetItem }, set: { sheetItem = $0 }), onDismiss: { sheetDismissals += 1 }) { item in
                Text("Item \(item.id)")
            }
    }
}

@MainActor
func checkItemSheet(_ mock: MockRenderer) {
    sheetItem = nil
    sheetDismissals = 0
    Runtime.shared.installRootView { ItemSheetScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    expect(!findTextInTree(mock.lastTree!, "Item 7"), "no item, no sheet")
    sheetItem = SheetItem(id: 7)
    Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame()
    expect(findTextInTree(mock.lastTree!, "Item 7"), "the sheet shows the item's content")
    expect(sheetDismissals == 0, "onDismiss waits for the dismissal")
    sheetItem = nil
    Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame()
    Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame()
    expect(!findTextInTree(mock.lastTree!, "Item 7"), "clearing the item dismisses the sheet")
    expect(sheetDismissals == 1, "onDismiss runs once when the sheet goes (got \(sheetDismissals))")
}

// MARK: ForEach($items), onDelete

struct Pet: Identifiable { let id: Int; var name: String }
nonisolated(unsafe) var pets = [Pet(id: 1, name: "Ada"), Pet(id: 2, name: "Bo"), Pet(id: 3, name: "Cy")]

struct PetsScreen: View {
    var body: some View {
        List {
            ForEach(Binding(get: { pets }, set: { pets = $0 })) { $pet in
                TextField("Name", text: $pet.name)
            }
            .onDelete { offsets in pets.remove(atOffsets: offsets) }
        }
    }
}

@MainActor
func checkBindingForEach(_ mock: MockRenderer) {
    pets = [Pet(id: 1, name: "Ada"), Pet(id: 2, name: "Bo"), Pet(id: 3, name: "Cy")]
    Runtime.shared.installRootView { PetsScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    let tree = lastFlatTree(mock, encoder)
    let fields = flatNodes(tree) { $0.kind == .textfield }
    expect(fields.map { $0.v ?? "" } == ["Ada", "Bo", "Cy"], "each row's field shows its element (got \(fields.map { $0.v ?? "" }))")
    Runtime.shared.installTreeHandlers(encoder.handlers)
    if fields.count == 3, let edit = fields[1].edit { Runtime.shared.hostViewEvent(id: edit, value: "Bea") }
    expect(pets.map(\.name) == ["Ada", "Bea", "Cy"], "editing a row's field edits its element (got \(pets.map(\.name)))")
    // `.onDelete`: each row offers Delete as its trailing swipe.
    let swipes = flatNodes(tree) { param($0, "swipeTrailing") != nil }
    expect(swipes.count == 3, "each row can be swiped to delete (got \(swipes.count))")
    if let first = swipes.first, let id = param(first, "swipe") {
        Runtime.shared.hostViewEvent(id: id, value: "0")
    }
    expect(pets.map(\.id) == [2, 3], "a row's Delete removes its element (got \(pets.map(\.id)))")
}

// MARK: Row traits under an app's own modifier (visor's SidebarRow)

nonisolated(unsafe) var sidebarSelection: Int? = 2

struct HighlightRow: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Color.white : Color.primary)
            .listRowInsets(.horizontal, 24)
            .listRowBackground(ZStack {
                Color(white: 0.96)
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 12)
            })
    }
}

struct HighlightScreen: View {
    var body: some View {
        List(selection: Binding(get: { sidebarSelection }, set: { sidebarSelection = $0 })) {
            ForEach(1..<4, id: \.self) { index in
                Text("Row \(index)").tag(index).modifier(HighlightRow(selected: sidebarSelection == index))
            }
        }
    }
}

@MainActor
func checkRowTraitsInModifier(_ mock: MockRenderer) {
    sidebarSelection = 2
    Runtime.shared.installRootView { HighlightScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    let tree = lastFlatTree(mock, encoder)
    let rows = flatNodes(tree) { param($0, "cell") == "row" }
    expect(rows.count == 3, "three rows (got \(rows.count))")
    expect(rows.allSatisfy { param($0, "rowOwnBg") == "1" }, "each row draws its own background")
    expect(rows.allSatisfy { param($0, "rowInsets") == "-,24,-,24" },
           "the horizontal insets are the row's, top and bottom the list's (got \(rows.map { param($0, "rowInsets") ?? "nil" }))")
    expect(rows.map { param($0, "selected") } == [nil, "1", nil], "the tag under the modifier selects the row")
    // A tap selects through the tag under the modifier.
    Runtime.shared.installTreeHandlers(encoder.handlers)
    if let tap = rows.first?.tap { Runtime.shared.hostViewEvent(id: tap, value: "") }
    expect(sidebarSelection == 1, "tapping a row selects its tag (got \(String(describing: sidebarSelection)))")
}

// MARK: Environment

nonisolated(unsafe) var seenPresented: [Bool] = []
nonisolated(unsafe) var seenSearching: [Bool] = []
nonisolated(unsafe) var query = ""

struct EnvironmentProbe: View {
    @Environment(\.isPresented) var isPresented
    @Environment(\.isSearching) var isSearching
    let record: (Bool, Bool) -> Void
    var body: some View {
        record(isPresented, isSearching)
        return Text("Probe")
    }
}

struct EnvironmentScreen: View {
    var body: some View {
        NavigationStack {
            EnvironmentProbe { _, searching in seenSearching.append(searching) }
                .searchable(text: Binding(get: { query }, set: { query = $0 }))
                .sheet(isPresented: .constant(true)) {
                    EnvironmentProbe { presented, _ in seenPresented.append(presented) }
                }
        }
    }
}

@MainActor
func checkEnvironmentValues(_ mock: MockRenderer) {
    seenPresented = []; seenSearching = []; query = ""
    Runtime.shared.installRootView { EnvironmentScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    expect(seenPresented.last == true, "\\.isPresented is true in a sheet's content")
    expect(seenSearching.last == false, "\\.isSearching is false with no query")
    query = "a"
    Runtime.shared.setNeedsRender(); Runtime.shared.renderFrame()
    expect(seenSearching.last == true, "\\.isSearching is true with a query")
}

// MARK: Host modifiers, paths, fonts

struct HalfDisc: Shape {
    // (Isomer's geometry types: Foundation's share the names.)
    func path(in rect: SwiftUI.CGRect) -> Path {
        var path = Path()
        path.addArc(center: SwiftUI.CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: SwiftUI.CGPoint(x: rect.maxX, y: rect.midY), control: SwiftUI.CGPoint(x: rect.midX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

struct HostModifierScreen: View {
    var body: some View {
        ZStack {
            Text("Over").zIndex(1)
            Text("Through").allowsHitTesting(false)
            Text("Soft").blur(radius: 2).help("A tip")
            Button("New") {}.keyboardShortcut("n")
            HalfDisc().fill(Color.blue)
            Ellipse().stroke(lineWidth: 2)
            VStack { Text("Slanted") }.italic().fontDesign(.serif)
            Text("Named").font(.custom("Avenir", size: 14))
        }
    }
}

@MainActor
func checkHostModifiers(_ mock: MockRenderer) {
    Runtime.shared.installRootView { HostModifierScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let tree = lastFlatTree(mock)
    func has(_ key: String, _ value: String) -> Bool { !flatNodes(tree) { param($0, key) == value }.isEmpty }
    expect(has("z", "1"), "zIndex rides its view")
    expect(has("nohit", "1"), "allowsHitTesting(false) rides its view")
    expect(has("blur", "2.0") && has("help", "A tip"), "blur and help ride their view")
    expect(has("shortcut", "cmd+n"), "a keyboard shortcut is named for the hosts")
    let paths = flatNodes(tree) { param($0, "path") != nil }.compactMap { param($0, "path") }
    let arc = paths.first { $0.split(separator: " ").filter { $0 == "L" }.count > 40 }
    expect(arc != nil, "an arc and a curve are drawn as runs of lines (got \(paths.map { $0.prefix(40) }))")
    expect(paths.contains { $0.hasPrefix("E 0 0 1 1") }, "an Ellipse is the ellipse in its frame")
    let slanted = flatNodes(tree) { $0.kind == .text && $0.v == "Slanted" }.first
    expect(slanted.map { param($0, "design") == "serif" && (param($0, "runs") ?? "").contains("i") } == true,
           ".italic() and .fontDesign on a container reach its text")
    expect(has("family", "Avenir"), "Font.custom names its typeface")
}

// MARK: A disabled button

nonisolated(unsafe) var disabledPresses = 0

struct DisabledButtonScreen: View {
    var body: some View {
        Form {
            Button("Connect") { disabledPresses += 1 }.disabled(true)
        }
    }
}

@MainActor
func checkDisabledButton(_ mock: MockRenderer) {
    disabledPresses = 0
    Runtime.shared.installRootView { DisabledButtonScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    let tree = lastFlatTree(mock, encoder)
    Runtime.shared.installTreeHandlers(encoder.handlers)
    for node in flatNodes(tree, where: { $0.tap != nil }) { Runtime.shared.hostViewEvent(id: node.tap!, value: "") }
    expect(disabledPresses == 0, "a disabled button does nothing when pressed (pressed \(disabledPresses))")
    expect(!flatNodes(tree) { param($0, "disabled") == "1" }.isEmpty, "a disabled button says so to the host")
}

// MARK: Styles made from styles

struct DerivedStyleScreen: View {
    var body: some View {
        VStack {
            Rectangle().fill(.secondary)
            Rectangle().fill(.secondary.opacity(0.5))
            Rectangle().fill(Color.red.secondary)
            Circle().foregroundStyle(.secondary.opacity(0.5))
        }
    }
}

@MainActor
func checkDerivedStyles(_ mock: MockRenderer) {
    Runtime.shared.installRootView { DerivedStyleScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let alphas = flatNodes(lastFlatTree(mock)) { $0.fill != nil }.map { Double($0.fill!.a) }
    guard alphas.count == 4 else {
        expect(false, "four filled shapes (found \(alphas.count))")
        return
    }
    func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.01 }
    expect(near(alphas[1], alphas[0] * 0.5), ".secondary.opacity(0.5) fills at half .secondary (\(alphas[1]) vs \(alphas[0]))")
    expect(near(alphas[2], 0.6), "Color.red.secondary is red at the secondary level (\(alphas[2]))")
    expect(near(alphas[3], alphas[0] * 0.5), ".foregroundStyle(.secondary.opacity(0.5)) fills a bare shape (\(alphas[3]))")
}

// MARK: The public host interface (IsomerSwiftUI)

struct ConnectionScreen: View {
    var body: some View { Text("connected") }
}

@MainActor
func checkRuntimeConnection(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ConnectionScreen() }
    guard let connection = IsomerRuntime.connection else {
        expect(false, "the runtime connects itself to IsomerRuntime")
        return
    }
    var sent: [UInt8] = []
    connection.bindTreeRenderer { sent = $0 }
    connection.start(host: StubHost(), width: 390, height: 844)
    expect(!sent.isEmpty, "a tree renderer bound through the connection gets the frame's encoded tree")
    var buffer = ByteBuffer(bytes: sent)
    let patch: IsoFlat_Patch = getRoot(byteBuffer: &buffer)
    expect(patch.ops.count > 0, "the encoded frame is a tree.fbs patch (\(patch.ops.count) ops)")
    // Back to the mock for the checks after this one.
    Renderer.bind(mock)
}

// MARK: Text(AttributedString)

/// AgentUI's inline markdown: links grey, semibold and underlined.
struct AttributedScreen: View {
    var body: some View {
        Text(Self.markdown)
    }

    static var markdown: AttributedString {
        // The runs Apple's parser makes of "See [the notes](…) for the
        // rules.", built by hand: the toolchain's Foundation on Linux
        // parses no markdown.
        var notes = AttributedString("the notes")
        notes.link = URL(string: "https://example.com/notes")
        var attributed = AttributedString("See ") + notes + AttributedString(" for the rules.")
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = .secondary
            attributed[run.range].underlineStyle = .single
            attributed[run.range].font = .body.weight(.semibold)
        }
        return attributed
    }
}

@MainActor
func checkAttributedText(_ mock: MockRenderer) {
    Runtime.shared.installRootView { AttributedScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let texts = flatNodes(lastFlatTree(mock)) { param($0, "runs") != nil }
    guard let text = texts.first, let runs = param(text, "runs") else {
        expect(false, "the attributed string is a text of runs")
        return
    }
    let parts = runs.split(separator: ";").map(String.init)
    expect(parts.count == 3, "a run for each side of the link and one for it (\(runs))")
    let link = parts.count == 3 ? parts[1].split(separator: ":", omittingEmptySubsequences: false) : []
    // length, flags, RGBA, and (a system colour's) its name.
    expect(link.count >= 3, "the link's run has a colour of its own (\(runs))")
    expect(link.count == 4 && link[3] == "secondary", "named as the system's colour it is (\(runs))")
    expect(link.count > 1 && link[1].contains("l") && link[1].contains("u") && link[1].contains("w600"),
           "the link's run is a link, underlined, semibold (\(runs))")
    expect(param(text, "runLinks") == "https://example.com/notes", "the link's URL goes with it")
}

// MARK: .listRowSeparator in a row's content

/// Visor's phone sidebar: a section's header as its first row, its separator
/// hidden from inside the row.
struct InlineHeaderScreen: View {
    var body: some View {
        List {
            Section {
                Text("Snapshot Mac")
                    .font(.headline)
                    .listRowSeparator(.hidden)
                Text("Offline sync")
                Text("Widget layout")
            }
        }
    }
}

/// A section of Visor's phone sidebar: a view whose body is a header-less
/// Section, its header the first row.
struct InlineSection: View {
    let title: String
    let rows: [String]

    var body: some View {
        Section {
            Text(title).listRowSeparator(.hidden)
            ForEach(rows, id: \.self) { Text($0) }
        }
    }
}

struct TwoInlineSectionsScreen: View {
    var body: some View {
        List {
            InlineSection(title: "Snapshot Mac", rows: ["Offline sync", "Computer Settings"])
            InlineSection(title: "Messages", rows: ["Rows now sync"])
        }
    }
}

@MainActor
func checkRowSeparatorTrait(_ mock: MockRenderer) {
    Runtime.shared.installRootView { InlineHeaderScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let rows = flatNodes(lastFlatTree(mock)) { param($0, "listRow") != nil || param($0, "row") != nil }
    let hidden = flatNodes(lastFlatTree(mock)) { param($0, "noSeparator") == "1" }
    expect(hidden.count == 1, "only the header row hides its separator (\(hidden.count) of \(rows.count) rows)")

    // Two views whose bodies are header-less Sections: two groups from the
    // first frame (a semantic host's two sections), not one.
    Runtime.shared.installRootView { TwoInlineSectionsScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let tree = lastFlatTree(mock)
    let texts = flatNodes(tree) { $0.kind == .text }.compactMap(\.v)
    let gaps = flatNodes(tree) { param($0, "cell") == "header" }.count
    expect(texts.firstIndex(of: "Messages") != nil, "both sections' rows are built")
    expect(gaps == 1, "the second section starts its own group (\(gaps) section breaks)")
}

// MARK: Transforms through a reactor's tree (the desktop wasm hosts)

/// A board of cells each `.offset` into place, as 2048 draws it.
struct OffsetBoard: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<4, id: \.self) { index in
                Color.gray
                    .frame(width: 40, height: 40)
                    .offset(x: CGFloat(index % 2) * 48, y: CGFloat(index / 2) * 48)
            }
            Color.blue.frame(width: 10, height: 10).scaleEffect(2)
        }
        .frame(width: 96, height: 96)
    }
}

/// The desktop hosts decode the reactor's flat tree back into render nodes
/// (FlatTreeDecoder): its transforms must survive, or every `.offset` cell
/// draws at its origin (2048's board, one tile on Linux and Windows).
@MainActor
func checkDecodedTransforms(_ mock: MockRenderer) {
    Runtime.shared.installRootView { OffsetBoard() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let bytes = FlatTreeEncoder().encode(root: mock.lastTree!)
    let decoded = FlatTreeDecoder { _, _ in }.decode(bytes: bytes)
    // What the decoded nodes carry, read back through the encoder.
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: decoded))
    let again = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    let offsets = flatNodes(again) { $0.offsetX != nil || $0.offsetY != nil }
        .map { "\(Int($0.offsetX ?? 0)),\(Int($0.offsetY ?? 0))" }
    let scales = flatNodes(again) { $0.scale != nil }.compactMap(\.scale)
    expect(offsets.sorted() == ["0,48", "48,0", "48,48"], "the decoded cells keep their offsets (\(offsets))")
    expect(scales == [2], "and a scaleEffect survives (\(scales))")
}

/// Text interpolated with system colours (the Storybook's highlighted code):
/// each run names its colour, so a host with the system's draws its own.
struct NamedRunScreen: View {
    var body: some View {
        let inner = Text("\(Text(verbatim: "plain ").foregroundColor(.primary))\(Text(verbatim: "red").foregroundColor(.red))")
        // Nested, as the Storybook builds a line token by token.
        Text("\(inner)\(Text(verbatim: " more").foregroundColor(.primary))")
    }
}

@MainActor
func checkNamedRuns(_ mock: MockRenderer) {
    Runtime.shared.installRootView { NamedRunScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let text = flatNodes(lastFlatTree(mock)) { $0.kind == .text }.first
    let runs = text.flatMap { param($0, "runs") } ?? "none"
    let named = runs.split(separator: ";").filter { $0.hasSuffix(":primary") }.count
    expect(named == 2 && runs.contains(":red"), "interpolated runs name their system colours, nested too (\(runs))")
}

// MARK: onScrollPhaseChange

nonisolated(unsafe) var phaseChanges: [String] = []

struct PhaseScreen: View {
    var body: some View {
        ScrollView {
            VStack {
                ForEach(0..<40, id: \.self) { Text("Row \($0)") }
            }
        }
        .onScrollPhaseChange { old, new, context in
            phaseChanges.append("\(old.debugDescription)>\(new.debugDescription)@\(Int(context.geometry.contentOffset.y))"
                + (context.velocity.map { ",\(Int($0.dy))" } ?? ""))
        }
    }
}

@MainActor
func checkScrollPhases(_ mock: MockRenderer) {
    Runtime.shared.installRootView { PhaseScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    let scroll = flatNodes(lastFlatTree(mock, encoder)) { $0.kind == .scroll }.first
    guard let phase = scroll.flatMap({ param($0, "phase") }), let geometry = scroll.flatMap({ param($0, "geometry") }) else {
        expect(false, "a scroll with onScrollPhaseChange asks its host for its phases and geometry")
        return
    }
    Runtime.shared.installTreeHandlers(encoder.handlers)
    // The phase with its geometry, the same phase again (no change), the
    // geometry alone then a phase without it (the last one reported), a
    // velocity, and a name no host sends.
    Runtime.shared.hostViewEvent(id: phase, value: "interacting;0,120,390,1600,390,844,0,0,0,0;")
    Runtime.shared.hostViewEvent(id: phase, value: "interacting")
    Runtime.shared.hostViewEvent(id: geometry, value: "0,300,390,1600,390,844,0,0,0,0")
    Runtime.shared.hostViewEvent(id: phase, value: "decelerating;;0,-900")
    Runtime.shared.hostViewEvent(id: phase, value: "sideways")
    Runtime.shared.hostViewEvent(id: phase, value: "idle")
    let expected = ["idle>interacting@120", "interacting>decelerating@300,-900", "decelerating>idle@300"]
    expect(phaseChanges == expected, "onScrollPhaseChange runs at each change of the host's phase (got \(phaseChanges))")
    expect(ScrollPhase.idle.isScrolling == false && ScrollPhase.tracking.isScrolling && ScrollPhase.animating.isScrolling,
           "every phase but idle is scrolling")
}

// MARK: What Reviews uses: tabular digits, fitting, masks, menus

struct ReviewsAPIScreen: View {
    var body: some View {
        VStack {
            Text("Score: ") + Text("42").monospacedDigit()
            Text("1,234").monospacedDigit()
            Text("A long title").lineLimit(1).minimumScaleFactor(0.5)
            Rectangle().frame(width: 100, height: 50).mask(alignment: .leading) { Circle().frame(width: 50) }
            Menu("Sort") { Button("By name") {} }.menuIndicator(.hidden)
        }
    }
}

@MainActor
func checkReviewsAPIs(_ mock: MockRenderer) {
    Runtime.shared.installRootView { ReviewsAPIScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let tree = lastFlatTree(mock)
    let joined = flatNodes(tree) { $0.kind == .text && $0.v == "Score: 42" }.first.flatMap { param($0, "runs") } ?? "none"
    let joinedRuns = joined.split(separator: ";").map { $0.split(separator: ":").dropFirst().first ?? "" }
    expect(joinedRuns.count == 2 && !joinedRuns[0].contains("t") && joinedRuns[1].contains("t"),
           "monospacedDigit() on one side of a + reaches its run alone (\(joined))")
    expect(flatNodes(tree) { $0.v == "1,234" && param($0, "tnum") == "1" }.count == 1, "a Text's monospacedDigit() is tabular")
    expect(flatNodes(tree) { $0.v == "A long title" && param($0, "minScale") == "0.5" }.count == 1, "minimumScaleFactor rides its text")
    let masks = flatNodes(tree) { param($0, "layer") == "mask" }
    expect(masks.count == 1 && masks.first.flatMap { param($0, "layerAlign") }?.hasPrefix("start") == true,
           "a mask is a layer of its view, at its alignment (\(masks.compactMap { param($0, "layerAlign") }))")
    expect(flatNodes(tree) { param($0, "indicator") == "hidden" }.count == 1, "menuIndicator(.hidden) rides its menu")
}

@MainActor
func checkAPIAdditions(_ mock: MockRenderer) {
    checkReviewsAPIs(mock)
    checkNamedRuns(mock)
    checkScrollPhases(mock)
    checkDecodedTransforms(mock)
    checkRuntimeConnection(mock)
    checkDerivedStyles(mock)
    checkDisabledButton(mock)
    checkHostModifiers(mock)
    checkSecureField(mock)
    checkItemSheet(mock)
    checkBindingForEach(mock)
    checkRowTraitsInModifier(mock)
    checkEnvironmentValues(mock)
    checkAttributedText(mock)
    checkRowSeparatorTrait(mock)
    checkTextFieldSelection(mock)
    checkToggleStyles(mock)
    checkAccessibilityText(mock)
    checkTemplateImages(mock)
    checkPathArcs()
    checkDragPrediction()
    checkBackButtonHidden(mock)
    checkPathInFrame(mock)
    checkGesturePriorities(mock)
}

// MARK: ToggleStyle

/// An app's style that keeps the switch and adds a caption beside it.
struct CaptionedSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            Text(configuration.isOn ? "caption on" : "caption off")
            Toggle(configuration)
        }
    }
}

/// An app's style with no switch at all: a button that flips the value.
struct TapToFlipStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label
                Text(configuration.isOn ? "is ON" : "is OFF")
            }
        }
    }
}

struct ToggleStyleScreen: View {
    @State private var alpha = false
    @State private var beta = true
    var body: some View {
        VStack {
            Toggle("Alpha", isOn: $alpha).toggleStyle(CaptionedSwitchStyle())
            Toggle("Beta", isOn: $beta).toggleStyle(TapToFlipStyle())
            Toggle("Gamma", isOn: .constant(true)).toggleStyle(.switch)
            Toggle("Delta", isOn: .constant(false))
            // Styles compose: the captioned style's inner Toggle is drawn
            // by the style around it.
            VStack {
                Toggle("Epsilon", isOn: .constant(false)).toggleStyle(CaptionedSwitchStyle())
            }
            .toggleStyle(TapToFlipStyle())
        }
    }
}

@MainActor
func checkToggleStyles(_ mock: MockRenderer) {
    let verifying = Runtime.shared.verifyPartialFrames
    Runtime.shared.verifyPartialFrames = true
    defer { Runtime.shared.verifyPartialFrames = verifying }
    let mismatches = Runtime.shared.partialMismatches
    Runtime.shared.installRootView { ToggleStyleScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    var frame = HostFrame(mock.lastTree!)
    let switches = frame.hostViews("toggle")
    expect(switches.count == 3, "the captioned style's inner Toggle, .switch and the default draw switches; the button styles none (got \(switches.count))")
    expect(countFlatTexts(frame.root, "caption off") == 2 && frame.shows("Alpha"), "a custom style's body replaces the toggle, its inner Toggle keeping the label")
    expect(frame.shows("Beta") && frame.shows("is ON"), "the button style shows its label and state")
    expect(frame.tapTarget("Epsilon") != nil && frame.shows("is OFF"), "a style's inner Toggle takes the style around it")
    // The inner switch flips the style's binding.
    frame.send(switches.first?.edit, "1")
    frame = HostFrame(mock.lastTree!)
    expect(frame.shows("caption on"), "the inner switch writes through the configuration's binding")
    // The button style flips its own.
    frame.tap("is ON")
    frame = HostFrame(mock.lastTree!)
    expect(frame.shows("is OFF"), "a custom style's button flips $isOn")
    expect(Runtime.shared.partialMismatches == mismatches, "frames built in place match whole builds")
}

// MARK: accessibility

struct AccessibilityTextScreen: View {
    var body: some View {
        VStack {
            Image(systemName: "star").accessibilityLabel(Text("Favourite")).accessibilityHint(Text("Adds it"))
                .accessibilityValue(Text("3 stars"))
            Rectangle().frame(width: 20, height: 20)
                .accessibilityRepresentation { Toggle("Represented", isOn: .constant(true)) }
        }
    }
}

@MainActor
func checkAccessibilityText(_ mock: MockRenderer) {
    Runtime.shared.installRootView { AccessibilityTextScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let root = lastFlatTree(mock)
    let labels = allParams(root, key: "a11yLabel")
    func has(_ text: String) -> Bool { flatNodes(root) { node in node.params.contains { $0.value == text } }.count > 0 }
    expect(has("Favourite") && has("Adds it") && has("3 stars"), "Text label, hint and value cross as words (\(labels))")
    expect(has("Represented"), "a representation's label crosses over")
}

// MARK: Image.renderingMode

struct TemplateImageScreen: View {
    var body: some View {
        VStack {
            Image("icon").renderingMode(.template).foregroundStyle(Color.red)
            Image("icon").renderingMode(.original)
            Image("icon")
        }
    }
}

@MainActor
func checkTemplateImages(_ mock: MockRenderer) {
    Runtime.shared.installRootView { TemplateImageScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let images = flatNodes(lastFlatTree(mock)) { $0.kind == .image }
    expect(images.count == 3 && param(images[0], "template")?.hasPrefix("#ff") == true
           && param(images[1], "template") == nil && param(images[2], "template") == nil,
           "only the template image carries its colour (got \(images.map { param($0, "template") }))")
}

// MARK: Path arcs and curves

@MainActor
func checkPathArcs() {
    func close(_ a: CGPoint?, _ b: CGPoint, _ tolerance: CGFloat = 0.01) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }
    // A quarter turn from the x axis toward +y ends at (0, r).
    var arc = Path()
    arc.addArc(center: .zero, radius: 10, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
    expect(close(arc.currentPoint, CGPoint(x: 0, y: 10)), "addArc ends at its end angle (\(String(describing: arc.currentPoint)))")
    var relative = Path()
    relative.addRelativeArc(center: .zero, radius: 10, startAngle: .degrees(0), delta: .degrees(-90))
    expect(close(relative.currentPoint, CGPoint(x: 0, y: -10)), "addRelativeArc turns by its delta")
    // A rounded corner: from (0,0) toward (10,0), turning down to (10,10).
    var corner = Path()
    corner.move(to: .zero)
    corner.addArc(tangent1End: CGPoint(x: 10, y: 0), tangent2End: CGPoint(x: 10, y: 10), radius: 4)
    expect(close(corner.currentPoint, CGPoint(x: 10, y: 4)), "the tangent arc ends where it meets the second line")
    expect(corner.boundingRect.maxX <= 10.01 && corner.boundingRect.minY >= -0.01, "the tangent arc stays inside the corner")
    var curves = Path()
    curves.move(to: .zero)
    curves.addQuadCurve(to: CGPoint(x: 10, y: 0), control: CGPoint(x: 5, y: 10))
    curves.addCurve(to: CGPoint(x: 20, y: 0), control1: CGPoint(x: 12, y: -10), control2: CGPoint(x: 18, y: -10))
    expect(close(curves.currentPoint, CGPoint(x: 20, y: 0)), "curves end at their ends")
    expect(abs(curves.boundingRect.maxY - 5) < 0.1, "the quadratic peaks halfway to its control (\(curves.boundingRect))")
    // A Core Graphics capsule: two arcs and two lines.
    let capsule = CGMutablePath()
    capsule.addArc(center: CGPoint(x: 10, y: 10), radius: 10, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    capsule.addArc(center: CGPoint(x: 30, y: 10), radius: 10, startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: false)
    capsule.closeSubpath()
    let fromCG = Path(capsule)
    let box = fromCG.boundingRect
    expect(abs(box.minX) < 0.05 && abs(box.maxX - 40) < 0.05 && abs(box.minY) < 0.05 && abs(box.maxY - 20) < 0.05,
           "Path(CGPath) keeps a capsule's bounds (\(box))")
    expect(fromCG.cgPath.boundingBoxOfPath.width > 39.9, "and goes back to a CGPath")
}

// MARK: DragGesture's prediction

@MainActor
func checkDragPrediction() {
    var tracker = DragGesture.VelocityTracker()
    _ = tracker.add(CGPoint(x: 0, y: 0), at: 1.0)
    _ = tracker.add(CGPoint(x: 10, y: 0), at: 1.05)
    let velocity = tracker.add(CGPoint(x: 20, y: 0), at: 1.1)
    expect(abs(velocity.width - 200) < 0.5 && velocity.height == 0, "200 pt/s across (got \(velocity))")
    let value = DragGesture.Value(startLocation: .zero, location: CGPoint(x: 20, y: 0), velocity: velocity)
    expect(abs(value.predictedEndTranslation.width - 70) < 0.5, "the prediction runs on a quarter second (\(value.predictedEndTranslation))")
    expect(abs(value.velocity.width - 200) < 0.5, "and gives the velocity back")
    // A finger held still before letting go flings nothing.
    let still = tracker.add(CGPoint(x: 20, y: 0), at: 1.5)
    expect(still == .zero, "a pause brings the velocity to rest (\(still))")
}

// MARK: navigationBarBackButtonHidden

struct BackHiddenScreen: View {
    var body: some View {
        NavigationStack(path: .constant([1])) {
            Text("Root")
                .navigationDestination(for: Int.self) { number in
                    Text("Screen \(number)").navigationTitle("Pushed").navigationBarBackButtonHidden()
                }
        }
    }
}

@MainActor
func checkBackButtonHidden(_ previous: MockRenderer) {
    Runtime.shared.installRootView { BackHiddenScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let semantic = lastFlatTree(previous)
    expect(findParam(semantic, key: "backHidden") == "1", "a host's own stack hears the Back is hidden")
    let drawing = DrawingMockRenderer()
    Renderer.bind(drawing)
    defer { Renderer.bind(previous) }
    Runtime.shared.installRootView { BackHiddenScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let drawn = HostFrame(drawing.lastTree!)
    expect(drawn.shows("Screen 1"), "the pushed screen shows")
    expect(flatNavbarParam(drawn.root, "back") == "0", "the drawn bar has no Back")
}

// MARK: a shape asked for its path in its own size

/// A pill from Core Graphics arcs, its radius half the height it is given.
struct CGPillShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let pill = CGMutablePath()
        pill.addArc(center: CGPoint(x: rect.minX + radius, y: rect.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        pill.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.midY), radius: radius,
                    startAngle: 3 * .pi / 2, endAngle: .pi / 2, clockwise: false)
        pill.closeSubpath()
        return Path(pill)
    }
}

struct PillScreen: View {
    var body: some View {
        CGPillShape().fill(Color.blue).frame(width: 100, height: 20)
    }
}

@MainActor
func checkPathInFrame(_ mock: MockRenderer) {
    Runtime.shared.installRootView { PillScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let shapes = flatNodes(lastFlatTree(mock)) { $0.kind == .shape }
    guard let text = shapes.first.flatMap({ param($0, "path") }) else { return expect(false, "the pill carries a path") }
    // Its top edge: the points on y = 0 run from one end's radius to the other's.
    let numbers = text.split(separator: " ").compactMap { Double($0) }
    var top: [Double] = []
    var i = 0
    while i + 1 < numbers.count {
        if abs(numbers[i + 1]) < 0.001 { top.append(numbers[i]) }
        i += 2
    }
    expect(abs((top.min() ?? 0) - 0.1) < 0.01 && abs((top.max() ?? 0) - 0.9) < 0.01,
           "the pill's ends are as round as it is tall in its 100 x 20 frame (top edge \(top.min() ?? -1)...\(top.max() ?? -1))")
}

// MARK: Gesture priorities, springs and accessibility actions

struct GesturePrioritiesScreen: View {
    var body: some View {
        VStack {
            Rectangle().frame(height: 100).highPriorityGesture(DragGesture())
            Rectangle().frame(height: 100).simultaneousGesture(DragGesture(), isEnabled: false)
            Rectangle().frame(height: 100)
                .accessibilityAction { }
                .accessibilityAction(.escape) { }
                .accessibilityAction(named: "Archive") { }
                .accessibilityAction(named: Text("Delete")) { }
        }
        // `.spring()` resolves (Apple's response spring is disfavoured), as do
        // the interactive springs.
        .animation(.spring(), value: 1)
        .animation(.interactiveSpring, value: 2)
        .animation(.interactiveSpring(response: 0.2), value: 3)
    }
}

@MainActor
func checkGesturePriorities(_ mock: MockRenderer) {
    Runtime.shared.installRootView { GesturePrioritiesScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let encoder = FlatTreeEncoder()
    _ = lastFlatTree(mock, encoder)
    let drags = encoder.handlers.keys.filter { $0.hasSuffix(".drag") }.count
    expect(drags == 1, "a high-priority gesture recognizes and a disabled simultaneous one doesn't (\(drags) drag handlers)")
    expect(AccessibilityActionKind(named: Text("Archive")) != .default, "a named action kind is its own")
}

/// An elliptical gradient travels as a radial one with its radii fractions
/// ("ell"), and the desktop hosts' decoder keeps them; `Color.gradient`
/// fills top to bottom, lighter at the top.
struct EllipticalScreen: View {
    var body: some View {
        VStack {
            Rectangle().fill(.ellipticalGradient(colors: [.white, .blue], startRadiusFraction: 0.1, endRadiusFraction: 0.6))
                .frame(width: 100, height: 50)
            Rectangle().fill(Color.green.gradient).frame(width: 100, height: 50)
        }
    }
}

@MainActor
func checkEllipticalGradient(_ mock: MockRenderer) {
    Runtime.shared.installRootView { EllipticalScreen() }
    Runtime.shared.start(host: StubHost(), width: 390, height: 844)
    let gradients = flatNodes(lastFlatTree(mock)) { $0.gradient != nil }.compactMap(\.gradient)
    expect(gradients.contains { $0.contains("\"kind\":\"radial\"") && $0.contains("\"ell\":[0.1,0.6]") },
           "an elliptical gradient's fractions travel (\(gradients))")
    expect(gradients.contains { $0.contains("\"kind\":\"linear\"") && $0.contains("\"p0\":[0.5,0]") },
           "Color.gradient fills top to bottom (\(gradients))")
    let decoded = FlatTreeDecoder { _, _ in }.decode(bytes: FlatTreeEncoder().encode(root: mock.lastTree!))
    var buffer = ByteBuffer(bytes: FlatTreeEncoder().encode(root: decoded))
    let again = getRoot(byteBuffer: &buffer) as IsoFlat_Node
    let kept = flatNodes(again) { $0.gradient?.contains("\"ell\":[0.1,0.6]") == true }
    expect(!kept.isEmpty, "and the decoder keeps them")
}

/// A DatePicker's value in the user's calendar: its date and time sent to
/// the host as parts, and a host's change to one keeping the other.
@MainActor
func checkDatePickerValue(_ mock: MockRenderer) {
    var parts = DateComponents()
    parts.year = 2026
    parts.month = 11
    parts.day = 1
    parts.hour = 7
    parts.minute = 30
    let start = Calendar.current.date(from: parts)!
    let value = DatePickerValue(start)
    expect(value.date == "2026-11-01" && value.time == "07:30", "the date and time sent (\(value.date) \(value.time))")
    let newDay = DatePickerValue.date(start, changedBy: "2026-12-25").map(DatePickerValue.init)
    expect(newDay?.date == "2026-12-25" && newDay?.time == "07:30", "a new date keeps the time")
    let newTime = DatePickerValue.date(start, changedBy: "time:18:05").map(DatePickerValue.init)
    expect(newTime?.date == "2026-11-01" && newTime?.time == "18:05", "a new time keeps the date")
    let both = DatePickerValue.date(start, changedBy: "2027-01-02T09:15").map(DatePickerValue.init)
    expect(both?.date == "2027-01-02" && both?.time == "09:15", "both at once")
    expect(DatePickerValue.date(start, changedBy: "nonsense") == nil, "a value of neither form is refused")
}
