// An original "Date Planner" — our own take on the agenda/events apps in
// Apple's SwiftUI sample-app tutorials. Events are grouped by day, created and
// edited through a sheet (TextField + DatePicker + Pickers), and persisted with
// FileManager in the app's Application Support. Calendar math comes from IsomerBridge's
// date helpers, so this exact source compiles on every platform. Nothing here
// is copied from Apple's sample sources.

import Foundation
import SwiftUI
import Isomer
import Observation

struct PlannerEvent: Identifiable, Equatable {
    var id: Int
    var title: String
    var date: Date
    var colorIndex: Int
}

/// The palette an event's accent is chosen from (index stored in the event).
let plannerColors: [(name: String, color: Color)] = [
    ("Blue", .blue), ("Green", .green), ("Orange", .orange),
    ("Red", .red), ("Purple", .purple),
]

func plannerColor(_ index: Int) -> Color {
    plannerColors[min(max(index, 0), plannerColors.count - 1)].color
}

/// Events store, persisted to a JSON file in the app's Application Support
/// (FileManager's, on every platform). Seeds a few sample events the first
/// time it runs.
@Observable final class PlannerStore {
    private(set) var events: [PlannerEvent] = []
    private var nextID = 1
    init() {
        load()
    }

    /// Events grouped by day, each day sorted by time, days sorted ascending.
    var days: [(day: Date, events: [PlannerEvent])] {
        var buckets: [Double: [PlannerEvent]] = [:]
        for event in events {
            buckets[startOfDay(event.date).timeIntervalSince1970, default: []].append(event)
        }
        return buckets
            .map { (Date(timeIntervalSince1970: $0.key), $0.value.sorted { $0.date.timeIntervalSince1970 < $1.date.timeIntervalSince1970 }) }
            .sorted { $0.0.timeIntervalSince1970 < $1.0.timeIntervalSince1970 }
            .map { (day: $0.0, events: $0.1) }
    }

    func event(_ id: Int) -> PlannerEvent? { events.first { $0.id == id } }

    func add(title: String, date: Date, colorIndex: Int) {
        events.append(PlannerEvent(id: nextID, title: title, date: date, colorIndex: colorIndex))
        nextID += 1
        save()
    }

    func update(_ event: PlannerEvent) {
        guard let index = events.firstIndex(where: { $0.id == event.id }) else { return }
        events[index] = event
        save()
    }

    func delete(_ id: Int) {
        events.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let text = SandboxFiles.read("planner.json"),
              let array = parseJSON(text)?.array else {
            seed()
            return
        }
        events = array.compactMap { entry in
            guard let id = entry["id"].int,
                  let title = entry["title"].string,
                  let epoch = entry["date"].double else { return nil }
            return PlannerEvent(
                id: id, title: title,
                date: Date(timeIntervalSince1970: epoch),
                colorIndex: entry["color"].int ?? 0)
        }
        nextID = (events.map(\.id).max() ?? 0) + 1
    }

    private func save() {
        let array = events.map { event in
            JSONValue.object([
                "id": .number(Double(event.id)),
                "title": .string(event.title),
                "date": .number(event.date.timeIntervalSince1970),
                "color": .number(Double(event.colorIndex)),
            ])
        }
        SandboxFiles.write("planner.json", JSONValue.array(array).encoded())
    }

    /// A few starter events around our reference day (2024-01-01) so the screen
    /// has content before the user adds their own.
    private func seed() {
        add(title: "Kickoff sync", date: makeDate(year: 2024, month: 1, day: 1, hour: 9, minute: 30), colorIndex: 0)
        add(title: "Design review", date: makeDate(year: 2024, month: 1, day: 1, hour: 14, minute: 0), colorIndex: 2)
        add(title: "Release planning", date: makeDate(year: 2024, month: 1, day: 3, hour: 11, minute: 0), colorIndex: 1)
        add(title: "Team dinner", date: makeDate(year: 2024, month: 1, day: 5, hour: 19, minute: 0), colorIndex: 4)
    }
}

// MARK: - Main screen (lives inside the Apps tab's NavigationStack)

struct DatePlannerScreen: View {
    @State private var store = PlannerStore()
    @State private var showingAdd = false

    var body: some View {
        List {
            Button {
                showingAdd = true
            } label: {
                HStack(spacing: 8) {
                    Text("+").font(.title2).foregroundColor(.accentColor)
                    Text("New Event").font(.headline).foregroundColor(.accentColor)
                    Spacer(minLength: 0)
                }
            }
            ForEach(0 ..< store.days.count, id: \.self) { index in
                let group = store.days[index]
                Section(dayHeadline(group.day)) {
                    ForEach(group.events) { event in
                        NavigationLink {
                            EventDetailView(store: store, eventID: event.id)
                        } label: {
                            EventRow(event: event)
                        }
                    }
                }
            }
        }
        .navigationTitle("Date Planner")
        .sheet(isPresented: $showingAdd) {
            EventEditView(store: store, editing: nil)
        }
    }
}

struct EventRow: View {
    let event: PlannerEvent

    var body: some View {
        HStack(spacing: 14) {
            Circle()
                .fill(plannerColor(event.colorIndex))
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(timeOfDay(event.date))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Detail

struct EventDetailView: View {
    var store: PlannerStore
    let eventID: Int
    @State private var showingEdit = false

    var body: some View {
        Group {
            if let event = store.event(eventID) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(plannerColor(event.colorIndex))
                                .frame(width: 22, height: 22)
                            Text(event.title).font(.title2).bold()
                        }
                        infoRow("Day", dayHeadline(event.date))
                        infoRow("Time", timeOfDay(event.date))
                        infoRow("Date", shortDate(event.date))

                        Button {
                            showingEdit = true
                        } label: {
                            Text("Edit").frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.accentColor.opacity(0.15)).cornerRadius(10)
                        }
                        Button {
                            store.delete(eventID)
                        } label: {
                            Text("Delete").foregroundColor(.red)
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Color.red.opacity(0.12)).cornerRadius(10)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 560)
                }
            } else {
                VStack { Text("Event deleted").font(.headline).foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Event")
        .sheet(isPresented: $showingEdit) {
            EventEditView(store: store, editing: store.event(eventID))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(value).foregroundColor(.primary)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Add / edit sheet

struct EventEditView: View {
    var store: PlannerStore
    let editing: PlannerEvent?
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var date: Date
    @State private var hour: Int
    @State private var minute: Int
    @State private var colorIndex: Int

    init(store: PlannerStore, editing: PlannerEvent?) {
        self.store = store
        self.editing = editing
        let base = editing?.date ?? makeDate(year: 2024, month: 1, day: 1, hour: 9, minute: 0)
        let parts = dateParts(base)
        _title = State(initialValue: editing?.title ?? "")
        _date = State(initialValue: base)
        _hour = State(initialValue: parts.hour)
        _minute = State(initialValue: (parts.minute / 15) * 15)
        _colorIndex = State(initialValue: editing?.colorIndex ?? 0)
    }

    private let minuteOptions = [0, 15, 30, 45]

    var body: some View {
        Form {
            Section("Event") {
                TextField("Title", text: $title)
            }
            Section("When") {
                DatePicker("Day", selection: $date)
                Picker("Hour", selection: $hour) {
                    ForEach(0 ..< 24, id: \.self) { h in
                        Text(hourLabel(h)).tag(h)
                    }
                }
                Picker("Minute", selection: $minute) {
                    ForEach(minuteOptions, id: \.self) { m in
                        Text(m < 10 ? ":0\(m)" : ":\(m)").tag(m)
                    }
                }
            }
            Section("Color") {
                Picker("Color", selection: $colorIndex) {
                    ForEach(0 ..< plannerColors.count, id: \.self) { i in
                        Text(plannerColors[i].name).tag(i)
                    }
                }
            }
            Section {
                Button {
                    save()
                } label: {
                    Text(editing == nil ? "Add Event" : "Save")
                        .frame(maxWidth: .infinity)
                        .foregroundColor(title.isEmpty ? .secondary : .accentColor)
                }
                Button {
                    dismiss()
                } label: {
                    Text("Cancel").frame(maxWidth: .infinity).foregroundColor(.secondary)
                }
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        let isPM = h >= 12
        var hour12 = h % 12
        if hour12 == 0 { hour12 = 12 }
        return "\(hour12) \(isPM ? "PM" : "AM")"
    }

    private func save() {
        guard !title.isEmpty else { return }
        let d = dateParts(date)
        let when = makeDate(year: d.year, month: d.month, day: d.day, hour: hour, minute: minute)
        if let editing {
            store.update(PlannerEvent(id: editing.id, title: title, date: when, colorIndex: colorIndex))
        } else {
            store.add(title: title, date: when, colorIndex: colorIndex)
        }
        dismiss()
    }
}
