// State and data: @State and @Binding, Observation, the environment,
// @AppStorage, and work tied to a view's lifetime.

import Foundation
import Observation
import SwiftUI

extension StoryCatalog {
    static let state = StoryArea(id: "state", title: "State and Data", symbol: "arrow.triangle.2.circlepath", stories: [
        Story(
            "state.binding", "@State and @Binding", apis: ["@State", "@Binding", "$value"],
            summary: "A value a view owns, and a child that reads and writes it through a binding: both redraw when it changes."
        ) { BindingStory() },
        Story(
            "state.observable", "@Observable", apis: ["@Observable", "@State", ".environment(_:)", "@Environment(Model.self)", "@Bindable"],
            summary: "A model class whose properties are observed: held in @State, put in the environment, read below, and bound to controls with @Bindable. Only the views that read a property redraw when it changes."
        ) { ObservableStory() },
        Story(
            "state.environment", "Environment values", apis: ["@Environment(\\.colorScheme)", "@Environment(\\.horizontalSizeClass)", ".environment(_:_:)"],
            summary: "Values the system passes down (the appearance, the size class) and values a view sets for the views inside it."
        ) { EnvironmentStory() },
        Story(
            "state.appstorage", "@AppStorage", apis: ["@AppStorage(_:)", "UserDefaults"],
            summary: "A value kept in the app's defaults: it is still there when the app is opened again."
        ) { AppStorageStory() },
        Story(
            "state.task", "Tasks and lifecycle", apis: [".task(_:)", ".task(id:_:)", ".onAppear(perform:)", ".onChange(of:_:)", "Task.sleep(for:)"],
            summary: "Work that starts when a view appears and is cancelled when it goes, restarted when a value changes."
        ) { TaskStory() },
    ])
}

// story: state.binding
struct BindingStory: View {
    @State private var count = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parent sees \(count)")
            CounterControls(count: $count)
        }
    }

    struct CounterControls: View {
        @Binding var count: Int

        var body: some View {
            HStack(spacing: 12) {
                Button("−") { count -= 1 }
                Text("\(count)").font(.title2).frame(minWidth: 48)
                Button("+") { count += 1 }
            }
            .buttonStyle(.bordered)
        }
    }
}
// end story

// story: state.observable
@Observable final class StoryProfile {
    var name = "Ada"
    var likes = 3
}

struct ObservableStory: View {
    @State private var profile = StoryProfile()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProfileSummary()
            ProfileEditor()
        }
        .environment(profile)
    }

    struct ProfileSummary: View {
        @Environment(StoryProfile.self) private var profile

        var body: some View {
            Text("\(profile.name) has \(profile.likes) likes").font(.headline)
        }
    }

    struct ProfileEditor: View {
        @Environment(StoryProfile.self) private var profile

        var body: some View {
            @Bindable var profile = profile
            TextField("Name", text: $profile.name)
                .textFieldStyle(.roundedBorder)
            Stepper("Likes: \(profile.likes)", value: $profile.likes, in: 0 ... 99)
        }
    }
}
// end story

// story: state.environment
struct EnvironmentStory: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance: \(colorScheme == .dark ? "dark" : "light")")
            Text("Width: \(sizeClass == .compact ? "compact" : "regular")")
            SchemeBadge()
                .environment(\.colorScheme, .dark)
            SchemeBadge()
                .environment(\.colorScheme, .light)
        }
    }

    struct SchemeBadge: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Text("This badge reads \(colorScheme == .dark ? "dark" : "light")")
                .padding(10)
                .foregroundColor(colorScheme == .dark ? .white : .black)
                .background(colorScheme == .dark ? Color.black : Color.white)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.4)))
        }
    }
}
// end story

// story: state.appstorage
struct AppStorageStory: View {
    @AppStorage("storybook.stars") private var stars = 0
    @AppStorage("storybook.nickname") private var nickname = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { stars += 1 } label: { Label("Star", systemImage: "star") }
                Button("Reset") { stars = 0 }
            }
            .buttonStyle(.bordered)
            Text("Starred \(stars) times, kept across launches")
            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
        }
    }
}
// end story

// story: state.task
struct TaskStory: View {
    @State private var status = "Loading…"
    @State private var city = "Paris"
    @State private var forecast = ""
    @State private var appeared = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status)
            Picker("City", selection: $city) {
                ForEach(["Paris", "Tokyo", "Lima"], id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(forecast.isEmpty ? "Fetching \(city)…" : forecast)
            Text("Appeared \(appeared) times")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .onAppear { appeared += 1 }
        .task {
            try? await Task.sleep(for: .milliseconds(600))
            status = "Loaded"
        }
        .task(id: city) {
            forecast = ""
            try? await Task.sleep(for: .milliseconds(400))
            forecast = "\(city): \(city.count + 15)° and clear"
        }
        .onChange(of: city) {
            status = "Changed city"
        }
    }
}
// end story
