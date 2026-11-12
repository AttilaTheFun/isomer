// Navigation: pushing screens, toolbars, and tabs.

import SwiftUI

extension StoryCatalog {
    static let navigation = StoryArea(id: "navigation", title: "Navigation", symbol: "arrow.right.square", stories: [
        Story(
            "navigation.links", "NavigationLink",
            summary: "Rows that push a screen onto the page's NavigationStack: by value, the destination chosen by the value's type, or with the destination written in place. Back returns."
        ) { NavigationLinksStory() },
        Story(
            "navigation.presented", "Presented destinations",
            summary: "A screen pushed by state rather than a link: navigationDestination(isPresented:) while a Bool is true, navigationDestination(item:) while an optional has a value. Back sets them false or nil again."
        ) { PresentedDestinationsStory() },
        Story(
            "navigation.toolbar", "Toolbar",
            summary: "Buttons in the navigation bar, placed by role. These two join this page's bar while the story is open."
        ) { ToolbarStory() },
        Story(
            "navigation.tabs", "TabView",
            height: 300,
            summary: "Screens a tab bar switches between: a bottom bar on iOS, a navigation bar on Android, tabs on the Mac."
        ) { TabsStory() },
    ])
}

// story: navigation.links
struct NavigationLinksStory: View {
    struct Planet: Hashable {
        let name: String
        let moons: Int
    }

    private let planets = [Planet(name: "Earth", moons: 1), Planet(name: "Mars", moons: 2), Planet(name: "Jupiter", moons: 95)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(planets, id: \.name) { planet in
                NavigationLink(planet.name, value: planet)
            }
            NavigationLink {
                Text("Written in place, no value needed.")
                    .padding()
                    .navigationTitle("Destination")
            } label: {
                Label("A destination in place", systemImage: "arrow.right.circle")
            }
        }
        .navigationDestination(for: Planet.self) { planet in
            VStack(spacing: 12) {
                Image(systemName: "globe").font(.system(size: 64))
                Text(planet.name).font(.largeTitle)
                Text("\(planet.moons) moons").foregroundColor(.secondary)
            }
            .navigationTitle(planet.name)
        }
    }
}
// end story

// story: navigation.presented
struct PresentedDestinationsStory: View {
    @State private var showsAbout = false
    @State private var selectedMoon: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button("About this page") { showsAbout = true }
            ForEach(["Phobos", "Deimos"], id: \.self) { moon in
                Button("Open \(moon)") { selectedMoon = moon }
            }
            Text(selectedMoon.map { "Showing \($0)" } ?? "No moon open")
                .foregroundStyle(.secondary)
        }
        .navigationDestination(isPresented: $showsAbout) {
            Text("Pushed while showsAbout is true.")
                .padding()
                .navigationTitle("About")
        }
        .navigationDestination(item: $selectedMoon) { moon in
            Text(moon).font(.largeTitle)
                .navigationTitle(moon)
        }
    }
}
// end story

// story: navigation.toolbar
struct ToolbarStory: View {
    @State private var count = 0
    @State private var last = "nothing yet"

    var body: some View {
        Text("Added \(count), last tapped: \(last)")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        count += 1
                        last = "add"
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .navigation) {
                    Button {
                        last = "settings"
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
    }
}
// end story

// story: navigation.tabs
struct TabsStory: View {
    @State private var tab = "home"

    var body: some View {
        TabView(selection: $tab) {
            Text("Home")
                .font(.title)
                .tabItem { Label("Home", systemImage: "house") }
                .tag("home")
            Text("Search")
                .font(.title)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag("search")
            Text("Profile")
                .font(.title)
                .tabItem { Label("Profile", systemImage: "person") }
                .tag("profile")
        }
    }
}
// end story
