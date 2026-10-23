// Checks for SwiftUI API Isomer gained from the API audit
// (docs/swiftui_api_audit.md): each builds a screen with the mock renderer
// and asserts on the tree, the serialized form, or what a host event does.

import FlatBuffers
import Foundation
import IsomerCore
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
    func path(in rect: IsomerCore.CGRect) -> Path {
        var path = Path()
        path.addArc(center: IsomerCore.CGPoint(x: rect.midX, y: rect.midY), radius: rect.width / 2,
                    startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        path.addQuadCurve(to: IsomerCore.CGPoint(x: rect.maxX, y: rect.midY), control: IsomerCore.CGPoint(x: rect.midX, y: rect.minY))
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
        var attributed = try! AttributedString(markdown: "See [the notes](https://example.com/notes) for the rules.")
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

@MainActor
func checkAPIAdditions(_ mock: MockRenderer) {
    checkNamedRuns(mock)
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
}
