// What the corpus is made of: SwiftUI's pieces as Swift snippets that compile
// in any generated screen. Every screen declares the same state (State.all),
// so a piece may use any of it:
//
//   count: Int, flag: Bool, level: Double, name: String, choice: Int,
//   items: [Int], tick: Int (the screen's timer), drag: CGSize, show: Bool,
//   date: Date; and `model`, the app's @Observable (CorpusModel).
//
// The pieces lean on state, so the screen's timer and the driver's events
// change what they draw: a render then rebuilds, re-lays out and re-encodes
// them, which is the runtime work the corpus is for.

struct Piece {
    let name: String
    /// The view, an expression of type `some View`.
    let code: String
}

struct Modifier {
    let name: String
    /// Appended to a view: `.padding(…)`.
    let code: String
}

struct Container {
    let name: String
    /// Wraps the items: `{items}` is replaced with them, one a line; `{tabs}`
    /// with them as tabs.
    let code: String
    /// How an item is wrapped inside the container (`{item}`), and its
    /// index (`{j}`).
    let item: String
}

/// A screen-level pattern: a modifier on the screen's container.
struct Pattern {
    let name: String
    let code: String
}

enum Catalog {
    static let state = """
            @State private var count = 0
            @State private var flag = false
            @State private var level = 0.3
            @State private var name = "corpus"
            @State private var choice = 0
            @State private var items: [Int] = [1, 2, 3]
            @State private var tick = 0
            @State private var drag = CGSize.zero
            @State private var show = false
            @State private var date = Date(timeIntervalSince1970: 1_700_000_000)
            @State private var selection: Int?
            @Environment(CorpusModel.self) private var model
        """

    static let pieces: [Piece] = [
        Piece(name: "text", code: #"Text("Item \(count) \(name)")"#),
        Piece(name: "formattedText", code: #"Text(String(format: "%.2f · %d", level, tick))"#),
        Piece(name: "modelText", code: #"Text("Model \(model.tick) · \(model.events.count)")"#),
        Piece(name: "image", code: #"Image(systemName: flag ? "star.fill" : "star")"#),
        Piece(name: "button", code: #"Button("Add \(count)") { withAnimation { count += 1; items.append(count) } }"#),
        Piece(name: "borderedButton", code: #"Button("Flip") { flag.toggle(); model.events.append(count) }.buttonStyle(.borderedProminent)"#),
        Piece(name: "toggle", code: #"Toggle("Flag \(flag ? 1 : 0)", isOn: $flag)"#),
        Piece(name: "slider", code: #"Slider(value: $level, in: 0...1)"#),
        Piece(name: "stepper", code: #"Stepper("Count \(count)", value: $count, in: 0...50)"#),
        Piece(name: "textField", code: #"TextField("Name", text: $name)"#),
        Piece(name: "secureField", code: #"SecureField("Secret", text: $name)"#),
        Piece(name: "textEditor", code: #"TextEditor(text: $name).frame(height: 60)"#),
        Piece(name: "picker", code: #"Picker("Choice", selection: $choice) { ForEach(0..<4, id: \.self) { Text("Option \($0)").tag($0) } }"#),
        Piece(name: "segmented", code: #"Picker("Mode", selection: $choice) { ForEach(0..<3, id: \.self) { Text("M\($0)").tag($0) } }.pickerStyle(.segmented)"#),
        Piece(name: "datePicker", code: #"DatePicker("Day", selection: $date, displayedComponents: .date)"#),
        Piece(name: "menu", code: #"Menu("Menu \(choice)") { Button("One") { choice = 1 }; Button("Two") { choice = 2 } }"#),
        Piece(name: "progress", code: #"ProgressView(value: level)"#),
        Piece(name: "spinner", code: #"ProgressView()"#),
        Piece(name: "label", code: #"Label("Starred \(count)", systemImage: "star")"#),
        Piece(name: "roundedRect", code: #"RoundedRectangle(cornerRadius: 8).fill(flag ? Color.blue : Color.orange).frame(width: 44, height: 44)"#),
        Piece(name: "circleStroke", code: #"Circle().stroke(Color.green, lineWidth: 3).frame(width: 40, height: 40)"#),
        Piece(name: "gradientCapsule", code: #"Capsule().fill(LinearGradient(colors: [.red, .purple], startPoint: .leading, endPoint: .trailing)).frame(width: 80, height: 24)"#),
        Piece(name: "shapePath", code: #"CorpusWave(level: level).stroke(Color.red, lineWidth: 2).frame(width: 80, height: 40)"#),
        Piece(name: "colorRow", code: #"HStack(spacing: 2) { ForEach(0..<6, id: \.self) { k in Color(red: Double(k) / 6, green: 0.5, blue: 0.8).frame(width: 12, height: 12) } }"#),
        Piece(name: "dragTile", code: #"RoundedRectangle(cornerRadius: 6).fill(Color.teal).frame(width: 50, height: 50).offset(x: drag.width, y: drag.height).gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { _ in withAnimation(.easeOut(duration: 0.2)) { drag = .zero } })"#),
        Piece(name: "tapShape", code: #"Circle().fill(flag ? Color.pink : Color.gray).frame(width: 36, height: 36).onTapGesture { withAnimation { flag.toggle() } }"#),
        Piece(name: "longPress", code: #"Text("Hold \(count)").padding(6).onLongPressGesture { count += 2 }"#),
        Piece(name: "rows", code: #"VStack(alignment: .leading) { ForEach(items, id: \.self) { Text("Row \($0)") } }"#),
        Piece(name: "conditional", code: #"Group { if flag { Text("Shown \(count)").transition(.opacity) } else { Image(systemName: "eye.slash") } }"#),
        Piece(name: "navigationLink", code: #"NavigationLink("Detail \(count)") { Text("Detail \(count)").navigationTitle("Detail") }"#),
        Piece(name: "disclosure", code: #"DisclosureGroup("More", isExpanded: $show) { Text("Hidden \(count)") }"#),
        Piece(name: "geometry", code: #"GeometryReader { g in Text("w \(Int(g.size.width))") }.frame(height: 30)"#),
        Piece(name: "viewThatFits", code: #"ViewThatFits { Text("A long line of text \(count) that may not fit in the row"); Text("Short") }"#),
        Piece(name: "anyView", code: #"(flag ? AnyView(Text("Any \(count)")) : AnyView(Image(systemName: "a.circle")))"#),
        Piece(name: "lazyGrid", code: #"LazyVGrid(columns: [GridItem(.adaptive(minimum: 40))]) { ForEach(0..<8, id: \.self) { k in Color.blue.opacity(Double(k) / 8).frame(height: 20) } }"#),
        Piece(name: "textRuns", code: #"(Text("Sum ") + Text("\(count)").bold() + Text(" items").italic() + Text(" ok").foregroundColor(.green))"#),
        Piece(name: "markdown", code: #"Text("**Bold \(count)** and _italic_ and `code`")"#),
        Piece(name: "attributed", code: #"Text(AttributedString("Attributed \(name)"))"#),
        Piece(name: "longText", code: #"Text(String(repeating: "A longer paragraph of text that wraps across lines. ", count: 3 + count % 4)).multilineTextAlignment(.leading)"#),
        Piece(name: "longList", code: #"VStack(alignment: .leading, spacing: 2) { ForEach(0..<(30 + count % 10), id: \.self) { k in HStack { Image(systemName: "circle"); Text("Row \(k)"); Spacer(); Text("\(k * count)") } } }"#),
        Piece(name: "identifiableRows", code: #"VStack(alignment: .leading) { ForEach(CorpusRow.rows(count)) { row in Label(row.title, systemImage: row.symbol) } }"#),
        Piece(name: "binding", code: #"CorpusCounter(count: $count, flag: $flag)"#),
        Piece(name: "generic", code: #"CorpusCard(title: "Card \(choice)") { Text("Inside \(tick)") }"#),
    ]

    static let modifiers: [Modifier] = [
        Modifier(name: "padding", code: ".padding(CGFloat(4 + count % 8))"),
        Modifier(name: "frameFill", code: ".frame(maxWidth: .infinity, alignment: .leading)"),
        Modifier(name: "frameWidth", code: ".frame(width: 160 + CGFloat(count % 5) * 10)"),
        Modifier(name: "background", code: ".background(flag ? Color.yellow.opacity(0.3) : Color.clear)"),
        Modifier(name: "foreground", code: ".foregroundStyle(flag ? Color.blue : Color.primary)"),
        Modifier(name: "font", code: ".font(flag ? .headline : .body)"),
        Modifier(name: "opacity", code: ".opacity(0.5 + level / 2)"),
        Modifier(name: "offset", code: ".offset(x: CGFloat(tick % 6) * 2)"),
        Modifier(name: "scale", code: ".scaleEffect(1 + CGFloat(tick % 4) * 0.05)"),
        Modifier(name: "rotation", code: ".rotationEffect(.degrees(Double(tick % 8) * 5))"),
        Modifier(name: "clipShape", code: ".clipShape(RoundedRectangle(cornerRadius: 6))"),
        Modifier(name: "cornerRadius", code: ".cornerRadius(4)"),
        Modifier(name: "shadow", code: ".shadow(radius: flag ? 4 : 0)"),
        Modifier(name: "overlay", code: ".overlay(alignment: .topTrailing) { Circle().fill(Color.red).frame(width: 6, height: 6) }"),
        Modifier(name: "border", code: ".border(Color.gray)"),
        Modifier(name: "animation", code: ".animation(.easeInOut(duration: 0.2), value: tick)"),
        Modifier(name: "disabled", code: ".disabled(choice == 3)"),
        Modifier(name: "tint", code: ".tint(.purple)"),
        Modifier(name: "contextMenu", code: #".contextMenu { Button("Copy") { count += 1 } }"#),
        Modifier(name: "zIndex", code: ".zIndex(Double(choice))"),
        Modifier(name: "fixedSize", code: ".fixedSize()"),
        Modifier(name: "lineLimit", code: ".lineLimit(1)"),
        Modifier(name: "blur", code: ".blur(radius: flag ? 1 : 0)"),
        Modifier(name: "mask", code: ".mask { RoundedRectangle(cornerRadius: 8) }"),
        Modifier(name: "onChange", code: ".onChange(of: flag) { count += 1 }"),
        Modifier(name: "id", code: ".id(choice)"),
        Modifier(name: "accessibility", code: #".accessibilityLabel("Piece \(count)")"#),
        Modifier(name: "accessibilityIdentifier", code: #".accessibilityIdentifier("piece.\(choice)")"#),
        Modifier(name: "backgroundView", code: ".background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.1)))"),
        Modifier(name: "tapGesture", code: ".onTapGesture { level = level < 0.9 ? level + 0.1 : 0 }"),
    ]

    static let containers: [Container] = [
        Container(name: "vstack", code: "VStack(alignment: .leading, spacing: 8) {\n{items}\n}", item: "{item}"),
        Container(name: "hscroll", code: "ScrollView(.horizontal) { HStack(spacing: 6) {\n{items}\n} }", item: "{item}"),
        Container(name: "zstack", code: "ZStack(alignment: .topLeading) {\n{items}\n}", item: "{item}.offset(y: CGFloat({j}) * 40)"),
        Container(name: "lazyVStack", code: "ScrollView { LazyVStack(spacing: 10) {\n{items}\n} }", item: "{item}"),
        Container(name: "list", code: "List {\n{items}\n}", item: "{item}"),
        Container(name: "form", code: "Form { Section(\"Section \\(count)\") {\n{items}\n} }", item: "{item}"),
        Container(name: "grid", code: "Grid(alignment: .leading) {\n{items}\n}", item: "GridRow { Text(\"{j}\"); {item} }"),
        Container(name: "tabs", code: "TabView(selection: $choice) {\n{items}\n}", item: "{item}.tabItem { Label(\"T{j}\", systemImage: \"circle\") }.tag({j})"),
        Container(name: "group", code: "ScrollView { VStack { Group {\n{items}\n} } }", item: "{item}"),
        Container(name: "selectableList", code: "List(selection: $selection) {\n{items}\nSection(\"Rows\") { ForEach(CorpusRow.rows(count)) { row in Text(row.title).tag(row.id) } }\n}", item: "Section(\"Item {j}\") { {item} }"),
        Container(name: "hstackWrap", code: "VStack { HStack {\n{items}\n} }", item: "{item}"),
    ]

    static let patterns: [Pattern] = [
        Pattern(name: "plain", code: ""),
        Pattern(name: "sheet", code: #".sheet(isPresented: $show) { VStack { Text("Sheet \(count)"); Button("Close") { show = false } } }"#),
        Pattern(name: "alert", code: #".alert("Alert \(count)", isPresented: $show) { Button("OK") { count += 1 } }"#),
        Pattern(name: "searchable", code: #".searchable(text: $name)"#),
        Pattern(name: "toolbar", code: #".toolbar { ToolbarItem { Button("Plus") { count += 1 } } }"#),
        Pattern(name: "confirmation", code: #".confirmationDialog("Choose", isPresented: $show) { Button("A") { choice = 1 }; Button("B") { choice = 2 } }"#),
        Pattern(name: "refreshable", code: #".refreshable { count += 1 }"#),
        Pattern(name: "safeArea", code: #".safeAreaInset(edge: .bottom) { Text("Inset \(tick)").padding(4) }"#),
    ]
}
