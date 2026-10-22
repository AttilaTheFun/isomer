// A To-Do app: a master list of smart lists (Today, Upcoming, Logbook) and a
// detail list of tasks. A floating + button opens a sheet (title + date picker)
// to create a task; tapping a task (not its checkbox) reopens the sheet to edit
// it. A short swipe marks a task done/undone (it animates out of Today/Upcoming
// into the Logbook); a long, full swipe deletes it. Compiles unchanged on every
// platform; persisted as a JSON file in Application Support (SandboxFiles).

import SwiftUI
import Isomer
import Observation

// MARK: - Model

struct TodoItem: Identifiable, Equatable {
    var id: Int
    var title: String
    var date: Date
    var completed: Bool
}

enum TodoFilter: Int, Identifiable, Hashable, CaseIterable {
    case today, upcoming, logbook

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .logbook: return "Logbook"
        }
    }

    var glyph: String {
        switch self {
        case .today: return "★"
        case .upcoming: return "❯"
        case .logbook: return "✓"
        }
    }

    var accent: Color {
        switch self {
        case .today: return .orange
        case .upcoming: return .blue
        case .logbook: return .green
        }
    }
}

@Observable final class TodoStore {
    private(set) var items: [TodoItem] = []
    private var nextID = 1
    init() {
        load()
    }

    /// Midnight of the device's current day (the boundary between Today and
    /// Upcoming).
    var today: Date {
        startOfDay(Date())
    }

    func items(for filter: TodoFilter) -> [TodoItem] {
        let t = today.timeIntervalSince1970
        switch filter {
        case .today:
            return items
                .filter { !$0.completed && startOfDay($0.date).timeIntervalSince1970 <= t }
                .sorted { $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970 }
        case .upcoming:
            return items
                .filter { !$0.completed && startOfDay($0.date).timeIntervalSince1970 > t }
                .sorted { $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970 }
        case .logbook:
            return items
                .filter { $0.completed }
                .sorted { $0.date.timeIntervalSince1970 > $1.date.timeIntervalSince1970 }
        }
    }

    func count(_ filter: TodoFilter) -> Int { items(for: filter).count }

    func item(_ id: Int) -> TodoItem? { items.first { $0.id == id } }

    func add(title: String, date: Date) {
        items.append(TodoItem(id: nextID, title: title, date: date, completed: false))
        nextID += 1
        save()
    }

    func update(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
        save()
    }

    func toggle(_ id: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].completed.toggle()
        save()
    }

    func delete(_ id: Int) {
        items.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let text = SandboxFiles.read("todos.json"), let array = parseJSON(text)?.array else {
            seed()
            return
        }
        items = array.compactMap { entry in
            guard let id = entry["id"].int,
                  let title = entry["title"].string,
                  let epoch = entry["date"].double else { return nil }
            return TodoItem(
                id: id, title: title,
                date: Date(timeIntervalSince1970: epoch),
                completed: entry["done"].bool ?? false)
        }
        nextID = (items.map(\.id).max() ?? 0) + 1
    }

    private func save() {
        let array = items.map { item in
            JSONValue.object([
                "id": .number(Double(item.id)),
                "title": .string(item.title),
                "date": .number(item.date.timeIntervalSince1970),
                "done": .bool(item.completed),
            ])
        }
        SandboxFiles.write("todos.json", JSONValue.array(array).encoded())
    }

    /// A few starter tasks the first time the app runs.
    private func seed() {
        let now = Date()
        let day = 86_400.0
        func at(_ offsetDays: Double) -> Date {
            Date(timeIntervalSince1970: now.timeIntervalSince1970 + offsetDays * day)
        }
        add(title: "Swipe me right-to-left to complete", date: at(0))
        add(title: "Long-swipe to delete", date: at(0))
        add(title: "Tap a task to edit its name or date", date: at(0))
        add(title: "Plan the week", date: at(2))
        add(title: "Dentist appointment", date: at(5))
    }
}

// MARK: - Master (Today / Upcoming / Logbook)

/// Mobile entry point: the smart lists, each pushing its task list.
struct TodoHome: View {
    @State private var store = TodoStore()

    var body: some View {
        List {
            ForEach(TodoFilter.allCases) { filter in
                NavigationLink {
                    TodoListView(store: store, filter: filter)
                } label: {
                    TodoFilterRow(store: store, filter: filter)
                }
            }
        }
        .navigationTitle("To-Do")
    }
}

/// Desktop content column: the smart lists drive the detail column.
struct TodoMasterColumn: View {
    var store: TodoStore
    @Binding var selection: TodoFilter?

    var body: some View {
        List(selection: $selection) {
            ForEach(TodoFilter.allCases) { filter in
                TodoFilterRow(store: store, filter: filter).tag(filter)
            }
        }
        .navigationTitle("To-Do")
    }
}

struct TodoFilterRow: View {
    var store: TodoStore
    let filter: TodoFilter

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(filter.accent)
                Text(filter.glyph).font(.subheadline).bold().foregroundColor(.white)
            }
            .frame(width: 28, height: 28)
            Text(filter.title).font(.body).foregroundColor(.primary)
            Spacer(minLength: 0)
            Text("\(store.count(filter))")
                .font(.subheadline).foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Detail (the task list + floating add button)

struct TodoListView: View {
    var store: TodoStore
    let filter: TodoFilter

    @State private var showSheet = false
    @State private var editingID: Int?
    @State private var draftTitle = ""
    @State private var draftDate = Date(timeIntervalSince1970: 0)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            content
            addButton
        }
        .navigationTitle(filter.title)
        .sheet(isPresented: $showSheet) {
            editSheet
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = store.items(for: filter)
        if items.isEmpty {
            VStack(spacing: 8) {
                Text(filter.glyph).font(.system(size: 44)).foregroundColor(.secondary.opacity(0.5))
                Text(emptyMessage).font(.headline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        TodoRow(
                            store: store, item: item,
                            onEdit: { beginEdit(item) })
                        Divider().padding(.leading, 52)
                    }
                }
                .padding(.bottom, 96)
            }
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .today: return "Nothing due today"
        case .upcoming: return "Nothing upcoming"
        case .logbook: return "No completed tasks yet"
        }
    }

    private var addButton: some View {
        Button {
            beginCreate()
        } label: {
            Text("+")
                .font(.system(size: 30, weight: .regular))
                .foregroundColor(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Color.accentColor))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        }
        .padding(20)
    }

    // MARK: Create / edit sheet (one sheet, parent-owned draft state)

    private func beginCreate() {
        editingID = nil
        draftTitle = ""
        draftDate = store.today
        showSheet = true
    }

    private func beginEdit(_ item: TodoItem) {
        editingID = item.id
        draftTitle = item.title
        draftDate = item.date
        showSheet = true
    }

    private func saveDraft() {
        guard !draftTitle.isEmpty else { return }
        if let id = editingID, var item = store.item(id) {
            item.title = draftTitle
            item.date = draftDate
            store.update(item)
        } else {
            store.add(title: draftTitle, date: draftDate)
        }
        showSheet = false
    }

    private var editSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editingID == nil ? "New To-Do" : "Edit To-Do")
                .font(.title2).bold()

            TextField("What do you need to do?", text: $draftTitle)
                .padding(12)
                .background(Color.gray.opacity(0.15))
                .cornerRadius(10)

            HStack {
                Text("Date").foregroundColor(.secondary)
                Spacer(minLength: 12)
                DatePicker("", selection: $draftDate)
            }

            HStack(spacing: 12) {
                Button { showSheet = false } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Color.gray.opacity(0.15)).cornerRadius(10)
                        .foregroundColor(.primary)
                }
                Button { saveDraft() } label: {
                    Text(editingID == nil ? "Add" : "Save")
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(draftTitle.isEmpty ? Color.accentColor.opacity(0.4) : Color.accentColor)
                        .cornerRadius(10)
                        .foregroundColor(.white)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: 460, alignment: .leading)
    }
}

// MARK: - A swipeable task row

struct TodoRow: View {
    var store: TodoStore
    let item: TodoItem
    let onEdit: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var dragX: CGFloat = 0

    /// Opaque so the swipe-action colour only shows where the row slides away.
    private var rowFill: Color {
        colorScheme == .dark ? Color(white: 0.13) : Color.white
    }

    // Swipe thresholds (leftward): past `complete` toggles done; a long, full
    // swipe past `delete` removes the task.
    private let completeThreshold: CGFloat = -70
    private let deleteThreshold: CGFloat = -200

    var body: some View {
        ZStack(alignment: .trailing) {
            background
            foreground
                .background(rowFill)
                .offset(x: dragX)
                .swipeGesture(
                    onChanged: { tx in dragX = min(0, max(tx, -320)) },
                    onEnded: { tx in finishSwipe(tx) })
                .onTapGesture { onEdit() }
        }
    }

    private var background: some View {
        let deleting = dragX <= deleteThreshold
        let label = deleting ? "Delete" : (item.completed ? "Reopen" : "Complete")
        return ZStack(alignment: .trailing) {
            (deleting ? Color.red : Color.green)
            Text(label)
                .font(.subheadline).bold().foregroundColor(.white)
                .padding(.trailing, 24)
        }
    }

    private var foreground: some View {
        HStack(spacing: 14) {
            Button { complete() } label: { checkbox }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.body)
                    .foregroundColor(item.completed ? .secondary : .primary)
                Text(shortDate(item.date))
                    .font(.caption)
                    .foregroundColor(item.completed ? .secondary : dueColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkbox: some View {
        ZStack {
            if item.completed {
                Circle().fill(Color.green).frame(width: 24, height: 24)
                Text("✓").font(.caption).bold().foregroundColor(.white)
            } else {
                Circle().stroke(Color(white: 0.6), lineWidth: 2).frame(width: 24, height: 24)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// Red for an overdue, not-yet-done task; secondary otherwise.
    private var dueColor: Color {
        startOfDay(item.date).timeIntervalSince1970 < store.today.timeIntervalSince1970
            ? .red : .secondary
    }

    private func complete() {
        withAnimation(.easeInOut(duration: 0.25)) { store.toggle(item.id) }
    }

    private func finishSwipe(_ tx: CGFloat) {
        if tx <= deleteThreshold {
            withAnimation(.easeInOut(duration: 0.25)) { store.delete(item.id) }
        } else if tx <= completeThreshold {
            dragX = 0
            withAnimation(.easeInOut(duration: 0.25)) { store.toggle(item.id) }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
        }
    }
}
