// A text field on a screen pushed onto a path an `@Observable` model holds
// (`NavigationStack(path: $model.path)`, the model in `@State` and in the
// environment): focusing the field (the keyboard coming up) and typing must
// settle, and only a push or a pop writes the path. The screens show how
// many times each view was built and the path was written, for a driver to
// read (uiautomator on Android). "Stray link" pushes a value the array
// path can't hold: the path must stay unwritten ("path writes" on the root).
//
// `-variant navigationPath` (ISO_ARGUMENTS on Android) binds a
// NavigationPath instead of an array.

import Foundation
import Observation
import SwiftUI

@main
struct PathFieldProbeApp: App {
    var body: some Scene {
        WindowGroup {
            if UserDefaults.standard.string(forKey: "variant") == "navigationPath" {
                PathFieldProbeNavigationPath()
            } else {
                PathFieldProbe()
            }
        }
    }
}

@Observable final class PathFieldModel {
    var path: [Int] = [] { didSet { pathWrites += 1 } }
    var navigationPath = NavigationPath() { didSet { pathWrites += 1 } }
    var name = ""
    var pathWrites = 0
}

nonisolated(unsafe) var rootBuilds = 0
nonisolated(unsafe) var editorBuilds = 0

struct PathFieldProbe: View {
    @State private var model = PathFieldModel()

    var body: some View {
        rootBuilds += 1
        return NavigationStack(path: $model.path) {
            PathFieldRoot()
        }
        .environment(model)
    }
}

struct PathFieldProbeNavigationPath: View {
    @State private var model = PathFieldModel()

    var body: some View {
        rootBuilds += 1
        return NavigationStack(path: $model.navigationPath) {
            PathFieldRoot()
        }
        .environment(model)
    }
}

struct PathFieldRoot: View {
    @Environment(PathFieldModel.self) private var model

    var body: some View {
        List {
            NavigationLink("Model field", value: 1)
            NavigationLink("Local field", value: 2)
            // Not an Int: the array path has nowhere to put it, so the tap
            // must not write the path (the NavigationPath variant pushes it,
            // to an empty screen).
            NavigationLink("Stray link", value: "stray")
            Text("root builds \(rootBuilds)")
            Text("path writes \(model.pathWrites)")
        }
        .navigationTitle("Path Field")
        .navigationDestination(for: Int.self) { route in
            PathFieldEditor(route: route)
        }
    }
}

struct PathFieldEditor: View {
    let route: Int
    @Environment(PathFieldModel.self) private var model
    @State private var local = ""
    @FocusState private var focused: Bool

    var body: some View {
        editorBuilds += 1
        @Bindable var model = model
        return Form {
            if route == 1 {
                TextField("Name", text: $model.name).focused($focused)
            } else {
                TextField("Local", text: $local).focused($focused)
            }
            Text(focused ? "focused" : "not focused")
            Text("editor builds \(editorBuilds)")
            Text("path writes \(model.pathWrites)")
            Text("depth \(model.path.count + model.navigationPath.count)")
        }
        .navigationTitle(route == 1 ? "Model" : "Local")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { focused = false }
            }
        }
    }
}
