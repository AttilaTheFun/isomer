// Lists and forms: sections, selection, row actions, forms, outlines,
// search and empty states.

import SwiftUI

extension StoryCatalog {
    static let lists = StoryArea(id: "lists", title: "Lists and Forms", symbol: "list.bullet", stories: [
        Story(
            "lists.sections", "List and Section", apis: ["List", "Section(_:content:)", "ForEach(_:id:content:)"],
            height: 340,
            summary: "Rows in sections with headers. A list is the platform's own: grouped and inset on iOS, Material rows on Android."
        ) { ListSectionsStory() },
        Story(
            "lists.selection", "Selection", apis: ["List(selection:content:)", ".tag(_:)"],
            height: 300,
            summary: "A list whose rows select a value: the row tagged with it is highlighted."
        ) { ListSelectionStory() },
        Story(
            "lists.actions", "Row actions", apis: [".swipeActions(edge:allowsFullSwipe:content:)", ".onDelete(perform:)", ".contextMenu(menuItems:)"],
            height: 300,
            summary: "Actions on a row: swiped from its edge, deleted with a full swipe, or chosen from its context menu (a long press, or a secondary click)."
        ) { RowActionsStory() },
        Story(
            "lists.form", "Form", apis: ["Form", "Section(_:content:footer:)", "LabeledContent(_:value:)", ".formStyle(_:)"],
            height: 440,
            summary: "Settings-style rows of controls in grouped sections, with labeled values and footers."
        ) { FormStory() },
        Story(
            "lists.outline", "Outlines", apis: ["OutlineGroup(_:children:content:)", "DisclosureGroup(_:isExpanded:content:)", "List(_:children:rowContent:)"],
            height: 340,
            summary: "A tree shown as rows that expand to show their children, and a single group that shows and hides its content."
        ) { OutlineStory() },
        Story(
            "lists.search", "Searchable", apis: [".searchable(text:prompt:)"],
            height: 300,
            summary: "A search field in the navigation bar that filters what the page lists."
        ) { SearchStory() },
        Story(
            "lists.empty", "ContentUnavailableView", apis: ["ContentUnavailableView(_:systemImage:description:)", "ContentUnavailableView(label:description:actions:)"],
            summary: "What a screen shows when it has nothing to show: a symbol, a title, a description, and what to do about it."
        ) { EmptyStateStory() },
    ])
}

// story: lists.sections
struct ListSectionsStory: View {
    private let fruits = ["Apple", "Banana", "Cherry"]
    private let vegetables = ["Carrot", "Leek", "Potato", "Spinach"]

    var body: some View {
        List {
            Section("Fruits") {
                ForEach(fruits, id: \.self) { Text($0) }
            }
            Section("Vegetables") {
                ForEach(vegetables, id: \.self) { name in
                    Label(name, systemImage: "leaf")
                }
            }
        }
    }
}
// end story

// story: lists.selection
struct ListSelectionStory: View {
    @State private var selection: String? = "Matcha"
    private let flavors = ["Vanilla", "Chocolate", "Strawberry", "Matcha", "Mango"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Selected: \(selection ?? "none")")
                .font(.headline)
                .padding(.bottom, 8)
            List(selection: $selection) {
                ForEach(flavors, id: \.self) { flavor in
                    Text(flavor).tag(flavor)
                }
            }
        }
    }
}
// end story

// story: lists.actions
struct RowActionsStory: View {
    @State private var mail = ["Lunch on Friday?", "Your order has shipped", "Build 0.38 passed", "Weekly report", "Re: the icon"]
    @State private var flagged: Set<String> = []

    var body: some View {
        List {
            ForEach(mail, id: \.self) { subject in
                HStack {
                    Text(subject)
                    Spacer()
                    if flagged.contains(subject) {
                        Image(systemName: "flag.fill").foregroundColor(.orange)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Flag") { toggleFlag(subject) }
                        .tint(.orange)
                }
                .contextMenu {
                    Button("Flag") { toggleFlag(subject) }
                    Button("Delete", role: .destructive) { mail.removeAll { $0 == subject } }
                }
            }
            .onDelete { mail.remove(atOffsets: $0) }
        }
    }

    private func toggleFlag(_ subject: String) {
        if flagged.contains(subject) { flagged.remove(subject) } else { flagged.insert(subject) }
    }
}
// end story

// story: lists.form
struct FormStory: View {
    @State private var name = "Ada"
    @State private var notifications = true
    @State private var frequency = "Daily"
    @State private var volume = 0.5

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Name", text: $name)
                LabeledContent("Member since", value: "2026")
            }
            Section {
                Toggle("Notifications", isOn: $notifications)
                Picker("Frequency", selection: $frequency) {
                    ForEach(["Hourly", "Daily", "Weekly"], id: \.self) { Text($0).tag($0) }
                }
                Slider(value: $volume)
            } header: {
                Text("Alerts")
            } footer: {
                Text("Alerts arrive at most \(frequency.lowercased()).")
            }
        }
        .formStyle(.grouped)
    }
}
// end story

// story: lists.outline
struct OutlineStory: View {
    struct Node: Identifiable {
        let name: String
        var children: [Node]?
        var id: String { name }
    }

    private let tree = [
        Node(name: "Sources", children: [
            Node(name: "App.swift"),
            Node(name: "Views", children: [Node(name: "List.swift"), Node(name: "Form.swift")]),
        ]),
        Node(name: "README.md"),
    ]
    @State private var expanded = true

    var body: some View {
        List {
            OutlineGroup(tree, children: \.children) { node in
                Label(node.name, systemImage: node.children == nil ? "doc" : "folder")
            }
            DisclosureGroup("Advanced", isExpanded: $expanded) {
                Text("Shown while the group is expanded.")
            }
        }
    }
}
// end story

// story: lists.search
struct SearchStory: View {
    @State private var query = ""
    private let cities = ["Amsterdam", "Berlin", "Lisbon", "London", "Madrid", "Oslo", "Paris", "Rome", "Vienna"]

    var body: some View {
        List {
            ForEach(cities.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { city in
                Text(city)
            }
        }
        .searchable(text: $query, prompt: "Search cities")
    }
}
// end story

// story: lists.empty
struct EmptyStateStory: View {
    var body: some View {
        VStack(spacing: 24) {
            ContentUnavailableView(
                "No Messages",
                systemImage: "tray",
                description: Text("Messages you receive appear here.")
            )
            ContentUnavailableView {
                Label("No Connection", systemImage: "wifi.slash")
            } description: {
                Text("Check the network and try again.")
            } actions: {
                Button("Retry") {}
                    .buttonStyle(.bordered)
            }
        }
    }
}
// end story
